"""Apply the declared Dock, and restart the Dock only when that changed
something, or when a pinned application appeared during this activation.

Usage: dock.py DESIRED_JSON [--app-appeared]
       dock.py --refresh-stale

DESIRED_JSON is {"settings": {key: value}, "apps": [path],
"others": [{"path", "arrangement", "displayas", "showas"}]}. Runs as the Dock's
user. The comparison is logical: the Dock rewrites every tile it stores with
keys of its own (GUID, book, file-label, file-mod-date, a file:// URL with a
trailing slash), so a byte comparison would always differ.

One of those keys is not cosmetic. `book` is a bookmark the Dock captures when
it first resolves a folder, and it records the volume the folder was on. A
network share that is remounted (after the file server reboots, say) comes
back as a different volume, the old bookmark stops resolving, and the Dock
trusts it over the path: it tries to mount the share itself, fails with
"File exists" because the share is already mounted there, and draws a question
mark (2026-10-21). Restarting the Dock does not help, because the bookmark is
stored. A folder tile whose bookmark no longer resolves to its own path is
therefore stale, and is rewritten without one, so the Dock resolves the path
again. --refresh-stale does only that; network-shares.nix runs it after
remounting a share.
"""

import ctypes
import ctypes.util
import json
import plistlib
import subprocess
import sys
import tempfile
import urllib.parse

DOMAIN = "com.apple.dock"

# CFURLBookmarkResolutionOptions: never draw UI, never mount a volume to
# resolve. The question is whether the bookmark resolves as things stand.
RESOLVE_WITHOUT_UI = 1 << 8
RESOLVE_WITHOUT_MOUNTING = 1 << 9
POSIX_PATH_STYLE = 0
UTF8 = 0x08000100

_cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
_cf.CFDataCreate.restype = ctypes.c_void_p
_cf.CFDataCreate.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long]
_cf.CFURLCreateByResolvingBookmarkData.restype = ctypes.c_void_p
_cf.CFURLCreateByResolvingBookmarkData.argtypes = [
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_ulong,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_ubyte),
    ctypes.POINTER(ctypes.c_void_p),
]
_cf.CFURLCopyFileSystemPath.restype = ctypes.c_void_p
_cf.CFURLCopyFileSystemPath.argtypes = [ctypes.c_void_p, ctypes.c_long]
_cf.CFStringGetCString.restype = ctypes.c_bool
_cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
_cf.CFRelease.argtypes = [ctypes.c_void_p]


def bookmark_path(book):
    """The path a bookmark resolves to now, or None when it does not resolve."""
    data = _cf.CFDataCreate(None, book, len(book))
    stale = ctypes.c_ubyte(0)
    error = ctypes.c_void_p()
    url = _cf.CFURLCreateByResolvingBookmarkData(
        None,
        data,
        RESOLVE_WITHOUT_UI | RESOLVE_WITHOUT_MOUNTING,
        None,
        None,
        ctypes.byref(stale),
        ctypes.byref(error),
    )
    _cf.CFRelease(data)
    if error.value:
        _cf.CFRelease(error)
    if not url:
        return None
    path = _cf.CFURLCopyFileSystemPath(url, POSIX_PATH_STYLE)
    _cf.CFRelease(url)
    buf = ctypes.create_string_buffer(4096)
    ok = _cf.CFStringGetCString(path, buf, len(buf), UTF8)
    _cf.CFRelease(path)
    if not ok or stale.value:
        return None
    return buf.value.decode("utf-8")


def bookmark_stale(tile):
    book = tile.get("tile-data", {}).get("book")
    if not book:
        return False
    resolved = bookmark_path(bytes(book))
    return resolved is None or resolved.rstrip("/") != path_of(tile)


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


def import_domain(domain):
    with tempfile.NamedTemporaryFile(suffix=".plist") as staged:
        plistlib.dump(domain, staged)
        staged.flush()
        subprocess.run(["/usr/bin/defaults", "import", DOMAIN, staged.name], check=True)


def refresh_stale(domain):
    """Drop stale bookmarks from folder tiles, leaving everything else as is."""
    stale = [tile for tile in domain.get("persistent-others", []) if bookmark_stale(tile)]
    for tile in stale:
        del tile["tile-data"]["book"]
    if stale:
        import_domain(domain)
        names = ", ".join(path_of(tile) for tile in stale)
        print(f"Dock folder bookmark no longer resolves ({names}); restarting the Dock", file=sys.stderr)
        subprocess.run(["/usr/bin/killall", "Dock"], check=False)


def main():
    exported = subprocess.run(["/usr/bin/defaults", "export", DOMAIN, "-"], capture_output=True)
    domain = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}

    if sys.argv[1:] == ["--refresh-stale"]:
        refresh_stale(domain)
        return

    desired_path = sys.argv[1]
    app_appeared = "--app-appeared" in sys.argv[2:]
    with open(desired_path) as f:
        desired = json.load(f)

    current_apps = [path_of(tile) for tile in domain.get("persistent-apps", [])]
    current_others = [folder_view(tile) for tile in domain.get("persistent-others", [])]
    wanted_apps = [path.rstrip("/") for path in desired["apps"]]

    changed = (
        any(domain.get(key) != value for key, value in desired["settings"].items())
        or current_apps != wanted_apps
        or current_others != desired["others"]
        or any(bookmark_stale(tile) for tile in domain.get("persistent-others", []))
    )

    if changed:
        domain.update(desired["settings"])
        domain["persistent-apps"] = [app_tile(path) for path in desired["apps"]]
        domain["persistent-others"] = [folder_tile(folder) for folder in desired["others"]]
        import_domain(domain)
        print("Dock settings changed; restarting the Dock", file=sys.stderr)
    elif app_appeared:
        # A pinned app installed by this activation's Homebrew step shows as a
        # question mark until the Dock re-resolves its tiles.
        print("A pinned application was just installed; restarting the Dock", file=sys.stderr)

    if changed or app_appeared:
        subprocess.run(["/usr/bin/killall", "Dock"], check=False)


if __name__ == "__main__":
    main()
