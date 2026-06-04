#!/usr/bin/env bash
# No set -e — we handle errors explicitly with fallbacks

# ─── Fancy output helpers ─────────────────────────────────────────────────────

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

spinner() {
    local pid=$1 msg=$2
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}${frames[$i]}${NC} ${msg}"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.1
    done
    wait "$pid" 2>/dev/null
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        printf "\r  ${GREEN}✓${NC} ${msg}\n"
    else
        printf "\r  ${RED}✗${NC} ${msg} (failed)\n"
    fi
    return 0
}

step() {
    echo ""
    echo -e "${BOLD}${CYAN}▶ $1${NC}"
    echo ""
}

success() {
    echo -e "  ${GREEN}✓${NC} $1"
}

warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

info() {
    echo -e "  ${DIM}$1${NC}"
}

# Extract production client_id/secret from plaid-cli config (tab-separated).
# Walks the JSON and prefers any path containing "production" so we never grab
# a sandbox/development secret by accident.
read_plaid_creds() {
    [ -f ~/.config/plaid-cli/config.json ] || return 1
    uv run python3 - "$HOME/.config/plaid-cli/config.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
best = {}
def walk(o, prod):
    if isinstance(o, dict):
        cid, sec = o.get('client_id'), o.get('secret')
        if cid or sec:
            slot = best.setdefault('prod' if prod else 'any', {})
            if cid: slot.setdefault('client_id', cid)
            if sec: slot.setdefault('secret', sec)
        for k, v in o.items():
            walk(v, prod or 'production' in str(k).lower())
    elif isinstance(o, list):
        for v in o: walk(v, prod)
walk(d, False)
c = best.get('prod') or best.get('any') or {}
print((c.get('client_id') or '') + '\t' + (c.get('secret') or ''))
PY
}

# Validate Plaid production credentials. Returns non-zero only when Plaid
# explicitly rejects them (400/401/403) so transient/offline errors don't block.
validate_plaid_creds() {
    local cid="$1" sec="$2" code
    [ -z "$cid" ] || [ -z "$sec" ] && return 1
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
        --data-raw "{\"client_id\":\"$cid\",\"secret\":\"$sec\",\"country_codes\":[\"US\"],\"count\":1,\"offset\":0}" \
        "https://production.plaid.com/institutions/get" 2>/dev/null || echo "000")
    case "$code" in 400|401|403) return 1 ;; *) return 0 ;; esac
}

# ─── Header ───────────────────────────────────────────────────────────────────

clear
echo ""
echo -e "${BOLD}  ╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ║     ${CYAN}plaid-wave-sync${NC}${BOLD} setup              ║${NC}"
echo -e "${BOLD}  ║     Plaid → Wave in 5 minutes           ║${NC}"
echo -e "${BOLD}  ╚══════════════════════════════════════════╝${NC}"
echo ""

# ─── Codespaces check ─────────────────────────────────────────────────────────

if [ -n "$CODESPACES" ]; then
    REPO_SLUG=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)
    if [ "$REPO_SLUG" = "jeffreylsoffer/plaid-wave-sync" ]; then
        echo -e "${RED}${BOLD}  ERROR: You opened a Codespace on the upstream repo.${NC}"
        echo ""
        echo -e "  You need to ${BOLD}fork first${NC}, then open a Codespace on your fork:"
        echo -e "  1. Go to ${CYAN}https://github.com/jeffreylsoffer/plaid-wave-sync${NC}"
        echo -e "  2. Click ${BOLD}Fork${NC} (top right)"
        echo -e "  3. On YOUR fork, click ${BOLD}Code → Codespaces → New codespace${NC}"
        echo ""
        echo -e "  This is required because secrets must be saved to a repo you own."
        echo ""
        exit 1
    fi
fi

# (repo privacy is set in Step 6 after gh auth)

# ─── Step 1: Install dependencies ─────────────────────────────────────────────

step "Step 1/6 · Installing tools"

if command -v plaid &>/dev/null; then
    success "Plaid CLI already installed"
else
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 NONINTERACTIVE=1
    if ! command -v brew &>/dev/null; then
        info "Installing Homebrew (this takes ~60s on first run)..."
        # Subshell exits 0 on purpose: the installer can exit non-zero on a benign
        # post-install metadata refresh (stale 'brew update' lock / SIGHUP) even though
        # brew itself installs fine. We verify real success via 'command -v' below.
        { /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null &>/tmp/brew-install.log; true; } &
        spinner $! "Installing Homebrew"
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" 2>/dev/null || true
        command -v brew &>/dev/null || warn "Homebrew may not have installed cleanly — see /tmp/brew-install.log"
    fi
    brew install plaid/plaid-cli/plaid &>/tmp/plaid-install.log &
    spinner $! "Installing Plaid CLI"
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" 2>/dev/null || true
    command -v plaid &>/dev/null || warn "Plaid CLI install failed — see /tmp/plaid-install.log"
