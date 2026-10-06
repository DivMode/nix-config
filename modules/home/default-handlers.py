"""Merge declared handlers into LaunchServices' preferences.

Usage: default-handlers.py DESIRED_JSON OUTPUT_PLIST

DESIRED_JSON is {"contentTypes": {UTI: {"bundleId", "role"}},
"urlSchemes": {scheme: bundleId}}. The user's current
com.apple.launchservices.secure domain is read with `defaults export`, every
LSHandlers entry for a declared UTI or URL scheme is replaced by the declared
one, and every other entry is kept as it is. When that changes anything, the
merged domain is written to OUTPUT_PLIST and "changed" is printed; otherwise
nothing is written.
"""

import json
import plistlib
import subprocess
import sys
import time

DOMAIN = "com.apple.LaunchServices/com.apple.launchservices.secure"
ROLE_KEYS = {
    "all": "LSHandlerRoleAll",
    "viewer": "LSHandlerRoleViewer",
    "editor": "LSHandlerRoleEditor",
    "shell": "LSHandlerRoleShell",
}
# LSHandlerModificationDate counts seconds from the Core Foundation epoch.
CF_EPOCH = 978307200


def current_domain():
    exported = subprocess.run(
        ["/usr/bin/defaults", "export", DOMAIN, "-"], capture_output=True
    )
    # A home directory where nothing has chosen a handler has no domain yet.
    if exported.returncode != 0:
        return {}
    return plistlib.loads(exported.stdout)


def binding(target_key, target, role_key, bundle_id):
    # LaunchServices stores bundle identifiers lowercased: the declared
    # com.google.Chrome read back as com.google.chrome after lsd restarted
    # (2026-10-05), so the declared case would never compare equal and every
    # activation would rewrite the domain and restart lsd again.
    return {
        target_key: target,
        role_key: bundle_id.lower(),
        "LSHandlerPreferredVersions": {role_key: "-"},
    }


def declared(desired):
    """Map (target key, target) to the entry that should be stored for it."""
    entries = {}
    for uti, handler in desired.get("contentTypes", {}).items():
        key = ("LSHandlerContentType", uti)
        entries[key] = binding(*key, ROLE_KEYS[handler["role"]], handler["bundleId"])
    # The shape LaunchServices itself stored for the acrobat* schemes on this
    # Mac: role All, preferred version "-".
    for scheme, bundle_id in desired.get("urlSchemes", {}).items():
        key = ("LSHandlerURLScheme", scheme)
        entries[key] = binding(*key, "LSHandlerRoleAll", bundle_id)
    return entries


def target_of(entry):
    for key in ("LSHandlerContentType", "LSHandlerURLScheme"):
        if key in entry:
            return (key, entry[key])
    return None


def matches(entry, wanted):
    # The modification date is bookkeeping, not part of the binding.
    return {k: v for k, v in entry.items() if k != "LSHandlerModificationDate"} == wanted


def main():
    desired_path, output_path = sys.argv[1:]
    with open(desired_path) as f:
        wanted = declared(json.load(f))

    domain = current_domain()
    handlers = domain.get("LSHandlers", [])
    now = int(time.time()) - CF_EPOCH

    merged = []
    unchanged = {}
    for entry in handlers:
        target = target_of(entry)
        if target not in wanted:
            merged.append(entry)
        elif target not in unchanged and matches(entry, wanted[target]):
            unchanged[target] = entry

    changed = len(unchanged) != len(wanted) or len(merged) + len(unchanged) != len(handlers)
    for target, entry in sorted(wanted.items()):
        merged.append(unchanged.get(target) or {**entry, "LSHandlerModificationDate": now})

    if changed:
        domain["LSHandlers"] = merged
        with open(output_path, "wb") as f:
            plistlib.dump(domain, f)
        print("changed")


if __name__ == "__main__":
    main()
