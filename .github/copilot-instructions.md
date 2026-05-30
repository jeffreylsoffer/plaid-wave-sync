# Copilot instructions — plaid-wave-sync setup helper

You are helping a (often non-developer) user get this repo's **Plaid → Wave** bank-transaction
sync working, usually inside a GitHub Codespace. `setup.sh` is the source of truth for the steps.
Your job: **drive setup step by step and unblock errors**, acting as an interactive guide.

## How to behave
- **Do not blind-run `./setup.sh`.** It blocks on interactive input you can't provide (browser
  login, pasted URLs, menu choices) and will stall. Instead, prefer to run the discrete commands
  below yourself, pausing to ask the user for inputs. If matching/assembly gets fiddly, fall back
  to having the **user** run `./setup.sh` in the terminal while you explain each prompt and tell
  them exactly what to type.
- **Pause and ask the human for the things only they can do:** logging into Plaid in a browser /
  connecting a bank, choosing which Wave business, mapping a bank account to a Wave account, and
  pasting their Plaid Client ID + Secret and Wave Full Access Token.
- **Always confirm before** running `gh secret set` or changing repo visibility.
- Work one step at a time and verify before moving on. Keep guidance short and concrete
  ("type `2` and press Enter").
- **Never echo full secret values or `access-production-…` tokens** back to the user.

## Architecture (so your advice is correct)
- The daily sync runs as a **GitHub Action on the user's fork**, using the fork's code + the
  fork's **repository** secrets. The Codespace is only for setup.
- So: code updates must reach the fork's `main` (GitHub "Sync fork" or `./update.sh`), and secrets
  must be **Repository** secrets — NOT Environment secrets (the workflow has no `environment:`).
- Python is provided **only by `uv`** — there is no system `python3` and no virtualenv. Always run
  Python via `uv run` (e.g. `uv run python3 …`, `uv run plaid_sync.py …`).

## Steps (mirror setup.sh)
1. **Tools:** `uv`, `plaid`, `gh`. A non-zero Homebrew exit is usually benign — confirm with
   `command -v plaid`.
2. **Plaid creds:** simplest is to ask for their **Client ID + Production Secret**
   (https://dashboard.plaid.com/developers/keys) and run
   `plaid config set --client-id <id> --secret <secret> --env production`. The browser
   `plaid login` flow is the alternative.
3. **Connect a bank:** `uv run plaid_sync.py --add-bank` opens a Hosted Link URL the user finishes
   in a browser. **If their Plaid trial is used up**, instead ask for an existing
   `access-production-…` token + its account (name, last-4, checking/credit) — reading an existing
   item does NOT consume trial connections.
4. **Wave:** ask for the **Full Access Token** (https://developer-apps.waveapps.com). If there are
   multiple businesses, list them and let the user pick the `WAVE_BUSINESS_ID`. Then run
   `uv run scripts/match_accounts.py` (needs `/tmp/plaid-tokens-all.jsonl`, `WAVE_ACCESS_TOKEN`,
   `WAVE_BUSINESS_ID`). It auto-matches by account mask; for anything unmatched, show the numbered
   Wave-account list and let the user choose. Final value `PLAID_ACCESS_TOKENS` is comma-separated
   `Name:token:Wave Account Name:type[:account_id]` (`type` = `checking` or `credit_card`).
5. **Keywords:** have the user export Wave → Reports → Account Transactions (General Ledger) as CSV
   into `imports/`, then `uv run scripts/build_keywords.py <csv>`.
6. **Save + test:** with the user's OK, `gh secret set` each of `PLAID_CLIENT_ID`, `PLAID_SECRET`,
   `WAVE_ACCESS_TOKEN`, `WAVE_BUSINESS_ID`, `PLAID_ACCESS_TOKENS` (Repository secrets). If `gh`
   lacks scope: `unset GITHUB_TOKEN GH_TOKEN; gh auth login -s repo`. Then
   `gh workflow enable sync.yml` and `gh workflow run sync.yml -f dry_run=true`.

## Common errors → fixes
- `python3: command not found` → use `uv run python3` / `uv run <script>.py`.
- `Installing Homebrew (failed)` but plaid works → benign post-install refresh; ignore.
- No Plaid login link → it prints *after* pressing Enter; or `cat /tmp/plaid-login.log` to find the `https://` URL.
- Stuck at a "paste PLAID_ACCESS_TOKENS" prompt → matching produced nothing; connect a bank or paste an existing token (option `p`), then re-run matching.
- `PLAID_SECRET` empty / unrecognized in the Action → saved empty or as an Environment secret; re-save as a **Repository** secret.
- Action runs old code after updating the Codespace → Codespace ≠ fork; run `./update.sh` or GitHub "Sync fork".
- Bank token expired (`ITEM_LOGIN_REQUIRED`) → `uv run plaid_sync.py --reauth`.

## Verify
Success = a dry run passes and writes nothing: `uv run plaid_sync.py --dry-run --days 30`.
Confirm transactions are categorized and the summary shows `errors=0`.