fi

if command -v uv &>/dev/null; then
    success "uv already installed"
else
    curl -LsSf https://astral.sh/uv/install.sh | sh &>/dev/null &
    spinner $! "Installing uv"
    export PATH="$HOME/.local/bin:$PATH"
fi

if ! command -v gh &>/dev/null; then
    (curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null && \
    sudo apt-get update -qq && sudo apt-get install -y -qq gh) &>/tmp/gh-install.log &
    spinner $! "Installing GitHub CLI"
fi

# ─── Step 2: Plaid account ────────────────────────────────────────────────────

step "Step 2/6 · Plaid account"

if [ -f ~/.config/plaid-cli/config.json ] && grep -q '"client_id"' ~/.config/plaid-cli/config.json 2>/dev/null; then
    # Make sure correct team is selected
    TEAM_ID=$(plaid teams list 2>/dev/null | grep '\*' | awk '{print $2}')
    [ -z "$TEAM_ID" ] && TEAM_ID=$(plaid teams list 2>/dev/null | grep -i "Individual" | awk '{print $2}')
    [ -n "$TEAM_ID" ] && plaid teams use "$TEAM_ID" &>/dev/null
    plaid keys fetch &>/dev/null || true
    # Re-read production credentials after team switch
    CREDS=$(read_plaid_creds)
    export PLAID_CLIENT_ID=$(printf '%s' "$CREDS" | cut -f1)
    export PLAID_SECRET=$(printf '%s' "$CREDS" | cut -f2)
    if [ -n "$PLAID_CLIENT_ID" ]; then
        if validate_plaid_creds "$PLAID_CLIENT_ID" "$PLAID_SECRET"; then
            success "Already logged in (Client ID: $PLAID_CLIENT_ID)"
        else
            warn "Saved credentials are invalid for Production. Will prompt for manual entry."
            unset PLAID_CLIENT_ID PLAID_SECRET
        fi
    else
        # Config exists but no valid credentials — fall through to login
        unset PLAID_CLIENT_ID PLAID_SECRET
    fi
fi

