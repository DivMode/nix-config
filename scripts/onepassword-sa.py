"""1Password vault and item writes through the service account, without the CLI.

The approved write interface for agents: it authenticates only with the cached
service-account token (never Connect, the desktop app, or a signed-in session),
takes secret values on stdin (never argv), and has no command that prints a
secret. `item-edit` adds or replaces fields and verifies the submitted values;
`item-copy`/`item-move` read values to verify a copy; `items` lists titles and
ids only. Deletion is limited to an item whose
verified copy exists in the target vault (`item-move`) and to an EMPTY vault
(`vault-delete`).
"""

import argparse
import asyncio
import json
import os
import sys
from uuid import uuid4

from onepassword.client import Client
from onepassword import types as op_types
from onepassword.types import (
    GroupGetParams,
    GroupVaultAccess,
    ItemCategory,
    ItemCreateParams,
    ItemField,
    ItemFieldType,
    ItemSection,
    VaultAccessorType,
    VaultCreateParams,
    VaultGetParams,
)

# Permission bits exported by the SDK (READ_ITEMS, MANAGE_VAULT, ...), for display.
PERMISSIONS = {name: value for name, value in vars(op_types).items()
               if name.isupper() and isinstance(value, int) and value > 0}


def fail(message):
    print(f"onepassword-sa: {message}", file=sys.stderr)
    raise SystemExit(1)


async def connect():
    token = os.environ.get("OP_SERVICE_ACCOUNT_TOKEN", "")
    if not token:
        fail("OP_SERVICE_ACCOUNT_TOKEN is not set; run the human setup workflow")
    return await Client.authenticate(
        auth=token, integration_name="nix-config onepassword-sa", integration_version="1"
    )


async def vault_by_title(client, title, required=True):
    matches = [v for v in await client.vaults.list() if v.title == title]
    if len(matches) > 1:
        fail(f"{len(matches)} vaults titled {title!r}")
    if not matches and required:
        fail(f"vault {title!r} is not visible to the service account")
    return matches[0] if matches else None


async def item_by_title(client, vault, title):
    matches = [i for i in await client.items.list(vault.id) if i.title == title]
    if len(matches) > 1:
        fail(f"{len(matches)} items titled {title!r} in {vault.title!r}")
    return matches[0] if matches else None


async def vaults(client, _args):
    for v in await client.vaults.list():
        print(f"{v.id}  {v.title}")


async def vault_create(client, args):
    existing = await vault_by_title(client, args.title, required=False)
    if existing:
        print(f"vault {args.title!r} exists ({existing.id})")
        return
    vault = await client.vaults.create(
        VaultCreateParams(title=args.title, description=args.description, allow_admins_access=True)
    )
    print(f"created vault {args.title!r} ({vault.id})")


def permission_names(bits):
    names = [name for name, value in sorted(PERMISSIONS.items(), key=lambda kv: kv[1]) if bits & value]
    return ",".join(names) or "NO_ACCESS"


async def accessors(client, vault):
    detail = await client.vaults.get(vault.id, VaultGetParams(accessors=True))
    return detail.access or []


async def vault_access(client, args):
    """Who can open a vault: metadata only, never items."""
    vault = await vault_by_title(client, args.vault)
    for access in await accessors(client, vault):
        title = ""
        if access.accessor_type == VaultAccessorType.GROUP:
            group = await client.groups.get(access.accessor_uuid, GroupGetParams())
            title = f"  {group.title}"
        print(f"{access.accessor_type.value}  {access.accessor_uuid}{title}  {permission_names(access.permissions)}")


# Everything a person needs to use a vault in the app (the SDK grants groups only).
FULL_ACCESS = sum(PERMISSIONS[name] for name in (
    "MANAGE_VAULT", "READ_ITEMS", "REVEAL_ITEM_PASSWORD", "UPDATE_ITEMS", "CREATE_ITEMS",
    "ARCHIVE_ITEMS", "DELETE_ITEMS", "UPDATE_ITEM_HISTORY", "SEND_ITEMS", "IMPORT_ITEMS",
    "EXPORT_ITEMS", "PRINT_ITEMS",
))


