# plaid-wave-sync

Automatically sync bank transactions from [Plaid](https://plaid.com) → [Wave](https://www.waveapps.com) accounting. No Wave Pro subscription necessary.

- **Keyword-based categorization** — auto-generated from your previous year's general ledger
- **Deduplication** — safe to re-run anytime (uses Plaid transaction IDs)
- **Credit card support** — handles both checking and CC accounts
- **Invoice matching** — auto-marks invoices as paid when deposits match
- **GitHub Actions ready** — runs daily on a schedule, zero infrastructure

---

## Setup (5 minutes)

### Step 1 → Create your own private copy

[![Use this template](https://img.shields.io/badge/1-Use_this_template_→-238636?style=for-the-badge&logo=github)](../../generate)

Click the button, then **set the repository to Private**. This creates your own
independent copy — not a fork.

> **Why a template, not a fork?** Forks of a public repo can't be made private,
> so your Action logs would be public. A private template copy keeps them private.

### Step 2 → Open in Codespaces

On **your new private repo**, click **Code → Codespaces → Create codespace**.

The setup script runs automatically and walks you through everything:
- Creates your Plaid account & activates trial (10 free bank connections)
- Connects your bank accounts via Plaid Hosted Link
- Shows your Wave accounts and matches them to your banks
- Generates keyword mappings from your Wave general ledger CSV
- Saves all secrets to your repo
- Enables the workflow and triggers a test run

Once setup completes, close the Codespace — everything runs automatically from there.

> **Prefer the command line?** One command does it all (creates a private repo
> from the template and clones it):
> ```bash
> gh repo create plaid-wave-sync --private \
>   --template jeffreylsoffer/plaid-wave-sync --clone
> cd plaid-wave-sync && ./setup.sh
> ```

---

## Usage

```bash
# Preview what would sync
uv run plaid_sync.py --dry-run --days 30

# Sync for real
uv run plaid_sync.py --days 30

# Weekly reconciliation check
uv run plaid_sync.py --reconcile --days 7

# Validate your keyword mappings
uv run plaid_sync.py --dump-accounts
```

## How It Works

```
Plaid (bank)              keywords.json           Wave (accounting)
     │                         │                        │
     │  fetch transactions     │  categorize            │  create entries
     ├────────────────────────►├───────────────────────►│
     │                         │                        │
     │  positive = expense     │  keyword match → acct  │  deduped by
     │  negative = income      │  no match → fallback   │  transaction_id
```

- **Checking accounts**: Plaid positive = money out (expense), negative = money in (income)
- **Credit cards**: Plaid positive = charge (expense), negative = payment/refund
- **Invoices**: Income deposits are auto-matched to open invoices by customer name + amount
- **Duplicates**: Silently skipped via `externalId` — safe to re-run anytime

## Commands

| Flag | Description |
|------|-------------|
| `--days N` | Sync last N days (default: 30) |
| `--dry-run` | Preview without writing to Wave |
| `--reconcile` | Compare Plaid totals for the period |
| `--dump-accounts` | Show Wave accounts + validate keywords |
| `--add-bank` | Connect a new bank via Plaid Hosted Link |
| `--debug` | Verbose logging |

## Deployment Options

| Platform | How |
|----------|-----|
| **GitHub Actions** (recommended) | Use template (Private) → setup → done. Runs daily at 9am ET. |
| **Any VPS / cron** | `0 13 * * * cd /path && uv run plaid_sync.py --days 3` (9am ET / 1pm UTC) |

## FAQ

**What if a transaction doesn't match any keyword?**
Goes to your fallback account (set in `keywords.json`). Review in Wave weekly, add keywords as patterns emerge.

**Is it safe to run multiple times?**
Yes. Duplicates are silently skipped.

**What if my bank token expires?**
The script generates a Plaid Hosted Link URL for re-auth. Open it in any browser, log in, done. Token stays the same.

**What about credit card bill payments?**
CC payments (transfers between checking and CC) can't be recorded via Wave's API as inter-account transfers. They go to "Uncategorized Expense" for you to recategorize in Wave as a CC payment. This is the same as Wave's native bank sync. All actual CC charges sync correctly as expenses.

## Requirements

- Python 3.11+
- [uv](https://docs.astral.sh/uv/)
- Plaid account (trial = 10 free connections)
- Wave account with API access

## License

MIT
