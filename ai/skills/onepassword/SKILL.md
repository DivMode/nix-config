---
name: onepassword
description: Store, update, read, delete or organise 1Password credentials on this Mac through the self-hosted Connect server. Use whenever the owner hands you a credential (an API token, key pair, password) to keep, a task needs a secret stored or rotated in a vault, or you need to know which commands may touch 1Password.
---

# 1Password through Connect

Everything goes through the self-hosted Connect server. Never run `op` for
item data, never use the desktop app or a signed-in session, and never read the
Connect environment file yourself: the commands below read it.

## Store or update a credential

When the owner gives you a credential, store it yourself. Do not ask them to.

1. Write the fields to a JSON file in the session scratchpad, created with mode
   0600 (`umask 077` before writing). Values never go in argv.

   ```json
   {
     "category": "API_CREDENTIAL",
     "fields": [
       {"label": "account_id", "type": "STRING", "value": "..."},
       {"label": "api_token", "type": "CONCEALED", "value": "..."}
     ]
   }
   ```

   Types: `STRING`, `CONCEALED` (the default), `EMAIL`, `URL`, `OTP`, `PHONE`.
   Use the labels the consuming code reads, exactly; a loader that requires a
   concealed field rejects a `STRING` one.

   When the consumer reads one of the category's built-in fields, also give
   its `"id"` (`"credential"` for `API_CREDENTIAL`, `"password"` for `LOGIN`).
   Without it Connect stores a custom field with a generated id: a reader that
   matches labels finds it, but one that reads built-in fields by id, such as
   the 1Password Pulumi provider, does not. Check how the consumer reads the
   item, or copy the shape of a sibling item it already reads.

   When the owner should be able to fill the value into a web page, make it a
   `LOGIN` item and add `"urls": ["http://..."]` (first one primary): the
   browser extension never fills an `API_CREDENTIAL` into a page.

2. Run `nix-config-connect-item put VAULT "TITLE" FILE`. VAULT is the vault's ID
   or exact name. An existing item with that title gets the listed fields
   replaced or added and keeps the rest; otherwise a new item is created
   (`category` applies only then). It reads the item back until every value
   matches and prints only the item ID and labels.

3. Delete the file with its own plain `rm`.

4. Confirm through the consuming repository's own loader when it has one (for
   example a script that lists an item's labels and types), not by printing
   values.

If Connect answers 403 for the vault, the Connect token lacks write access
there: say so; `nix-config-connect-rotate --add-vault VAULT` issues a token
covering a new vault, with the owner's approval.

## Find an item

`nix-config-connect-item find TEXT` lists the items, in every vault Connect
reaches, whose title or website contains TEXT: vault, item ID, category,
dates and websites, never a field value. Items in vaults the Connect token
cannot read (the owner's personal vault among them) do not appear.

## Delete an item

Deleting an item is the owner's call: do it only when they have authorized
that specific item. Then run `nix-config-connect-item delete VAULT "TITLE"`. It
refuses unless exactly one item in VAULT has that title, deletes it, reads it
back until Connect no longer has it, and prints only the vault and item ID. A
403 means the Connect token lacks delete access to the vault: say so, and do
not reach for another credential.

## Read a credential

Use the repository's own loader for the task (its deploy script or Connect
client). Never print a secret value; check labels, types or a hash instead.

## Vault administration

`nix-config-op-admin vault create NAME` and `nix-config-op-admin item move ITEM
--current-vault A --destination-vault B` run as the vault-admin service account
without a prompt. Connect administration is `nix-config-connect-rotate`.
Deleting vaults is the owner's call: ask first.