if [ -z "$PLAID_CLIENT_ID" ]; then
    read -p "  Already have a Plaid Developer account? (y/n): " has_account
    if [ "$has_account" != "y" ]; then
        echo ""
        echo -e "  ${BOLD}1.${NC} Create your Plaid account:"
        echo -e "     ${CYAN}https://dashboard.plaid.com/signup${NC}"
        plaid register &>/dev/null || true
        echo ""
        read -p "  Done signing up? Press Enter..."
        echo ""
        echo -e "  ${BOLD}2.${NC} Activate trial plan (10 free connections):"
        echo -e "     ${CYAN}https://dashboard.plaid.com/trial-plan${NC}"
        plaid trial &>/dev/null || true
        echo ""
        read -p "  Done with trial? Press Enter..."
        echo ""
    fi

    echo -e "  ${BOLD}Log in to Plaid${NC} — press Enter and a login link will appear here."
    read -p "  Press Enter to generate your login link..."

    # Kill any stale plaid login processes
    pkill -f "plaid login" 2>/dev/null || true
    sleep 1

    plaid login &>/tmp/plaid-login.log &
    PLAID_PID=$!
    # Wait (up to ~20s) for the auth URL to be written to the log, then show it
    LOGIN_URL=""
    for _ in $(seq 1 40); do
        LOGIN_URL=$(grep -o 'https://[^ ]*' /tmp/plaid-login.log 2>/dev/null | head -1)
        [ -n "$LOGIN_URL" ] && break
        sleep 0.5
    done
    if [ -n "$LOGIN_URL" ]; then
        echo -e "\n  ${CYAN}${LOGIN_URL}${NC}\n"
    else
        warn "Couldn't capture the login URL automatically. Raw output below — open the https:// link:"
        sed 's/^/    /' /tmp/plaid-login.log
        echo ""
    fi

    echo -e "  Now:"
    echo -e "  1. ${BOLD}Cmd+Click${NC} (or Ctrl+Click) the link above and log in to Plaid"
    echo -e "  2. Your browser will fail on a ${BOLD}localhost${NC} URL — ${GREEN}that's expected${NC}"
    echo -e "  3. Copy that localhost URL and paste it below"
    echo ""
    read -p "  Paste the failed localhost URL: " callback_url
    while ! echo "$callback_url" | grep -q "localhost.*callback.*code="; do
        warn "That doesn't look right — need a URL like: http://localhost:.../oauth/callback?code=..."
        read -p "  Paste the URL (or 'q' to enter credentials manually): " callback_url
        [ "$callback_url" = "q" ] && break
    done
    if echo "$callback_url" | grep -q "localhost.*callback.*code="; then
        info "Sending callback to plaid login server..."
        curl -s "$callback_url" &>/dev/null &
        CURL_PID=$!
        sleep 5
        kill $CURL_PID 2>/dev/null || true
        kill $PLAID_PID 2>/dev/null || true
        wait $PLAID_PID 2>/dev/null || true
        wait $CURL_PID 2>/dev/null || true

        # Login succeeded — get credentials from config
        success "Logged in"
        TEAM_ID=$(plaid teams list 2>/dev/null | grep '\*' | awk '{print $2}')
        [ -z "$TEAM_ID" ] && TEAM_ID=$(plaid teams list 2>/dev/null | grep -i "Individual" | awk '{print $2}')
        [ -n "$TEAM_ID" ] && plaid teams use "$TEAM_ID" &>/dev/null
        plaid keys fetch &>/dev/null || true
        CREDS=$(read_plaid_creds)
        export PLAID_CLIENT_ID=$(printf '%s' "$CREDS" | cut -f1)
        [ -z "$PLAID_CLIENT_ID" ] && export PLAID_CLIENT_ID=$(plaid config 2>/dev/null | grep "Client ID" | awk '{print $NF}')
        export PLAID_SECRET=$(printf '%s' "$CREDS" | cut -f2)
        if validate_plaid_creds "$PLAID_CLIENT_ID" "$PLAID_SECRET"; then
            success "Client ID: $PLAID_CLIENT_ID"
        else
            warn "Production credentials from login are invalid. Enter them manually:"
            echo -e "  ${CYAN}https://dashboard.plaid.com/developers/keys${NC}"
            read -p "  Client ID: " PLAID_CLIENT_ID
            read -p "  Secret (Production): " PLAID_SECRET
            export PLAID_CLIENT_ID PLAID_SECRET
            plaid config set --client-id "$PLAID_CLIENT_ID" --secret "$PLAID_SECRET" --env production 2>/dev/null
            success "Credentials saved"
        fi
    else
        wait $PLAID_PID 2>/dev/null || true
        warn "Invalid URL. Let's enter credentials manually instead:"
        echo -e "  ${CYAN}https://dashboard.plaid.com/developers/keys${NC}"
        echo ""
        read -p "  Client ID: " PLAID_CLIENT_ID
        read -p "  Secret (Production): " PLAID_SECRET
        export PLAID_CLIENT_ID PLAID_SECRET
        while ! validate_plaid_creds "$PLAID_CLIENT_ID" "$PLAID_SECRET"; do
            warn "Those credentials didn't work. Check them at:"
            echo -e "  ${CYAN}https://dashboard.plaid.com/developers/keys${NC}"
            echo ""
            read -p "  Client ID (or 'q' to skip): " PLAID_CLIENT_ID
            [ "$PLAID_CLIENT_ID" = "q" ] && break
            read -p "  Secret (Production): " PLAID_SECRET
            export PLAID_CLIENT_ID PLAID_SECRET
        done
        plaid config set --client-id "$PLAID_CLIENT_ID" --secret "$PLAID_SECRET" --env production 2>/dev/null
        success "Credentials saved"
    fi

    echo ""
    if plaid keys fetch 2>/dev/null; then
        success "API keys saved"
    else
        # Auto-select first team and retry
        FIRST_TEAM=$(plaid teams list 2>/dev/null | awk 'NR==2 {print $2}')
        [ -n "$FIRST_TEAM" ] && plaid teams use "$FIRST_TEAM" 2>/dev/null
        if plaid keys fetch 2>/dev/null; then
            success "API keys saved"
        else
            warn "Couldn't fetch keys. Enter them manually:"
            echo -e "  ${CYAN}https://dashboard.plaid.com/developers/keys${NC}"
            echo ""
            read -p "  Client ID: " PLAID_CLIENT_ID
            read -p "  Secret (Production): " PLAID_SECRET
            export PLAID_CLIENT_ID PLAID_SECRET
            plaid config set --client-id "$PLAID_CLIENT_ID" --secret "$PLAID_SECRET" --env production 2>/dev/null
            success "Credentials saved"
        fi
    fi
fi

# ─── Step 3: Connect banks ────────────────────────────────────────────────────

step "Step 3/6 · Connect your bank accounts"

