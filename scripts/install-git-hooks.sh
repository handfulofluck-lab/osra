#!/bin/sh
# Install the repo's git hooks into this clone (AGENTS.md §6 — main is PR-only).
#
#   scripts/install-git-hooks.sh
#
# Why a script: two "obvious" installations silently do nothing.
#   1. `git config core.hooksPath .githooks` — a RELATIVE path resolves to nothing on
#      Git for Windows, so git finds no hooks and pushes straight through. Use an absolute
#      path if you prefer core.hooksPath, or use this script.
#   2. Relying on .githooks/ existing in the checked-out ref — it is absent on `main` until
#      this guard is merged, and switching branches removes it from the working tree.
# Copying into .git/hooks/ is independent of which branch is checked out.
set -eu

repo_root=$(git rev-parse --show-toplevel)
src="$repo_root/.githooks"
dst="$repo_root/.git/hooks"

[ -d "$src" ] || { echo "no .githooks directory at $src" >&2; exit 1; }

installed=0
for hook in "$src"/*; do
  [ -f "$hook" ] || continue
  name=$(basename "$hook")
  cp "$hook" "$dst/$name"
  chmod +x "$dst/$name"
  echo "installed: .git/hooks/$name"
  installed=$((installed + 1))
done

[ "$installed" -gt 0 ] || { echo "no hooks found in $src" >&2; exit 1; }
echo "done — pushes to refs/heads/main are now blocked in this clone."
echo "maintainer override: OSRA_ALLOW_MAIN_PUSH=1 git push <remote> main"
