#!/usr/bin/env bash
# Update to the latest code, then re-run setup.  Usage: ./update.sh
UPSTREAM="jeffreylsoffer/plaid-wave-sync"

# 1) Refresh local code from upstream (discards local edits to tracked files)
git fetch "https://github.com/$UPSTREAM.git" main && git reset --hard FETCH_HEAD

# 2) Sync the fork on GitHub too, so the daily Action runs the new code
FORK=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
if [ -n "$FORK" ] && gh repo sync "$FORK" --source "$UPSTREAM" --force 2>/dev/null; then
    echo "✓ Fork updated — the daily sync will use the new code"
else
    echo "⚠ Also update your fork: GitHub → your repo → 'Sync fork' → Update branch"
fi

# 3) Re-run setup (reuses Plaid/Wave creds cached in ~/.config when present)
exec ./setup.sh