# Check if banks are already connected from a previous run
EXISTING_ITEMS=$(plaid item list 2>/dev/null | grep -c "access-" 2>/dev/null || true)
EXISTING_ITEMS=${EXISTING_ITEMS:-0}
if [ "$EXISTING_ITEMS" -gt "0" ]; then
    success "Found $EXISTING_ITEMS connected bank(s):"
    plaid item list 2>/dev/null | grep -v "^$" | while read -r line; do echo -e "    $line"; done
    # Rebuild the token file from existing items using real account details
    plaid item list --json 2>/dev/null | PLAID_CLIENT_ID="$PLAID_CLIENT_ID" PLAID_SECRET="$PLAID_SECRET" uv run --with httpx python3 -c "
import json, sys, os, httpx
items = json.load(sys.stdin)
cid, sec = os.environ.get('PLAID_CLIENT_ID',''), os.environ.get('PLAID_SECRET','')
with open('/tmp/plaid-tokens-all.jsonl', 'w') as f:
    for item in items:
        tok = item.get('access_token')
        if not tok:
            continue
        try:
            r = httpx.post('https://production.plaid.com/accounts/get',
                json={'client_id': cid, 'secret': sec, 'access_token': tok}, timeout=30)
            accts = r.json().get('accounts', [])
        except Exception:
            accts = []
        rows = [{'name': a.get('name','Bank'), 'mask': a.get('mask') or '',
                 'account_id': a.get('account_id',''),
                 'type': 'credit_card' if a.get('type')=='credit' else 'checking'} for a in accts]
        if rows:
            f.write(json.dumps({'access_token': tok, 'accounts': rows}) + '\n')
" 2>/dev/null && info "Loaded real account details for matching"
    echo ""
    read -p "  Add another bank? (y/n): " choice
    [ "$choice" != "y" ] && choice="n"
else
    echo -e "  Connect your bank accounts using Plaid Hosted Link."
    echo -e "  ${BOLD}Cmd+Click${NC} (or Ctrl+Click) the URL that appears."
    echo ""
    warn "Some banks (Chase, Schwab) need OAuth approval (~24hrs)."
    info "Check status: https://dashboard.plaid.com/activity/status/oauth-institutions"
    info "If you need to come back later, reopen this Codespace and run: ./setup.sh"
    echo ""
    read -p "  Press Enter to connect a bank, 'p' to paste a token, or 'n' to skip: " choice
fi
while [ "$choice" != "n" ]; do
    if [ "$choice" = "p" ]; then
        read -p "  Access token: " manual_token
        read -p "  Account name (e.g. Bluevine): " manual_name
        read -p "  Last 4 digits of account number: " manual_mask
        read -p "  Type — 1. checking  2. credit card: " manual_type_choice
        while [ "$manual_type_choice" != "1" ] && [ "$manual_type_choice" != "2" ]; do
            read -p "  Please enter 1 or 2: " manual_type_choice
        done
        if [ "$manual_type_choice" = "2" ]; then
            manual_type="credit_card"
        else
            manual_type="checking"
        fi
        echo "{\"access_token\":\"$manual_token\",\"accounts\":[{\"name\":\"$manual_name\",\"mask\":\"$manual_mask\",\"type\":\"$manual_type\"}]}" >> /tmp/plaid-tokens-all.jsonl
        success "Token saved for matching"
    else
        export PATH="$HOME/.local/bin:$PATH"
        # Ensure credentials are set
        if [ -z "$PLAID_CLIENT_ID" ] || [ -z "$PLAID_SECRET" ]; then
            echo -e "  Enter your Plaid credentials from: ${CYAN}https://dashboard.plaid.com/developers/keys${NC}"
            read -p "  Client ID: " PLAID_CLIENT_ID
            read -p "  Secret (Production): " PLAID_SECRET
            export PLAID_CLIENT_ID PLAID_SECRET
        fi
        uv run plaid_sync.py --add-bank
        ADD_BANK_EXIT=$?
        if [ "$ADD_BANK_EXIT" -ne 0 ]; then
            warn "Failed — likely a credentials mismatch (multiple Plaid teams?)."
            echo -e "  Paste correct keys from: ${CYAN}https://dashboard.plaid.com/developers/keys${NC}"
            echo ""
            read -p "  Client ID: " PLAID_CLIENT_ID
            read -p "  Secret (Production): " PLAID_SECRET
            export PLAID_CLIENT_ID PLAID_SECRET
            if [ -f ~/.config/plaid-cli/config.json ]; then
                uv run python3 -c "
