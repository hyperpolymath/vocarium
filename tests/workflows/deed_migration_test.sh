#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Isolated regression tests; set STANDARDS_DIR to the canonical checkout.
set -euo pipefail
repo="$(git rev-parse --show-toplevel)"
: "${STANDARDS_DIR:?set STANDARDS_DIR to a standards checkout}"
export STANDARDS_DIR
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/.github/hooks" "$work/.machine_readable" "$work/scripts"
cp "$repo/.github/hooks/validate-deed.sh" "$work/.github/hooks/"
cp -r "$repo/.machine_readable/descriptiles" "$repo/.machine_readable/arrival-pack" "$work/.machine_readable/"
cp "$repo/scripts/deed-field.sh" "$work/scripts/"
cp "$repo/vocarium_chora.deed" "$repo/0-AI-MANIFEST.deed" "$repo/CLAUDE.md" "$work/"
git -C "$work" init -q
cd "$work"
expect_failure() { if "$@" >/dev/null 2>&1; then echo "unexpected success: $*" >&2; exit 1; fi; }
bash .github/hooks/validate-deed.sh >/dev/null
bash .machine_readable/arrival-pack/verify.sh >/dev/null
cp vocarium_chora.deed extra_chora.deed
expect_failure bash .github/hooks/validate-deed.sh
rm extra_chora.deed
printf 'legacy\n' > stale.a2ml
expect_failure bash .github/hooks/validate-deed.sh
rm stale.a2ml
printf '(broken\n' > bad.deed
expect_failure bash .github/hooks/validate-deed.sh
rm bad.deed
expect_failure env STANDARDS_DIR="$work/nonexistent" bash .github/hooks/validate-deed.sh
sed -i 's/:phase active/:phase invalid/' .machine_readable/descriptiles/STATE.deed
expect_failure bash .github/hooks/validate-deed.sh
expect_failure bash .machine_readable/arrival-pack/verify.sh
sed -i 's/:phase invalid/:phase active/' .machine_readable/descriptiles/STATE.deed
printf '\nmanual note outside region\n' >> CLAUDE.md
bash .machine_readable/arrival-pack/generate.sh >/dev/null
grep -q '^manual note outside region$' CLAUDE.md
bash .machine_readable/arrival-pack/verify.sh >/dev/null
printf '\n<!-- ARRIVAL-PACK:BEGIN -->\n' >> CLAUDE.md
expect_failure bash .machine_readable/arrival-pack/verify.sh
expect_failure bash .machine_readable/arrival-pack/generate.sh
echo 'deed migration regression tests passed'
