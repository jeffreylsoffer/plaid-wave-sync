#!/usr/bin/env bash
# Update this fork to the latest code, then re-run setup.
# Usage: ./update.sh
UPSTREAM="jeffreylsoffer/plaid-wave-sync"

# 1) Sync the fork on GitHub from upstream (server-side — this is what the Action runs)
FORK=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
if [ -n "$FORK" ] && gh repo sync "$FORK" --source "$UPSTREAM" --force 2>/dev/null; then
    echo "✓ Fork updated from $UPSTREAM"
else
    echo "⚠ Couldn't sync automatically. In GitHub, click your repo → 'Sync fork' → Update branch, then re-run."
fi

# 2) Hard-reset the local Codespace to the synced code (discards local edits to tracked files)
git fetch origin && git reset --hard origin/main

# 3) Re-run setup (reuses Plaid/Wave creds cached in ~/.config when present)
exec ./setup.sh
