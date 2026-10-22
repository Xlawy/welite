#!/usr/bin/env bash
set -euo pipefail

readonly KOREADER_TESTED_COMMIT="1e2fa5f1239028ab4b37acae833cdc86a71e5258"
plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
koreader_dir="${KOREADER_DIR:-}"

if (( BASH_VERSINFO[0] < 4 )); then
    echo "error: KOReader integration tests require Bash >= 4 (got $BASH_VERSION)" >&2
    echo "On macOS, install Homebrew bash and run this script with that executable." >&2
    exit 1
fi

if [[ -z "$koreader_dir" ]]; then
    echo "error: set KOREADER_DIR to a KOReader checkout" >&2
    exit 1
fi
koreader_dir="$(cd "$koreader_dir" && pwd)"

if [[ ! -f "$koreader_dir/Makefile" || ! -d "$koreader_dir/plugins" ]]; then
    echo "error: KOREADER_DIR is not a KOReader source checkout" >&2
    exit 1
fi

actual_commit="$(git -C "$koreader_dir" rev-parse HEAD)"
if [[ "$actual_commit" != "$KOREADER_TESTED_COMMIT" ]]; then
    echo "error: expected KOReader $KOREADER_TESTED_COMMIT, got $actual_commit" >&2
    echo "Set KOREADER_DIR to the pinned checkout used by CI." >&2
    exit 1
fi

plugin_target="$koreader_dir/plugins/welite.koplugin"
if [[ -e "$plugin_target" || -L "$plugin_target" ]]; then
    echo "error: integration target already exists: $plugin_target" >&2
    exit 1
fi

fixture_dir="$(mktemp -d)"
spec_targets=()
spec_args=()
cleanup() {
    for target in "${spec_targets[@]}"; do rm -f "$target"; done
    rm -f "$plugin_target"
    rm -rf "$fixture_dir"
}
trap cleanup EXIT

# The real released plugin is an immutable ancestor, not a test double.
PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" "$fixture_dir/weread.koplugin" <<'PYTHON'
from pathlib import Path
import sys
from test_welite import upstream_fixture
upstream_fixture(Path(sys.argv[1]), Path(sys.argv[2]))
PYTHON
export WELITE_UPSTREAM_FIXTURE="$fixture_dir/weread.koplugin"
export XDG_DATA_HOME="$fixture_dir/profile"
export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy

ln -s "$plugin_dir" "$plugin_target"
for source in "$plugin_dir"/spec/koreader/welite*_spec.lua \
    "$plugin_dir/spec/koreader/weread_plugin_spec.lua" \
    "$plugin_dir/spec/koreader/welite_native_helper.lua"; do
    name="community_$(basename "$source")"
    target="$koreader_dir/spec/unit/$name"
    if [[ -e "$target" ]]; then
        echo "error: integration spec target already exists: $target" >&2
        exit 1
    fi
    cp "$source" "$target"
    spec_targets+=("$target")
    if [[ "$name" != community_welite_native_helper.lua ]]; then
        spec_args+=("spec/front/unit/$name")
    fi
done

if [[ "${KOREADER_SKIP_FETCH:-0}" != "1" ]]; then
    make -C "$koreader_dir" fetchthirdparty
fi

cd "$koreader_dir"
make base
./base/utils/fake_tty.py make --assume-old=base testfront \
    T="--busted=--helper=spec/front/unit/community_welite_native_helper.lua -- ${spec_args[*]}"
