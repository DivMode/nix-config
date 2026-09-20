"""Git SSH signing through the configured service account, without an agent."""

import os
import re
import shlex
import signal
from pathlib import Path
import subprocess
import sys
import tempfile


def fail(message):
    print(f"Git service-account signing: {message}", file=sys.stderr)
    raise SystemExit(1)


mode, op, ssh_keygen, ssh, reference, expected_public_file, *arguments = sys.argv[1:]

def terminate(signum, frame):
    raise SystemExit(128 + signum)

signal.signal(signal.SIGTERM, terminate)

if mode not in {"sign", "transport"}:
    fail("unsupported interface")

if mode == "transport":
    # Accept only Git's fixed GitHub SSH protocol, never arbitrary SSH options
    # or remote commands. Host identity is checked by OpenSSH below.
    if arguments[:2] == ["-o", "SendEnv=GIT_PROTOCOL"]:
        arguments = arguments[2:]
    if len(arguments) != 2 or arguments[0] != "git@github.com":
        fail("only GitHub Git transport is configured")
    remote = shlex.split(arguments[1])
    if (len(remote) != 2 or remote[0] not in {"git-upload-pack", "git-receive-pack"}
            or re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git", remote[1]) is None):
        fail("unsupported remote Git command")
    remote_command = shlex.join(remote)
if mode == "sign":
    if len(arguments) < 2 or arguments[0] != "-Y":
        fail("unsupported operation")
    if arguments[1] in {"verify", "find-principals", "check-novalidate"}:
        os.execv(ssh_keygen, [ssh_keygen, *arguments])
    if arguments[1] != "sign":
        fail("unsupported operation")
if not os.environ.get("OP_SERVICE_ACCOUNT_TOKEN"):
    fail("service-account authentication is missing; no desktop fallback")
if os.environ.get("OP_CONNECT_HOST") or os.environ.get("OP_CONNECT_TOKEN"):
    fail("conflicting Connect environment; no credentials changed")

if mode == "sign":
    forward = []
    key_file = None
    namespace = None
    payload = None
    index = 2
    while index < len(arguments):
        argument = arguments[index]
        if argument == "-U":
            # Git adds this for a public signing key. This signer uses the matching
            # private key from the service account, never an SSH agent.
            index += 1
        elif argument in {"-f", "-n"} and index + 1 < len(arguments):
            value = arguments[index + 1]
            if argument == "-f" and key_file is None:
                key_file = value
            elif argument == "-n" and namespace is None:
                namespace = value
            else:
                fail("duplicate signing argument")
            index += 2
        elif argument == "-q":
            forward.append(argument)
            index += 1
        elif not argument.startswith("-") and payload is None and index == len(arguments) - 1:
            payload = argument
            index += 1
        else:
            fail("unsupported signing argument")
    if namespace != "git" or key_file is None or payload is None:
        fail("only Git signatures with an explicit configured key are supported")

try:
    expected = Path(expected_public_file).read_text().split()[:2]
    requested = Path(key_file).read_text().split()[:2] if mode == "sign" else expected
except OSError:
    fail("could not read the public signing identity")
if len(expected) != 2 or requested != expected:
    fail("requested signing identity does not match the configured key")

try:
    secret = subprocess.run(
        [op, "read", reference], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30,
    )
except (OSError, subprocess.TimeoutExpired):
    fail("service-account key retrieval failed; no desktop fallback")
if secret.returncode or not secret.stdout:
    fail("service-account key retrieval failed; no desktop fallback")

# TemporaryDirectory is private (0700), and the key is created as 0600. Nothing
# is added to an agent or cached after signing. The private bytes never reach logs.
with tempfile.TemporaryDirectory(prefix="git-service-account-sign-") as directory:
    private = Path(directory) / "key"
    descriptor = os.open(private, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(secret.stdout)
    del secret
    public = subprocess.run(
        [ssh_keygen, "-y", "-P", "", "-f", str(private)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, timeout=10,
    )
    if public.returncode or public.stdout.decode().split()[:2] != expected:
        fail("retrieved key does not match the configured public identity")
    if mode == "transport":
        result = subprocess.run([
            ssh, "-F", "/dev/null", "-T",
            "-o", "BatchMode=yes", "-o", "IdentityAgent=none",
            "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
            "-o", "ForwardAgent=no", "-o", "ConnectTimeout=15",
            "-i", str(private), "git@github.com", remote_command,
        ])
        raise SystemExit(result.returncode)
    try:
        result = subprocess.run(
            [ssh_keygen, "-Y", "sign", "-n", "git", "-f", str(private), *forward, payload],
            stdin=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        fail("SSH signing failed or timed out")
    if result.returncode:
        fail("SSH signing failed")
    raise SystemExit(0)
