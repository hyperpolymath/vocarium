#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Static contract for the required secret-scanning context and its triggers.
set -euo pipefail

workflow=${1:-.github/workflows/secret-scanner.yml}
fail() { echo "FAIL: $*" >&2; exit 1; }

for trigger in pull_request push merge_group; do
  grep -Fxq "  $trigger:" "$workflow" || fail "missing $trigger trigger"
done
grep -Fxq '    branches: [main]' "$workflow" || fail 'main push trigger missing'
grep -Fxq '    types: [checks_requested]' "$workflow" || fail 'merge-group checks_requested missing'
grep -Fxq '  group: ${{ github.workflow }}-${{ github.ref }}' "$workflow" || fail 'concurrency is not scoped by ref'
grep -Fxq 'permissions: {}' "$workflow" || fail 'workflow-wide permissions are not disabled'

# The job ID and reusable subjob name together produce `scan / gitleaks`, the
# app-bound required status context. The pinned reusable was inspected at this
# exact SHA; it runs a real scan of actions/checkout's default event tree.
awk '
  /^  scan:$/ { in_scan=1; next }
  in_scan && /^  [a-zA-Z0-9_-]+:$/ { exit }
  in_scan && $0 == "      contents: read" { read_contents=1 }
  in_scan && $0 == "    uses: metadatastician/standards/.github/workflows/secret-scanner-reusable.yml@8d1a2aab4211493cf42f147f2080f024605797dc" { pinned=1 }
  END { if (!in_scan || !read_contents || !pinned) exit 1 }
' "$workflow" || fail 'required scan job, minimal permissions, or pinned canonical reusable changed'

if grep -Eq '^[[:space:]]*(secrets|continue-on-error|pull_request_target):|\$\{\{[[:space:]]*secrets\.' "$workflow"; then
  fail 'inherited secrets, bypass, or privileged PR trigger present'
fi
if grep -Eq '^[[:space:]]*(actions|pull-requests):[[:space:]]*(read|write)' "$workflow"; then
  fail 'unneeded Actions or PR permissions present'
fi

echo 'Secret scanner contract passed: PR, main push and merge-group wiring; required job; pinned reusable; no inherited secrets.'
echo 'A real merge-group event and scan still require a hosted canary.'

# Exercise the checker itself against unsafe mutations. Passing a workflow
# path is the recursive fixture mode, which does not make further fixtures.
if [[ $# -eq 0 ]]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  expect_reject() {
    local label=$1 candidate=$2
    if bash "$0" "$candidate" > "$tmp/fixture.log" 2>&1; then
      fail "$label mutation unexpectedly passed"
    fi
    echo "ok: $label mutation rejected"
  }
  cp "$workflow" "$tmp/inherit.yml"
  sed -i '/^  scanner-contract:/i\    secrets: inherit' "$tmp/inherit.yml"
  expect_reject 'inherited secrets' "$tmp/inherit.yml"
  cp "$workflow" "$tmp/privileged-pr.yml"
  sed -i '/^  pull_request:$/a\  pull_request_target:' "$tmp/privileged-pr.yml"
  expect_reject 'privileged PR trigger' "$tmp/privileged-pr.yml"
  cp "$workflow" "$tmp/bypass.yml"
  sed -i '/^  scanner-contract:/i\    continue-on-error: true' "$tmp/bypass.yml"
  expect_reject 'failure bypass' "$tmp/bypass.yml"
  cp "$workflow" "$tmp/redirect.yml"
  sed -i 's/uses: metadatastician\/standards/uses: hyperpolymath\/standards/' "$tmp/redirect.yml"
  expect_reject 'redirecting reusable owner' "$tmp/redirect.yml"
  cp "$workflow" "$tmp/old-pin.yml"
  sed -i 's/8d1a2aab4211493cf42f147f2080f024605797dc/84355587cb2a1f86e6882de83514a32db2646e7a/' "$tmp/old-pin.yml"
  expect_reject 'upstream commit with invalid checkout lock' "$tmp/old-pin.yml"
  cp "$workflow" "$tmp/permission.yml"
  sed -i '/^      contents: read$/a\      pull-requests: write' "$tmp/permission.yml"
  expect_reject 'excess PR permissions' "$tmp/permission.yml"
  cp "$workflow" "$tmp/context.yml"
  sed -i 's/^  scan:$/  renamed:/' "$tmp/context.yml"
  expect_reject 'renamed required job' "$tmp/context.yml"
  cp "$workflow" "$tmp/group.yml"
  sed -i '/^  merge_group:/d' "$tmp/group.yml"
  expect_reject 'missing merge-group trigger' "$tmp/group.yml"
fi
