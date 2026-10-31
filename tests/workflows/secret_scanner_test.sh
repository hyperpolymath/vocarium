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
  in_scan && $0 == "    uses: metadatastician/standards/.github/workflows/secret-scanner-reusable.yml@84355587cb2a1f86e6882de83514a32db2646e7a" { pinned=1 }
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
