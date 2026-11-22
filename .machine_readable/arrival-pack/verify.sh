#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
target="$root/CLAUDE.md"
if [[ ! -f $target ]] || [[ $(grep -c '<!-- ARRIVAL-PACK:BEGIN' "$target") -ne 1 || $(grep -c '<!-- ARRIVAL-PACK:END' "$target") -ne 1 ]]; then
  echo 'missing or duplicate arrival markers' >&2
  exit 1
fi
diff -u <(awk '/<!-- ARRIVAL-PACK:BEGIN/{p=1} p{print} /<!-- ARRIVAL-PACK:END/{p=0}' "$target") <(bash "$root/.machine_readable/arrival-pack/extract.sh" "$root") || { echo 'Arrival pack drift: run just claude-md' >&2; exit 1; }
echo 'Arrival pack matches deed and STATE.'