import json
with open('$HOME/.config/plaid-cli/config.json') as f: d=json.load(f)
d.setdefault('environments',{}).setdefault('production',{})['secret']='$PLAID_SECRET'
with open('$HOME/.config/plaid-cli/config.json','w') as f: json.dump(d,f,indent=2)
" 2>/dev/null
            fi
            uv run plaid_sync.py --add-bank || warn "Still failing — check your credentials"
        fi

        # If bank was connected, save token for later matching (after Wave setup)
        if [ -f /tmp/plaid-new-token.txt ]; then
            cat /tmp/plaid-new-token.txt >> /tmp/plaid-tokens-all.jsonl
            rm -f /tmp/plaid-new-token.txt
            success "Bank token saved for matching"
        fi
    fi

    echo ""
    read -p "  Connect another bank? (y/n, or 'p' to paste token): " choice
done

echo ""
echo -e "  ${BOLD}Your linked accounts:${NC}"
plaid item list 2>/dev/null || true
echo ""

# ─── Step 4: Wave setup ───────────────────────────────────────────────────────

step "Step 4/6 · Wave setup"

# Persistent storage location for the Wave token (outside the repo)
WAVE_TOKEN_FILE="$HOME/.config/plaid-wave-sync/wave.token"

# Try to load from local cache (set on previous setup runs)
if [ -z "$WAVE_ACCESS_TOKEN" ] && [ -f "$WAVE_TOKEN_FILE" ]; then
    WAVE_ACCESS_TOKEN=$(cat "$WAVE_TOKEN_FILE" 2>/dev/null)
    [ -n "$WAVE_ACCESS_TOKEN" ] && success "Loaded saved Wave token from $WAVE_TOKEN_FILE"
fi

if [ -z "$WAVE_ACCESS_TOKEN" ]; then
    # Check if it's already saved as a GitHub secret (user re-running setup)
    if gh secret list 2>/dev/null | grep -q "WAVE_ACCESS_TOKEN"; then
        info "WAVE_ACCESS_TOKEN already saved in GitHub secrets, but we need a copy locally for matching."
        echo -e "  Get it from: ${CYAN}https://developer-apps.waveapps.com${NC} → your app → Full Access Token"
        read -p "  Paste your Wave token: " WAVE_ACCESS_TOKEN
    else
        echo -e "  Create a Wave app to get your API token:"
        echo -e "  ${CYAN}https://developer-apps.waveapps.com/apps/create/${NC}"
        echo ""
        echo -e "  Fill in:"
        echo -e "    Name:          ${BOLD}plaid-wave-sync${NC}"
        echo -e "    Description:   ${BOLD}Syncs bank transactions from Plaid${NC}"
        echo -e "    Redirect URI:  ${BOLD}http://localhost${NC}"
        echo ""
        echo -e "  After creating, copy the ${BOLD}Full Access Token${NC} from the app page."
        echo ""
        read -p "  Paste your Wave token: " WAVE_ACCESS_TOKEN
    fi
    export WAVE_ACCESS_TOKEN

    # Cache locally with restrictive permissions (outside the repo, gitignored regardless)
    if [ -n "$WAVE_ACCESS_TOKEN" ]; then
        mkdir -p "$(dirname "$WAVE_TOKEN_FILE")"
        umask 077
        printf '%s' "$WAVE_ACCESS_TOKEN" > "$WAVE_TOKEN_FILE"
        chmod 600 "$WAVE_TOKEN_FILE"
        info "Saved locally so you won't need to paste this again."
    fi
fi

