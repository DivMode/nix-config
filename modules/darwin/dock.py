"""Apply the declared Dock, and restart the Dock only when that changed
something, or when a pinned application appeared during this activation.

Usage: dock.py DESIRED_JSON [--app-appeared]

DESIRED_JSON is {"settings": {key: value}, "apps": [path],
"others": [{"path", "arrangement", "displayas", "showas"}]}. Runs as the Dock's
user. The comparison is logical: the Dock rewrites every tile it stores with
keys of its own (GUID, book, file-label, file-mod-date, a file:// URL with a
trailing slash), so a byte comparison would always differ.
"""

import json
import plistlib
import subprocess
import sys
import tempfile
import urllib.parse

DOMAIN = "com.apple.dock"


def path_of(tile):
    url = tile.get("tile-data", {}).get("file-data", {}).get("_CFURLString", "")
    path = urllib.parse.unquote(url.removeprefix("file://"))
    return path.rstrip("/") or path


def folder_view(tile):
    data = tile.get("tile-data", {})
    return {
        "path": path_of(tile),
        "arrangement": data.get("arrangement"),
        "displayas": data.get("displayas"),
        "showas": data.get("showas"),
    }


# The same tile shapes nix-darwin's system.defaults.dock writes
# (modules/system/defaults/dock.nix), so the Dock receives what it always has.
def app_tile(path):
    return {"tile-data": {"file-data": {"_CFURLString": path, "_CFURLStringType": 0}}}


def folder_tile(folder):
    return {
        "tile-data": {
            "file-data": {"_CFURLString": "file://" + folder["path"], "_CFURLStringType": 15},
            "arrangement": folder["arrangement"],
            "displayas": folder["displayas"],
            "showas": folder["showas"],
        },
        "tile-type": "directory-tile",
    }


def main():
    desired_path = sys.argv[1]
    app_appeared = "--app-appeared" in sys.argv[2:]
    with open(desired_path) as f:
        desired = json.load(f)

    exported = subprocess.run(["/usr/bin/defaults", "export", DOMAIN, "-"], capture_output=True)
    domain = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}

    current_apps = [path_of(tile) for tile in domain.get("persistent-apps", [])]
    current_others = [folder_view(tile) for tile in domain.get("persistent-others", [])]
    wanted_apps = [path.rstrip("/") for path in desired["apps"]]

    changed = (
        any(domain.get(key) != value for key, value in desired["settings"].items())
        or current_apps != wanted_apps
        or current_others != desired["others"]
    )

    if changed:
        domain.update(desired["settings"])
        domain["persistent-apps"] = [app_tile(path) for path in desired["apps"]]
        domain["persistent-others"] = [folder_tile(folder) for folder in desired["others"]]
        with tempfile.NamedTemporaryFile(suffix=".plist") as staged:
            plistlib.dump(domain, staged)
            staged.flush()
            subprocess.run(["/usr/bin/defaults", "import", DOMAIN, staged.name], check=True)
        print("Dock settings changed; restarting the Dock", file=sys.stderr)
    elif app_appeared:
        # A pinned app installed by this activation's Homebrew step shows as a
        # question mark until the Dock re-resolves its tiles.
        print("A pinned application was just installed; restarting the Dock", file=sys.stderr)

    if changed or app_appeared:
        subprocess.run(["/usr/bin/killall", "Dock"], check=False)


if __name__ == "__main__":
    main()
