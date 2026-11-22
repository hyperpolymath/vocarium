#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Validate with the canonical standards checkout, without a legacy allowlist.
set -euo pipefail
root="${INPUT_PATH:-.}"
root="$(cd "$root" && pwd)"
standards="${STANDARDS_DIR:-$root/../standards}"
linter="$standards/1-formats/deed/tools/deed_lint.js"
command -v node >/dev/null || { echo 'node is required for deed validation' >&2; exit 2; }
[ -f "$linter" ] || { echo "missing canonical deed linter: $linter (set STANDARDS_DIR)" >&2; exit 2; }
cd "$root"
shopt -s nullglob
roots=(*_chora.deed)
if [[ ${#roots[@]} -ne 1 || ${roots[0]} != vocarium_chora.deed ]]; then
  echo 'expected exactly one root deed: vocarium_chora.deed' >&2
  exit 1
fi
mapfile -d '' old < <(find . -path './.git' -prune -o -type f -name '*.a2ml' -print0)
if [ "${#old[@]}" -gt 0 ]; then printf 'retired A2ML file: %s\n' "${old[@]}" >&2; exit 1; fi
mapfile -d '' deeds < <(find . -path './.git' -prune -o -type f -name '*.deed' -print0 | sort -z)
[ "${#deeds[@]}" -gt 0 ] || exit 1
for deed in "${deeds[@]}"; do node "$linter" --strict "$deed"; done
node "$linter" --rsr-profile vocarium_chora.deed
for profile in state meta agentic neurosym; do
  node "$linter" "--$profile" --root "$root" ".machine_readable/descriptiles/${profile^^}.deed"
done
