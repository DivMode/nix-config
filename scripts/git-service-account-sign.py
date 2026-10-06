"""Git SSH signing and GitHub transport with the approved key, read from 1Password Connect.

No `op` CLI, no service account, no desktop application, no SSH agent: the key
is fetched over the Connect REST API, used from a private temporary file, and
every OpenSSH child runs without SSH_AUTH_SOCK.
"""

import os
import re
import shlex
import signal
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from onepassword_connect import Connect, ConnectError  # noqa: E402


def fail(message):
    print(f"Git signing: {message}", file=sys.stderr)
    raise SystemExit(1)


mode, connect_env, ssh_keygen, ssh, reference, expected_public_file, *arguments = sys.argv[1:]

# OpenSSH children never see an agent socket or 1Password variables.
child_env = {k: v for k, v in os.environ.items() if k != "SSH_AUTH_SOCK" and not k.startswith("OP_")}

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
        os.execve(ssh_keygen, [ssh_keygen, *arguments], child_env)
    if arguments[1] != "sign":
        fail("unsupported operation")

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
            # private key from Connect, never an SSH agent.
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

match = re.fullmatch(r"op://([a-z0-9]{26})/([a-z0-9]{26})/private key\?ssh-format=openssh", reference)
if match is None:
    fail("the signing key reference must name a vault and item by ID")
try:
    secret = Connect(connect_env).ssh_private_key(*match.groups()).encode()
except ConnectError as error:
    fail(f"{error}; no other credential is tried")

# TemporaryDirectory is private (0700), and the key is created as 0600. Nothing
# is added to an agent or cached after signing. The private bytes never reach logs.
with tempfile.TemporaryDirectory(prefix="git-service-account-sign-") as directory:
    private = Path(directory) / "key"
    descriptor = os.open(private, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(secret)
    del secret
    public = subprocess.run(
        [ssh_keygen, "-y", "-P", "", "-f", str(private)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, timeout=10, env=child_env,
    )
    if public.returncode or public.stdout.decode().split()[:2] != expected:
        fail("retrieved key does not match the configured public identity")
    # A PKCS#8 key carries no public half; ssh-keygen -Y sign reads it from key.pub.
    Path(f"{private}.pub").write_bytes(public.stdout)
    if mode == "transport":
        result = subprocess.run([
            ssh, "-F", "/dev/null", "-T",
            "-o", "BatchMode=yes", "-o", "IdentityAgent=none",
            "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
            "-o", "ForwardAgent=no", "-o", "ConnectTimeout=15",
            "-i", str(private), "git@github.com", remote_command,
        ], env=child_env)
        raise SystemExit(result.returncode)
    try:
        result = subprocess.run(
            [ssh_keygen, "-Y", "sign", "-n", "git", "-f", str(private), *forward, payload],
            stdin=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30, env=child_env,
        )
    except (OSError, subprocess.TimeoutExpired):
        fail("SSH signing failed or timed out")
    if result.returncode:
        fail(f"SSH signing failed: {result.stderr.decode(errors='replace').strip()[:300]}")
    raise SystemExit(0)
