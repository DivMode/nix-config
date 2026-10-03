"""1Password vault and item writes through the service account, without the CLI.

The approved write interface for agents: it authenticates only with the cached
service-account token (never Connect, the desktop app, or a signed-in session),
takes secret values on stdin (never argv), and has no command that prints a
secret. Reads happen only inside `item-copy`, to verify the copy.
"""

import argparse
import asyncio
import json
import os
import sys

from onepassword.client import Client
from onepassword.types import (
    ItemCategory,
    ItemCreateParams,
    ItemField,
    ItemFieldType,
    ItemSection,
    VaultCreateParams,
)


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


async def item_create(client, args):
    """Fields arrive on stdin as a JSON list of {title, type, value[, section]}."""
    vault = await vault_by_title(client, args.vault)
    if await item_by_title(client, vault, args.title):
        fail(f"item {args.title!r} already exists in {args.vault!r}; not overwriting")
    try:
        specs = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        fail(f"stdin is not JSON: {error.msg}")
    sections, fields = {}, []
    for spec in specs:
        section = spec.get("section")
        if section:
            sections.setdefault(section, ItemSection(id=section, title=section))
        fields.append(
            ItemField(
                id=spec["title"],
                title=spec["title"],
                section_id=section,
                field_type=ItemFieldType(spec.get("type", "Concealed")),
                value=spec["value"],
            )
        )
    item = await client.items.create(
        ItemCreateParams(
            category=ItemCategory(args.category),
            vault_id=vault.id,
            title=args.title,
            fields=fields,
            sections=list(sections.values()) or None,
            notes=args.notes,
        )
    )
    print(f"created {args.title!r} in {args.vault!r} ({item.id}, {len(item.fields)} fields)")


async def item_copy(client, args):
    source_vault = await vault_by_title(client, args.source_vault)
    target_vault = await vault_by_title(client, args.target_vault)
    overview = await item_by_title(client, source_vault, args.title)
    if overview is None:
        fail(f"no item {args.title!r} in {args.source_vault!r}")
    if await item_by_title(client, target_vault, args.title):
        print(f"{args.title!r} already in {args.target_vault!r}; not overwriting")
        return
    source = await client.items.get(source_vault.id, overview.id)
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
    written = await client.items.get(target_vault.id, copy.id)
    key = lambda f: (f.section_id or "", f.title)
    copied = {key(f): f.value for f in written.fields}
    differing = [title for (_, title), value in ((key(f), f.value) for f in source.fields)
                 if copied.get(key(f)) != value]
    if differing:
        fail(f"copied {args.title!r} but fields differ: {', '.join(differing)}")
    print(f"copied {args.title!r} to {args.target_vault!r} ({copy.id}), {len(source.fields)} fields verified")


def main():
    parser = argparse.ArgumentParser(prog="onepassword-sa", description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("vaults", help="list vault ids and titles")

    p = commands.add_parser("vault-create", help="create a vault (idempotent)")
    p.add_argument("title")
    p.add_argument("--description")

    p = commands.add_parser("item-create", help="create an item; fields as JSON on stdin")
    p.add_argument("--vault", required=True)
    p.add_argument("--title", required=True)
    p.add_argument("--category", default="SecureNote",
                   choices=[c.value for c in ItemCategory])
    p.add_argument("--notes")

    p = commands.add_parser("item-copy", help="copy an item between vaults and verify it")
    p.add_argument("source_vault")
    p.add_argument("title")
    p.add_argument("target_vault")

    args = parser.parse_args()
    handler = {"vaults": vaults, "vault-create": vault_create,
               "item-create": item_create, "item-copy": item_copy}[args.command]

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