echo ""
# Check for multiple businesses
BIZ_LIST=$(WAVE_ACCESS_TOKEN="$WAVE_ACCESS_TOKEN" uv run --with httpx python3 -c "
import os, httpx
r = httpx.post('https://gql.waveapps.com/graphql/public',
    headers={'Authorization': f'Bearer {os.environ[\"WAVE_ACCESS_TOKEN\"]}'},
    json={'query': '{ businesses(page:1, pageSize:10) { edges { node { id name isArchived } } } }'},
    timeout=30)
for e in r.json()['data']['businesses']['edges']:
    if not e['node']['isArchived']:
        print(f\"{e['node']['id']}|{e['node']['name']}\")
" 2>/dev/null)

BIZ_COUNT=$(echo "$BIZ_LIST" | grep -c '|' || echo "0")
if [ "$BIZ_COUNT" -gt "1" ]; then
    echo -e "  ${BOLD}Multiple Wave businesses found:${NC}"
    echo "$BIZ_LIST" | awk -F'|' '{printf "    %d. %s\n", NR, $2}'
    echo ""
    read -p "  Which one? (number): " biz_num
    export WAVE_BUSINESS_ID=$(echo "$BIZ_LIST" | sed -n "${biz_num}p" | cut -d'|' -f1)
    success "Selected: $(echo "$BIZ_LIST" | sed -n "${biz_num}p" | cut -d'|' -f2)"
else
    export WAVE_BUSINESS_ID=$(echo "$BIZ_LIST" | head -1 | cut -d'|' -f1)
fi

echo ""
uv run plaid_sync.py --dump-accounts 2>/dev/null | head -30
echo ""

# ─── Match Plaid accounts to Wave accounts ────────────────────────────────────

if [ -f /tmp/plaid-tokens-all.jsonl ]; then
    if [ -z "$WAVE_BUSINESS_ID" ]; then
        warn "Wave business ID not set — skipping auto-match. You'll set tokens manually in Step 6."
    else
        info "Matching your bank accounts to Wave..."
        export WAVE_ACCESS_TOKEN WAVE_BUSINESS_ID
        uv run scripts/match_accounts.py

        # Handle unmatched accounts interactively
        # Load auto-matched accounts, then resolve the remainder interactively
        PLAID_ACCESS_TOKENS=""
        [ -f /tmp/plaid-access-tokens.json ] && PLAID_ACCESS_TOKENS=$(cat /tmp/plaid-access-tokens.json)

        if [ -f /tmp/plaid-unmatched.jsonl ] && [ -s /tmp/plaid-unmatched.jsonl ]; then
            echo ""
            info "These accounts need a manual pick (only type-compatible Wave accounts are shown):"
            # Reading from a file (not a pipe) keeps PLAID_ACCESS_TOKENS in this shell
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                PARSED=$(printf '%s' "$line" | uv run python3 -c "
import json,sys
d=json.load(sys.stdin)
print('\t'.join([d.get('name','Bank'),d.get('token',''),d.get('type','checking'),d.get('account_id','')]))
" 2>/dev/null)
                ACCT_NAME=$(printf '%s' "$PARSED" | cut -f1)
                ACCT_TOKEN=$(printf '%s' "$PARSED" | cut -f2)
                ACCT_TYPE=$(printf '%s' "$PARSED" | cut -f3)
                ACCT_ID=$(printf '%s' "$PARSED" | cut -f4)
                [ "$ACCT_TYPE" = "credit_card" ] && CAT="liability" || CAT="asset"
                # List ALL accounts, compatible type first, each labeled — pick by number
                { grep "|${CAT}$" /tmp/wave-account-options.txt; grep -v "|${CAT}$" /tmp/wave-account-options.txt; } 2>/dev/null > /tmp/wave-opts-display.txt
                echo ""
                echo -e "  ${BOLD}Which Wave account is '$ACCT_NAME' ($ACCT_TYPE)?${NC}"
                if [ -s /tmp/wave-opts-display.txt ]; then
                    awk -F'|' '{printf "    %d. %s  [%s]\n", NR, $1, $2}' /tmp/wave-opts-display.txt
                    echo -e "    0. Skip this account"
                    read -p "  Enter a number (or type a name): " wave_input < /dev/tty
                else
                    read -p "  Wave account name (none auto-listed, Enter to skip): " wave_input < /dev/tty
                fi
                { [ "$wave_input" = "0" ] || [ -z "$wave_input" ]; } && continue
                if [ "$wave_input" -eq "$wave_input" ] 2>/dev/null; then
                    wave_name=$(sed -n "${wave_input}p" /tmp/wave-opts-display.txt 2>/dev/null | cut -d'|' -f1)
                else
                    wave_name="$wave_input"
                fi
                if [ -n "$wave_name" ]; then
                    success "Mapped $ACCT_NAME → $wave_name"
                    # Append to JSON array
                    NEW_ENTRY=$(uv run python3 -c "
import json,sys
entry = {'name': '$ACCT_NAME', 'token': '$ACCT_TOKEN', 'wave_account': '$wave_name', 'type': '$ACCT_TYPE', 'account_id': '$ACCT_ID'}
existing = json.loads(sys.stdin.read() or '[]')
existing.append(entry)
print(json.dumps(existing))
" <<< "$PLAID_ACCESS_TOKENS")
                    PLAID_ACCESS_TOKENS="$NEW_ENTRY"
                fi
            done < /tmp/plaid-unmatched.jsonl
        fi

        export PLAID_ACCESS_TOKENS
        rm -f /tmp/plaid-tokens-all.jsonl /tmp/plaid-access-tokens.json /tmp/plaid-unmatched.jsonl /tmp/wave-account-options.txt /tmp/wave-opts-display.txt
        if [ -n "$PLAID_ACCESS_TOKENS" ]; then
            success "PLAID_ACCESS_TOKENS ready"
        fi
    fi
fi

# ─── Step 5: Keywords ─────────────────────────────────────────────────────────

step "Step 5/6 · Build keyword mappings"

# Check if keywords.json has been customized (built from user's CSV)
# The shipped example has a "_comment" field; build_keywords.py output doesn't.
KEYWORDS_CUSTOMIZED="false"
if [ -f keywords.json ]; then
    if ! uv run python3 -c "import json,sys; d=json.load(open('keywords.json')); sys.exit(0 if '_comment' in d else 1)" 2>/dev/null; then
        KEYWORDS_CUSTOMIZED="true"
    fi
fi

if [ "$KEYWORDS_CUSTOMIZED" = "true" ]; then
    KW_COUNT=$(uv run python3 -c "import json; print(len(json.load(open('keywords.json'))['keywords']))" 2>/dev/null)
    success "keywords.json already built from your CSV ($KW_COUNT keywords)"
    read -p "  Rebuild from a new CSV? (y/n): " rebuild
    if [ "$rebuild" != "y" ]; then
        csv_path=""
    fi
fi

if [ -z "${rebuild:-}" ] || [ "$rebuild" = "y" ]; then
    echo -e "  Export your transaction history from Wave:"
echo -e "  ${CYAN}Wave → Reports → Account Transactions (General Ledger) → Export CSV${NC}"
echo -e "  (Set date range to last 12 months)"
echo ""
echo -e "  Then drag the CSV into the ${BOLD}imports/${NC} folder:"
echo -e "  Open the Explorer panel (${BOLD}Cmd+Shift+E${NC} on Mac, ${BOLD}Ctrl+Shift+E${NC} on Windows)"
echo -e "  and drop your file into the ${BOLD}imports${NC} folder."
echo ""
read -p "  Path to CSV (drag file into terminal, or Enter to auto-find): " csv_path
csv_path=$(echo "$csv_path" | tr -d "'" | tr -d '"')

# Auto-find CSV if not specified
if [ -z "$csv_path" ]; then
    csv_path=$(find . imports/ -maxdepth 1 -name "*.csv" 2>/dev/null | head -1)
    [ -n "$csv_path" ] && info "Found: $csv_path"
fi

if [ -n "$csv_path" ] && [ -f "$csv_path" ]; then
    export PATH="$HOME/.local/bin:$PATH"
    
    # Build keywords.json directly from the CSV's existing categorization
    info "Building keywords.json from your existing categorization..."
    uv run scripts/build_keywords.py "$csv_path"

    success "keywords.json generated from your existing categorization"
    info "Review it and tweak if needed. Run 'uv run plaid_sync.py --dump-accounts' to validate."
else
    warn "No CSV found. Export from Wave → Reports → Account Transactions, drop in workspace, re-run."
fi
fi

# ─── Step 6: Save secrets ─────────────────────────────────────────────────────

step "Step 6/6 · Save secrets to GitHub"

info "These are saved as ${BOLD}repository${NC} secrets (Settings → Secrets and variables → Actions)."
info "Do not use Environment secrets — the sync workflow reads repo-level secrets only."

# PLAID_SECRET is required at runtime; never save it empty
if [ -z "$PLAID_SECRET" ]; then
    warn "PLAID_SECRET is empty — Plaid auth will fail at runtime."
    echo -e "  Get your Production secret: ${CYAN}https://dashboard.plaid.com/developers/keys${NC}"
    read -p "  Enter Plaid Secret (Production): " PLAID_SECRET
    export PLAID_SECRET
fi

TARGET_REPO=$(git config --get remote.origin.url | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
if [ "$TARGET_REPO" = "jeffreylsoffer/plaid-wave-sync" ]; then
    warn "Your origin remote points to the upstream repo, not your fork."
    warn "Fork the repo on GitHub first, then update your remote:"
    echo -e "  ${CYAN}git remote set-url origin https://github.com/YOUR_USERNAME/plaid-wave-sync.git${NC}"
    echo ""
    read -p "  Enter your fork (owner/repo), or press Enter to skip saving secrets: " TARGET_REPO
    if [ -z "$TARGET_REPO" ]; then
        warn "Skipping secret save. Set them manually in your fork's Settings → Secrets → Actions."
        save_secrets="n"
    fi
fi

_set_secret() {  # name value
    if [ -z "$2" ]; then warn "$1 is empty — set it manually"; return; fi
    if gh secret set "$1" --body "$2" --repo "$TARGET_REPO"; then success "Saved $1"; else warn "Failed to save $1"; fi
}

read -p "  Auto-save secrets to this repo? (y/n): " save_secrets
if [ "$save_secrets" = "y" ]; then
    # gh prefers an ambient token; in Codespaces that token is read-only for
    # secrets, so drop both and let `gh auth login` grant the repo scope.
    if ! gh secret set PLAID_CLIENT_ID --body "$PLAID_CLIENT_ID" --repo "$TARGET_REPO" 2>/dev/null; then
        info "Need GitHub auth to save secrets (one-time)."
        unset GITHUB_TOKEN GH_TOKEN
        gh auth login -w -p https --git-protocol https -s repo
    fi

    # Make repo private to protect financial data in Action logs
    gh repo edit "$TARGET_REPO" --visibility private 2>/dev/null && success "Repo set to private" || true

    _set_secret PLAID_CLIENT_ID "$PLAID_CLIENT_ID"
    _set_secret PLAID_SECRET "$PLAID_SECRET"
    _set_secret WAVE_ACCESS_TOKEN "$WAVE_ACCESS_TOKEN"
    _set_secret WAVE_BUSINESS_ID "$WAVE_BUSINESS_ID"

    echo ""
    if [ -z "$PLAID_ACCESS_TOKENS" ]; then
        warn "PLAID_ACCESS_TOKENS wasn't assembled — paste it manually."
        info 'Format (JSON): [{"name":"MyBank","token":"access-xxx","wave_account":"Checking (001)","type":"checking"}]'
        info "List connected items with: plaid item list --json"
        read -p "  Paste PLAID_ACCESS_TOKENS (or Enter to skip): " tokens
        [ -n "$tokens" ] && PLAID_ACCESS_TOKENS="$tokens" && export PLAID_ACCESS_TOKENS
    fi
    if [ -n "$PLAID_ACCESS_TOKENS" ]; then
        _set_secret PLAID_ACCESS_TOKENS "$PLAID_ACCESS_TOKENS"
    else
        warn "PLAID_ACCESS_TOKENS not set. The Action will fail until this is configured."
        info "Re-run ./setup.sh or set it manually in Settings → Secrets → Actions"
    fi
else
    warn "Add secrets manually: Settings → Secrets and variables → Actions (Repository secrets)."
fi

# ─── Done ─────────────────────────────────────────────────────────────────────

# Enable the Actions workflow (only if secrets are configured)
if [ -z "$PLAID_CLIENT_ID" ] || [ -z "$PLAID_ACCESS_TOKENS" ]; then
    warn "Skipping workflow enable — secrets incomplete. Re-run ./setup.sh when ready."
else
    if ! gh workflow enable sync.yml --repo "$TARGET_REPO" 2>/dev/null; then
        REPO_URL="https://github.com/$TARGET_REPO"
        echo ""
        warn "GitHub requires you to manually enable Actions on a new fork."
        echo -e "  1. Open: ${CYAN}${REPO_URL}/actions${NC}"
        echo -e "  2. Click: ${BOLD}I understand my workflows, go ahead and enable them${NC}"
        echo ""
        read -p "  Press Enter once you've clicked the button..."
        gh workflow enable sync.yml --repo "$TARGET_REPO" &>/dev/null
    fi
    success "GitHub Actions workflow enabled"

    # Trigger a test run
    if gh workflow run sync.yml -f days=3 -f dry_run=true --repo "$TARGET_REPO" 2>/dev/null; then
        success "Test run triggered (dry-run)"

        info "Waiting for test run to complete..."
        sleep 10
        RUN_ID=$(gh run list --workflow=sync.yml -L 1 --json databaseId -q '.[0].databaseId' --repo "$TARGET_REPO" 2>/dev/null)
        if [ -n "$RUN_ID" ]; then
            gh run watch "$RUN_ID" --exit-status 2>/dev/null && success "Test run passed! ✓" || warn "Test run failed — check Actions tab for details"
            REPO_URL="https://github.com/$TARGET_REPO"
            echo -e "  ${CYAN}${REPO_URL}/actions/runs/${RUN_ID}${NC}"
        fi
    else
        warn "Could not trigger test run. Trigger manually from the Actions tab."
    fi
fi

echo ""
echo -e "  ${BOLD}  ╔══════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}  ║  ${GREEN}✓ Setup complete!${NC}${BOLD}                      ║${NC}"
echo -e "  ${BOLD}  ╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Your sync runs daily at 9am ET automatically."
echo -e "  Trigger manually: ${CYAN}Actions tab → Run workflow${NC}"
echo ""
echo -e "  ${DIM}You can close this Codespace now.${NC}"
echo ""
