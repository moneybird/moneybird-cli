---
name: moneybird-cli
description: Use the Moneybird API from the command line to read, create, and modify accounting data — contacts, sales invoices, estimates, purchase invoices, payments, products, documents, time entries, and more. Trigger on any task that mentions Moneybird, invoicing, accounting records, administrations, or when the user asks to look up, create, or update business/financial data in Moneybird.
---

# moneybird-cli

The `moneybird-cli` binary is on PATH when this plugin is installed. It reads the [Moneybird OpenAPI spec](https://github.com/moneybird/openapi) at runtime, so every resource and action in the public API is callable without the CLI needing to be updated.

## Shape of every command

```
moneybird-cli [global-options] <resource> <action> [id] [--param value...]
```

Examples:

```bash
moneybird-cli contacts list
moneybird-cli sales_invoices get 123456
moneybird-cli contacts create --company_name "Acme Corp" --email "info@acme.com"
moneybird-cli sales_invoices send_invoice 123456 --delivery_method Email
```

## Discovery — always prefer `--help` over guessing

The CLI generates help for every level from the spec. When you're unsure of a resource name, action, or parameter, ask the CLI:

```bash
moneybird-cli --help                          # list all resources
moneybird-cli contacts --help                 # list actions on contacts
moneybird-cli contacts create --help          # list parameters for creating a contact
```

This is faster and more accurate than guessing. Do this before writing a command for an unfamiliar resource.

## Standard actions (CRUD)

`list`, `get`, `create`, `update`, `delete` work on any resource that supports them. Custom actions like `send_invoice`, `register_payment`, `archive` are discovered from the spec — check `<resource> --help`.

## Output flags — make responses agent-parseable

- `--output raw` — raw JSON. Use this when piping into `jq` or parsing the result.
- `--output table` — compact tabular view. Good for quick human-readable scans.
- `--output pretty` — default, colorized JSON.
- `--fields id,company_name,email` — limit response fields (supports dotted paths like `contact.company_name`).
- `--select '<jq>'` — apply a jq expression to the response server-side.

Prefer `--output raw --fields ...` or `--select` when you only need specific values — this keeps context small.

## Authentication

The user authenticates once with `moneybird-cli login <token>` (or `--oauth`). Sessions are stored per administration. Switch with `moneybird-cli administration use <id>` and inspect with `moneybird-cli administration list` / `administration current`.

If a command returns "Not logged in" or "No administration selected", stop and tell the user to run `moneybird-cli login <token>` — do not attempt to work around it.

In Claude Cowork, the config is auto-detected from `.moneybird-cli/` in the workspace folder if the user has placed it there.

## Safe-by-default patterns

- **Use `--dry-run` for any write action while exploring.** It prints the exact HTTP request without sending it. Always dry-run `create`, `update`, `delete`, and custom mutating actions (`send_invoice`, `register_payment`, etc.) before executing when the consequences are non-trivial.
- **Read before you write.** Use `get`/`list` with `--fields` to confirm IDs and current state before modifying records.
- **Respect administration boundaries.** Verify `moneybird-cli administration current` matches the intended administration before making changes. Override per-command with `--administration <id>` when needed.

## Sub-resources and nested routes

Nested resources use colon notation:

```bash
moneybird-cli contacts:notes create 123456 --note "Called about invoice"
```

`--help` at the parent resource lists available sub-resources.

## Common pitfalls

- **Wrapper keys are automatic.** You pass `--company_name "Acme"`, the CLI wraps it as `{"contact": {"company_name": "Acme"}}` based on the spec. Don't pass pre-wrapped JSON.
- **JSON values for arrays/objects.** To pass structured values, use JSON literals: `--details_attributes '[{"description":"Item","price":10}]'`. The CLI detects JSON that starts with `[`, `{`, a digit, `true`, `false`, or `null`.
- **Unknown parameters are silently ignored by the API.** The CLI warns when a `--flag` isn't declared in the spec for that endpoint. Pay attention to those warnings.

## When to reach for this CLI

Use `moneybird-cli` whenever the task is:

- Looking up or listing Moneybird records (invoices, contacts, estimates, payments, products, documents, time entries, financial accounts)
- Creating or modifying Moneybird records
- Running administrative actions (sending invoices, registering payments, archiving)
- Scripting workflows across multiple resources

Do not use it for: Moneybird's web-app-only features (custom reports, user management UI flows), or tasks that need API endpoints not yet in the OpenAPI spec.
