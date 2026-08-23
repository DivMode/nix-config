#!/usr/bin/env python3

"""Merge Nix-owned preferences into Codex's application-owned TOML file."""

from __future__ import annotations

import argparse
import copy
import os
from pathlib import Path
import stat
import sys
import tempfile
from typing import Any

import tomlkit
from tomlkit.items import InlineTable, Table
from tomlkit.toml_document import TOMLDocument


TableLike = TOMLDocument | Table | InlineTable


class MergeError(Exception):
    """A safe merge cannot be completed without discarding live state."""


def is_table(value: Any) -> bool:
    return isinstance(value, (TOMLDocument, Table, InlineTable))


def item_value(value: Any) -> Any:
    return value.unwrap() if hasattr(value, "unwrap") else value


def clone_item(value: Any) -> Any:
    if isinstance(value, Table):
        cloned = tomlkit.table()
        for key, child in value.items():
            cloned.add(key, clone_item(child))
        return cloned
    if isinstance(value, InlineTable):
        cloned = tomlkit.inline_table()
        for key, child in value.items():
            cloned.add(key, clone_item(child))
        return cloned
    return tomlkit.item(copy.deepcopy(item_value(value)))


def existing_item(table: TableLike, key: str) -> Any:
    return table.item(key)


def merge_table(live: TableLike, declared: TableLike, path: tuple[str, ...] = ()) -> None:
    for key, declared_value in declared.items():
        key_path = (*path, key)
        if key not in live:
            live.add(key, clone_item(declared_value))
            continue

        live_value = live[key]
        if is_table(declared_value):
            if not is_table(live_value):
                raise MergeError(f"managed table conflicts with a scalar at {'.'.join(key_path)}")
            merge_table(live_value, declared_value, key_path)
            continue

        if item_value(live_value) == item_value(declared_value):
            continue

        replacement = clone_item(declared_value)
        current = existing_item(live, key)
        if hasattr(current, "trivia") and hasattr(replacement, "trivia"):
            replacement.trivia.indent = current.trivia.indent
            replacement.trivia.comment_ws = current.trivia.comment_ws
            replacement.trivia.comment = current.trivia.comment
            replacement.trivia.trail = current.trivia.trail
        live[key] = replacement


def parse_toml(text: str, source: Path) -> TOMLDocument:
    try:
        return tomlkit.parse(text)
    except Exception as error:
        raise MergeError(f"invalid TOML in {source}; refusing to overwrite it") from error


def fsync_directory(directory: Path) -> None:
    directory_fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def atomic_write(target: Path, content: str) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        dir=target.parent,
        prefix=f".{target.name}.",
        suffix=".tmp",
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
        fsync_directory(target.parent)
    finally:
        if temporary.exists():
            temporary.unlink()


def merge_config(target: Path, declared_path: Path) -> bool:
    if target.is_symlink():
        raise MergeError(f"refusing to replace symlink: {target}")
    if target.exists() and not target.is_file():
        raise MergeError(f"refusing to replace non-file: {target}")

    declared = parse_toml(declared_path.read_text(encoding="utf-8"), declared_path)
    original = target.read_text(encoding="utf-8") if target.exists() else None
    live = parse_toml(original, target) if original is not None else tomlkit.document()

    merge_table(live, declared)
    merged = tomlkit.dumps(live)

    if original == merged:
        if stat.S_IMODE(target.stat().st_mode) != 0o600:
            os.chmod(target, 0o600)
        return False

    target.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(target, merged)
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Merge declared preferences into a mutable Codex config.toml",
    )
    parser.add_argument("--declared", required=True, type=Path)
    parser.add_argument("target", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        changed = merge_config(args.target, args.declared)
    except (MergeError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print("updated" if changed else "unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
