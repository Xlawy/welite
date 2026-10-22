#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

if ! command -v rg >/dev/null 2>&1; then
    echo "error: ripgrep (rg) is required for the Lua namespace check" >&2
    exit 1
fi

failed=0

for legacy_dir in lib ui weread integrations; do
    if [[ -d "$legacy_dir" ]]; then
        echo "error: project modules must not be added to root-level $legacy_dir/" >&2
        failed=1
    fi
done

legacy_pattern='require[[:space:]]*\([[:space:]]*["'\''](lib|ui|weread|integrations)\.|package\.(loaded|preload)[[:space:]]*\[[[:space:]]*["'\''](lib|ui|weread|integrations)\.'
if rg -n --pcre2 "$legacy_pattern" --glob '*.lua' main.lua _meta.lua welite; then
    echo "error: use welite.lib.* or welite.ui.* for project-owned Lua modules" >&2
    failed=1
fi

if rg -n 'require[[:space:]]*\([[:space:]]*["'\'']logger["'\'']' \
    --glob '*.lua' \
    --glob '!welite/lib/logger.lua' \
    main.lua _meta.lua welite; then
    echo "error: use welite.lib.logger so project log messages receive a consistent prefix" >&2
    failed=1
fi

unexpected_modules="$(
    find welite -type f -name '*.lua' \
        ! -path 'welite/lib/*' \
        ! -path 'welite/ui/*' \
        ! -path 'welite/integrations/*' \
        ! -path 'welite/identity.lua' \
        -print
)"
if [[ -n "$unexpected_modules" ]]; then
    echo "error: Lua modules below welite/ must have a defined namespace:" >&2
    echo "$unexpected_modules" >&2
    failed=1
fi

exit "$failed"
