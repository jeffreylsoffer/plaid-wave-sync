#!/usr/bin/env bash
# Update to the latest code, then re-run setup.  Usage: ./update.sh
#
# This discards local edits to tracked files and force-updates YOUR repo to
# match upstream. Don't run it if you've intentionally customized your copy.
UPSTREAM="jeffreylsoffer/plaid-wave-sync"

# Your own repo, read from the ORIGIN remote. We avoid `gh repo view` because in
# a fork (or a Codespace on a fork) gh's base-repo resolution prefers the
# `upstream` parent — which would point at the source repo, not your copy.
ORIGIN_REPO=$(git config --get remote.origin.url 2>/dev/null \
    | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')

# 1) Refresh local code from upstream (discards local edits to tracked files)
git fetch "https://github.com/$UPSTREAM.git" main && git reset --hard FETCH_HEAD

# 2) Push it to YOUR repo so the daily Action runs the new code.
#    A force push to origin works for both forks and template copies — unlike
#    `gh repo sync`, which only works when your repo is a fork of upstream.
if [ -z "$ORIGIN_REPO" ] || [ "$ORIGIN_REPO" = "$UPSTREAM" ]; then
    echo "⚠ origin isn't your own copy — skipping push."
    echo "  Run this from your template copy or fork, not the upstream repo."
elif git push --force origin HEAD:main 2>/dev/null; then
    echo "✓ $ORIGIN_REPO updated — the daily Action will use the new code"
else
    echo "⚠ Couldn't push to $ORIGIN_REPO. Update it manually:"
    echo "    git push --force origin HEAD:main"
fi

# 3) Re-run setup (reuses Plaid/Wave creds cached in ~/.config when present)
exec ./setup.sh
