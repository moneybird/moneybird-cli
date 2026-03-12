# moneybird-cli

A command-line interface for the [Moneybird](https://www.moneybird.com) API. Instead of hardcoding logic for each endpoint, the CLI reads the [OpenAPI spec](https://github.com/moneybird/openapi) at runtime to resolve commands, generate help, and map parameters. Changes to the API spec automatically update the CLI's capabilities.

## Install

**Quick install** (requires `curl` and `jq`):

```bash
git clone https://github.com/moneybird/moneybird-cli.git ~/.moneybird-cli
ln -s ~/.moneybird-cli/moneybird-cli /usr/local/bin/moneybird-cli
```

Or with a one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/moneybird/moneybird-cli/main/install.sh | bash
```

### Dependencies

- `bash` 3.2+ (macOS default works)
- `curl`
- `jq` — install with `brew install jq` (macOS) or `apt install jq` (Linux)

## Getting started

### 1. Authenticate

Create a personal API token in Moneybird under **Settings > Developer > API tokens**, then:

```bash
moneybird-cli login <your-token>
```

### 2. Select an administration

```bash
moneybird-cli administrations list
moneybird-cli administration use <id>
```

### 3. Start using the API

```bash
moneybird-cli contacts list
moneybird-cli sales_invoices get <id>
moneybird-cli contacts create --company_name "Acme Corp"
```

## Usage

```
moneybird-cli [options] <resource> <action> [id] [--param value...]
```

### Actions

Standard CRUD actions work on any resource that supports them:

| Action   | Description              |
|----------|--------------------------|
| `list`   | List all records         |
| `get`    | Get a single record      |
| `create` | Create a new record      |
| `update` | Update an existing record|
| `delete` | Delete a record          |

Custom actions (like `send_invoice`, `register_payment`, `archive`) are discovered automatically from the API spec.

### Options

| Flag | Description |
|------|-------------|
| `--output <mode>` | Output format: `raw`, `pretty` (default), `table` |
| `--fields <f1,f2>` | Return only specified fields (supports nested: `contact.company_name`) |
| `--select <jq>` | Filter response with a jq expression |
| `--all` | Auto-paginate and return all results |
| `--dry-run` | Show the request without executing |
| `--verbose` | Show debug information |
| `--administration <id>` | Override the current administration |
| `--dev` | Target moneybird.dev instead of moneybird.com |

### Help

Every level has built-in help generated from the API spec:

```bash
moneybird-cli --help                    # List all resources
moneybird-cli contacts --help           # List actions for contacts
moneybird-cli contacts create --help    # List parameters for creating a contact
```

## Examples

```bash
# List all contacts as a table
moneybird-cli contacts list --output table

# Get a specific invoice with only a few fields
moneybird-cli sales_invoices get 123456 --fields id,invoice_id,total_price_incl_tax,state

# Create a contact
moneybird-cli contacts create --company_name "Acme Corp" --email "info@acme.com"

# Send an invoice via email
moneybird-cli sales_invoices send_invoice 123456 --delivery_method Email

# Fetch all invoices (auto-paginate)
moneybird-cli sales_invoices list --all --fields id,invoice_id,total_price_incl_tax

# Filter with jq
moneybird-cli contacts list --select '[.[] | select(.company_name | test("Acme"))]'

# Sub-resources
moneybird-cli contacts:notes list 123456

# Dry run to inspect the request
moneybird-cli sales_invoices create --dry-run --contact_id 789 --reference "Test"
```

## How it works

The CLI downloads and caches the Moneybird OpenAPI spec (`~/.config/moneybird-cli/openapi.json`). All routing, help generation, parameter discovery, and request body wrapping are derived from this spec at runtime using `jq`.

```
moneybird-cli contacts create --company_name "Acme"
         │         │       │              │
         │         │       │              └─ Wrapped as {"contact": {"company_name": "Acme"}}
         │         │       │                 (wrapper key from spec's requestBody schema)
         │         │       │
         │         │       └─ Mapped to POST (from CRUD convention, validated against spec)
         │         │
         │         └─ Resolved to /api/v2/{administration_id}/contacts.json
         │
         └─ Resource lookup in spec paths
```

## Configuration

Config is stored in `~/.config/moneybird-cli/`:

| File | Purpose |
|------|---------|
| `config.json` | Administration ID, client credentials, preferences |
| `tokens_*.json` | Access tokens (per host) |
| `openapi.json` | Cached API spec |

Override the config directory with `MONEYBIRD_CONFIG_DIR`.

## Shell completion

Add to your shell profile for tab completion of resources, actions, and parameters:

```bash
eval "$(moneybird-cli completion bash)"   # ~/.bashrc
eval "$(moneybird-cli completion zsh)"    # ~/.zshrc
```

## License

MIT