async def vault_grant(client, args):
    """Give a group already listed on the vault full item access, then read it back."""
    vault = await vault_by_title(client, args.vault)
    groups = {}
    for access in await accessors(client, vault):
        if access.accessor_type == VaultAccessorType.GROUP:
            group = await client.groups.get(access.accessor_uuid, GroupGetParams())
            groups.setdefault(group.title, []).append(access)
    matches = groups.get(args.group, [])
    if len(matches) != 1:
        fail(f"group {args.group!r} is not listed exactly once on {args.vault!r}")
    access = matches[0]
    wanted = access.permissions | FULL_ACCESS
    if wanted != access.permissions:
        await client.vaults.update_group_permissions(
            [GroupVaultAccess(vault_id=vault.id, group_id=access.accessor_uuid, permissions=wanted)]
        )
    granted = {a.accessor_uuid: a.permissions for a in await accessors(client, vault)}
    if granted.get(access.accessor_uuid, 0) & wanted != wanted:
        fail(f"{args.group!r} did not receive full access on {args.vault!r}")
    print(f"{args.group!r} on {args.vault!r}: {permission_names(granted[access.accessor_uuid])}")


def fields_from_stdin():
    """Fields arrive on stdin as a JSON list of {title, type, value[, section]}."""
    try:
        specs = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        fail(f"stdin is not JSON: {error.msg}")
    if not isinstance(specs, list):
        fail("stdin must be a JSON list of fields")
    sections, fields = {}, []
    seen = set()
    for spec in specs:
        if not isinstance(spec, dict):
            fail("each field must be a JSON object")
        if not isinstance(spec.get("title"), str) or not isinstance(spec.get("value"), str):
            fail("each field must have a string title and value")
        section = spec.get("section")
        if section is not None and not isinstance(section, str):
            fail("each field's section must be a string or null")
        try:
            field_type = ItemFieldType(spec.get("type", "Concealed"))
        except (TypeError, ValueError):
            fail(f"invalid type for field {spec['title']!r}")
        key = (section or "", spec["title"])
        if key in seen:
            fail(f"duplicate field {spec['title']!r} in stdin")
        seen.add(key)
        if section:
            sections.setdefault(section, ItemSection(id=section, title=section))
        fields.append(
            ItemField(
                id=spec["title"],
                title=spec["title"],
                section_id=section,
                field_type=field_type,
                value=spec["value"],
            )
        )
    return fields, list(sections.values())


async def item_create(client, args):
    vault = await vault_by_title(client, args.vault)
    if await item_by_title(client, vault, args.title):
        fail(f"item {args.title!r} already exists in {args.vault!r}; not overwriting")
    fields, sections = fields_from_stdin()
    item = await client.items.create(
        ItemCreateParams(
            category=ItemCategory(args.category),
            vault_id=vault.id,
            title=args.title,
            fields=fields,
            sections=sections or None,
            notes=args.notes,
        )
    )
    print(f"created {args.title!r} in {args.vault!r} ({item.id}, {len(item.fields)} fields)")


def differing_fields(source, copy):
    """Titles of source fields whose value the copy does not carry, by (section, title)."""
    key = lambda f: (f.section_id or "", f.title)
    copied = {key(f): f.value for f in copy.fields}
    return [f.title for f in source.fields if copied.get(key(f)) != f.value]


async def item_edit(client, args):
    vault = await vault_by_title(client, args.vault)
    overview = await item_by_title(client, vault, args.title)
    if overview is None:
        fail(f"no item {args.title!r} in {args.vault!r}")
    item = await client.items.get(vault.id, overview.id)
    fields, sections = fields_from_stdin()
    section_ids = {s.title: s.id for s in item.sections}
    used_section_ids = {s.id for s in item.sections}
    new_sections = []
    for section in sections:
        if section.title not in section_ids:
            while section.id in used_section_ids:
                section.id = uuid4().hex
            used_section_ids.add(section.id)
            section_ids[section.title] = section.id
            new_sections.append(section)
    for field in fields:
        if field.section_id:
            field.section_id = section_ids[field.section_id]
    existing = {(f.section_id or "", f.title): f for f in item.fields}
    conflicts = [f.title for f in fields if (f.section_id or "", f.title) in existing]
    if conflicts and not args.replace:
        fail(f"fields already exist: {', '.join(conflicts)}; use --replace")
    used_field_ids = {f.id for f in item.fields}
    added, replaced = 0, 0
    for field in fields:
        previous = existing.get((field.section_id or "", field.title))
        if previous is not None:
            previous.value = field.value
            previous.field_type = field.field_type
            replaced += 1
        else:
            while field.id in used_field_ids:
                field.id = uuid4().hex
            used_field_ids.add(field.id)
            item.fields.append(field)
            added += 1
    item.sections.extend(new_sections)
    submitted = item.model_copy(update={"fields": [f.model_copy() for f in fields]})
    await client.items.put(item)
    written = await client.items.get(vault.id, item.id)
    differing = differing_fields(submitted, written)
    if differing:
        fail(f"{args.title!r} in {args.vault!r} differs from the submitted fields: {', '.join(differing)}")
    print(f"edited {args.title!r} in {args.vault!r}: {added} added, {replaced} replaced, verified")


