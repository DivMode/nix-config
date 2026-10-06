"""Merge declared document-type handlers into LaunchServices' preferences.

Usage: default-handlers.py DESIRED_JSON OUTPUT_PLIST

DESIRED_JSON maps a UTI to {"bundleId": ..., "role": ...}. The user's current
com.apple.launchservices.secure domain is read with `defaults export`, every
LSHandlers entry for a declared UTI is replaced by the declared one, and every
other entry (URL schemes, undeclared types) is kept as it is. When that changes
anything, the merged domain is written to OUTPUT_PLIST and "changed" is
printed; otherwise nothing is written.
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


def declared_entry(uti, handler):
    key = ROLE_KEYS[handler["role"]]
    return {
        "LSHandlerContentType": uti,
        key: handler["bundleId"],
        "LSHandlerPreferredVersions": {key: "-"},
    }


def matches(entry, wanted):
    # The modification date is bookkeeping, not part of the binding.
    return {k: v for k, v in entry.items() if k != "LSHandlerModificationDate"} == wanted


def main():
    desired_path, output_path = sys.argv[1:]
    with open(desired_path) as f:
        desired = json.load(f)

    domain = current_domain()
    handlers = domain.get("LSHandlers", [])
    now = int(time.time()) - CF_EPOCH

    merged = []
    unchanged = {}
    for entry in handlers:
        uti = entry.get("LSHandlerContentType")
        if uti not in desired:
            merged.append(entry)
        elif uti not in unchanged and matches(entry, declared_entry(uti, desired[uti])):
            unchanged[uti] = entry

    changed = len(unchanged) != len(desired) or len(merged) + len(unchanged) != len(handlers)
    for uti, handler in sorted(desired.items()):
        if uti in unchanged:
            merged.append(unchanged[uti])
        else:
            merged.append({**declared_entry(uti, handler), "LSHandlerModificationDate": now})

    if changed:
        domain["LSHandlers"] = merged
        with open(output_path, "wb") as f:
            plistlib.dump(domain, f)
        print("changed")


if __name__ == "__main__":
    main()
