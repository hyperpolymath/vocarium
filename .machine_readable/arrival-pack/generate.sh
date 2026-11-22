#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
tmp="$(mktemp)"; out="$(mktemp)"
trap 'rm -f "$tmp" "$out"' EXIT
bash "$root/.machine_readable/arrival-pack/extract.sh" "$root" > "$tmp"
target="$root/CLAUDE.md"
if [ -f "$target" ] && grep -q 'ARRIVAL-PACK:BEGIN' "$target"; then
  [ "$(grep -c 'ARRIVAL-PACK:BEGIN' "$target")" -eq 1 ] && [ "$(grep -c 'ARRIVAL-PACK:END' "$target")" -eq 1 ] || { echo 'invalid arrival markers' >&2; exit 1; }
  awk 'FNR==NR {r=r $0 ORS; next} /<!-- ARRIVAL-PACK:BEGIN/ {printf "%s",r; skip=1; next} /<!-- ARRIVAL-PACK:END/ {skip=0; next} !skip {print}' "$tmp" "$target" > "$out"
else
  printf '<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->\n\n' > "$out"
  cat "$tmp" >> "$out"
fi
cat "$out" > "$target"
echo "claude-md: wrote $target"
