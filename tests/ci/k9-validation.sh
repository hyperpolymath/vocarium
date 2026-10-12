#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Exercise format dispatch and rejection paths, without running any K9 payload.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

check() {
    local expected="$1" actual=0
    INPUT_PATH="$fixture_dir" INPUT_PATHS_IGNORE='' INPUT_STRICT=false GITHUB_OUTPUT=/dev/null \
        bash "$repo_root/.githooks/validate-k9.sh" > "$fixture_dir/result.log" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        cat "$fixture_dir/result.log" >&2
        echo "Expected exit $expected, got $actual" >&2
        exit 1
    fi
}

# Both native Nickel comments and legacy envelope markers retain validation.
cat > "$fixture_dir/contract.k9.ncl" <<'K9'
# K9!
# SPDX-License-Identifier: MPL-2.0
{
  pedigree = {
    name = "fixture",
    version = "1.0.0",
    security = {
      leash = 'Hunt,
      signature_required = true,
    },
  },
}
K9
check 0
sed -i '1s/# //' "$fixture_dir/contract.k9.ncl"
check 0
sed -i '/signature_required/d' "$fixture_dir/contract.k9.ncl"
check 1
grep -q 'Hunt-level K9 file must include' "$fixture_dir/result.log"
sed -i "s/'Hunt/'Yard/" "$fixture_dir/contract.k9.ncl"
check 0
sed -i '1d' "$fixture_dir/contract.k9.ncl"
check 1
grep -q 'Missing K9! marker' "$fixture_dir/result.log"
rm "$fixture_dir/contract.k9.ncl"

# Deployment records can bind their pedigree before exporting it.
cat > "$fixture_dir/deploy.k9.ncl" <<'K9'
# K9!
# SPDX-License-Identifier: MPL-2.0
let component_pedigree = {
  name = "deployment",
  version = "1.0.0",
  security = {
    leash = 'Hunt,
    signature_required = true,
  },
} in
{ pedigree = component_pedigree }
K9
check 0
sed -i '/signature_required/d' "$fixture_dir/deploy.k9.ncl"
check 1
rm "$fixture_dir/deploy.k9.ncl"

# YAML session bindings remain data and must carry their own pedigree.
cat > "$fixture_dir/bindings.k9" <<'K9'
# K9!
# SPDX-License-Identifier: MPL-2.0
pedigree:
  name: "session-bindings"
  version: "1.0.0"
  security_level: "kennel"
checks:
  - id: "example"
K9
check 0
sed -i 's/"kennel"/"unknown"/' "$fixture_dir/bindings.k9"
check 1
grep -q 'Invalid security level' "$fixture_dir/result.log"
sed -i 's/"unknown"/"hunt"/' "$fixture_dir/bindings.k9"
check 1
grep -q 'Hunt-level K9 file must include' "$fixture_dir/result.log"
sed -i '/security_level:/a\  signature_required: true' "$fixture_dir/bindings.k9"
check 0
sed -i '/  name:/d' "$fixture_dir/bindings.k9"
check 1
grep -q "Pedigree block missing 'name'" "$fixture_dir/result.log"
sed -i '/^pedigree:/d' "$fixture_dir/bindings.k9"
check 1
grep -q 'Missing pedigree block' "$fixture_dir/result.log"
echo 'K9 format and rejection checks passed.'
