"""Print "changed" if a preferences domain does not already hold the declared
values, so an activation entry can restart an application only when its
settings actually changed.

Usage: defaults-changed.py [-currentHost] DOMAIN DESIRED_JSON

Run BEFORE Home Manager's setDarwinDefaults writes the values. The current
values are read with `defaults export`, which goes through cfprefsd, so a
write that has not been flushed to ~/Library/Preferences yet is still seen.
That is why this compares through `defaults` rather than the file on disk.
"""

import json
import plistlib
import subprocess
import sys


def main():
    args = sys.argv[1:]
    current_host = args[0] == "-currentHost"
    if current_host:
        args = args[1:]
    domain, desired_path = args
    with open(desired_path) as f:
        desired = json.load(f)

    command = ["/usr/bin/defaults"] + (["-currentHost"] if current_host else []) + ["export", domain, "-"]
    exported = subprocess.run(command, capture_output=True)
    current = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}

    if not contains(current, desired):
        print("changed")


def contains(current, desired):
    """True when every declared value is already stored. Dictionaries compare
    by their declared keys only, so one entry of a shared dictionary such as
    com.apple.symbolichotkeys AppleSymbolicHotKeys can be checked without
    declaring all the others. JSON and plist agree on bool, int, float,
    string, list and dict, the only types these values use."""
    if isinstance(desired, dict):
        # A null is an option Home Manager leaves unset and does not write
        # (e.g. currentHostDefaults."com.apple.controlcenter" carries
        # BatteryShowPercentage = null). Counting it as a difference made every
        # activation restart ControlCenter on 2026-10-06.
        return isinstance(current, dict) and all(
            key in current and contains(current[key], value)
            for key, value in desired.items()
            if value is not None
        )
    return current == desired


if __name__ == "__main__":
    main()