async def copy_verified(client, source_title, title, target_title):
    """Copy `title` unless the target already has it, then verify every field.

    Returns (source_vault, source_overview). Fails, leaving the source untouched,
    if the target copy does not carry every source value.
    """
    source_vault = await vault_by_title(client, source_title)
    target_vault = await vault_by_title(client, target_title)
    overview = await item_by_title(client, source_vault, title)
    if overview is None:
        fail(f"no item {title!r} in {source_title!r}")
    source = await client.items.get(source_vault.id, overview.id)
    existing = await item_by_title(client, target_vault, title)
    if existing is None:
        copy = await client.items.create(
            ItemCreateParams(
                category=source.category,
                vault_id=target_vault.id,
                title=source.title,
                fields=[
                    ItemField(
                        id=f.id,
                        title=f.title,
                        section_id=f.section_id,
                        field_type=f.field_type,
                        value=f.value,
                        details=f.details,
                    )
                    for f in source.fields
                ],
                sections=source.sections,
                notes=source.notes,
                tags=source.tags,
                websites=source.websites,
            )
        )
        action, target_id = "copied", copy.id
    else:
        action, target_id = "already present", existing.id
    written = await client.items.get(target_vault.id, target_id)
    differing = differing_fields(source, written)
    if differing:
        fail(f"{title!r} in {target_title!r} ({action}) differs from the source: {', '.join(differing)}")
    print(f"{title!r} {action} in {target_title!r} ({target_id}), {len(source.fields)} fields verified")
    return source_vault, overview


async def item_copy(client, args):
    await copy_verified(client, args.source_vault, args.title, args.target_vault)


async def item_move(client, args):
    source_vault, overview = await copy_verified(client, args.source_vault, args.title, args.target_vault)
    await client.items.delete(source_vault.id, overview.id)
    print(f"deleted {args.title!r} from {args.source_vault!r}")


async def items(client, args):
    vault = await vault_by_title(client, args.vault)
    for i in sorted(await client.items.list(vault.id), key=lambda i: i.title):
        print(f"{i.id}  {i.category}  {i.title}")


async def vault_delete(client, args):
    vault = await vault_by_title(client, args.vault)
    remaining = await client.items.list(vault.id)
    if remaining:
        fail(f"vault {args.vault!r} still holds {len(remaining)} item(s); move them first")
    await client.vaults.delete(vault.id)
    print(f"deleted empty vault {args.vault!r} ({vault.id})")


def main():
    parser = argparse.ArgumentParser(prog="onepassword-sa", description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("vaults", help="list vault ids and titles")

    p = commands.add_parser("vault-create", help="create a vault (idempotent)")
    p.add_argument("title")
    p.add_argument("--description")

    p = commands.add_parser("vault-access", help="list a vault's users and groups (metadata only)")
    p.add_argument("vault")

    p = commands.add_parser("vault-grant", help="give a group on the vault full item access")
    p.add_argument("vault")
    p.add_argument("group", help="group title already listed by vault-access, e.g. Owners")

    p = commands.add_parser("item-create", help="create an item; fields as JSON on stdin")
    p.add_argument("--vault", required=True)
    p.add_argument("--title", required=True)
    p.add_argument("--category", default="SecureNote",
                   choices=[c.value for c in ItemCategory])
    p.add_argument("--notes")

    p = commands.add_parser("item-edit", help="add or replace item fields as JSON on stdin, then verify")
    p.add_argument("--vault", required=True)
    p.add_argument("--title", required=True)
    p.add_argument("--replace", action="store_true")

    p = commands.add_parser("item-copy", help="copy an item between vaults and verify it")
    p.add_argument("source_vault")
    p.add_argument("title")
    p.add_argument("target_vault")

    p = commands.add_parser("item-move",
                            help="copy an item, verify every field, then delete the source")
    p.add_argument("source_vault")
    p.add_argument("title")
    p.add_argument("target_vault")

    p = commands.add_parser("items", help="list a vault's item ids, categories and titles")
    p.add_argument("vault")

    p = commands.add_parser("vault-delete", help="delete a vault that holds no items")
    p.add_argument("vault")

    args = parser.parse_args()
    handler = {"vaults": vaults, "vault-create": vault_create,
               "vault-access": vault_access, "vault-grant": vault_grant,
               "item-create": item_create, "item-edit": item_edit, "item-copy": item_copy,
               "item-move": item_move, "items": items,
               "vault-delete": vault_delete}[args.command]

    async def run():
        await handler(await connect(), args)

    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as error:
        # SDK errors (quota, permission, unknown vault) as one line, no traceback.
        fail(f"{type(error).__name__}: {error}")


if __name__ == "__main__":
    main()
