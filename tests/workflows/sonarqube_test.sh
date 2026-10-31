#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Exercise the actual inline workflow scripts, not a copy of their logic.
set -euo pipefail

workflow=${1:-.github/workflows/sonarqube.yml}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

extract_run() {
  local step=$1 dest=$2
  awk -v target="      - name: $step" '
    $0 == target { found = 1; next }
    found && /^        run: \|$/ { in_run = 1; next }
    in_run && /^          / { sub(/^          /, ""); print; next }
    in_run && /^$/ { print; next }
    in_run { exit }
    END { if (!in_run) exit 1 }
  ' "$workflow" > "$dest"
}
extract_run 'Select analysis route' "$tmp/route.sh"
extract_run 'Verify project and analysis context' "$tmp/context.sh"
bash -n "$tmp/route.sh"
bash -n "$tmp/context.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
route_case() {
  local label=$1 event=$2 ref=$3 base=$4 repo=$5 expected=$6 rc=0
  : > "$tmp/output"
  GITHUB_OUTPUT="$tmp/output" GITHUB_REPOSITORY="$repo" \
    EVENT_NAME="$event" EVENT_REF="$ref" BASE_REF="$base" \
    bash "$tmp/route.sh" > "$tmp/log" 2>&1 || rc=$?
  if [[ $expected == failure ]]; then
    [[ $rc -ne 0 && ! -s "$tmp/output" ]] || fail "$label unexpectedly passed"
  else
    [[ $rc == 0 ]] || { cat "$tmp/log"; fail "$label exited $rc"; }
    grep -qx "route=$expected" "$tmp/output" || fail "$label chose the wrong route"
  fi
  echo "ok: $label"
}
repo=hyperpolymath/vocarium
route_case 'same-repo PR to main' pull_request refs/pull/47/merge main "$repo" official
route_case 'fork PR to main follows the same secret-free route' pull_request refs/pull/48/merge main "$repo" official
route_case 'main push' push refs/heads/main '' "$repo" official
route_case 'master push is not an analysis route' push refs/heads/master '' "$repo" failure
route_case 'master PR is not an analysis route' pull_request refs/pull/49/merge master "$repo" failure
route_case 'manual main dispatch is not an analysis route' workflow_dispatch refs/heads/main '' "$repo" failure
route_case 'manual PR ref is not an analysis route' workflow_dispatch refs/pull/47/merge '' "$repo" failure
route_case 'manual feature branch is not an analysis route' workflow_dispatch refs/heads/feature '' "$repo" failure
route_case 'merge-group SHA is not treated as a PR head' merge_group refs/heads/gh-readonly-queue/main/pr-1 main "$repo" failure
route_case 'unknown branch is not silently accepted' push refs/heads/other '' "$repo" failure
route_case 'different repository is not this project' push refs/heads/main '' other/vocarium failure

# Check the wiring around the scripts as well as their runtime behaviour.
grep -Fq 'uses: hyperpolymath/cicd-suite/actions/sonarcloud-result-check@4404c3c0474e17753fe7689f3485c02890aac113' "$workflow" || fail 'verifier is not pinned'
grep -Fq 'sha: ${{ github.event.pull_request.head.sha || github.sha }}' "$workflow" || fail 'subject is not the PR head / push SHA'
grep -Fxq 'permissions: {}' "$workflow" || fail 'workflow-wide token permissions are not disabled'
grep -Fxq '      checks: read' "$workflow" || fail 'job-scoped checks: read is missing'
if grep -Eq '^[[:space:]]*(continue-on-error|pull_request_target|workflow_dispatch):|SONAR_TOKEN|sonarqube-scan-action' "$workflow"; then
  fail 'unexpected bypass, privileged/manual trigger, scanner, or scanner secret present'
fi
[[ $(grep -Fxc '    branches: [main]' "$workflow") -eq 2 ]] || fail 'Sonar triggers are not limited to main'
echo 'ok: verifier pin, main-only triggers, permissions and secret-free quality-gate wiring'

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'MOCK'
#!/usr/bin/env bash
[[ ${MOCK_ERROR:-0} == 0 ]] || exit 1
cat "$MOCK_RESPONSE"
MOCK
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" MOCK_RESPONSE="$tmp/response.json"
sha=0123456789abcdef0123456789abcdef01234567
jq -n --arg sha "$sha" '{id:10,head_sha:$sha,name:"SonarCloud Code Analysis",app:{id:12526,slug:"sonarqubecloud"},status:"completed",conclusion:"success",started_at:"2026-10-30T20:16:50Z",completed_at:"2026-10-30T20:17:00Z",details_url:"https://sonarcloud.io/dashboard?id=hyperpolymath_vocarium&pullRequest=47"}' > "$tmp/base.json"
context_case() {
  local label=$1 expected=$2 filter=$3 event=${4:-pull_request} pr=${5:-47} id=${6:-10}
  local event_time=${7-2026-10-30T20:16:44Z} rc=0
  jq "$filter" "$tmp/base.json" > "$MOCK_RESPONSE"
  GITHUB_REPOSITORY="$repo" CHECK_RUN_ID="$id" SUBJECT_SHA="$sha" \
    EVENT_NAME="$event" EVENT_TIME="$event_time" PR_NUMBER="$pr" \
    bash "$tmp/context.sh" > "$tmp/log" 2>&1 || rc=$?
  if [[ $expected == success ]]; then
    [[ $rc == 0 ]] || { cat "$tmp/log"; fail "$label exited $rc"; }
  else
    [[ $rc -ne 0 ]] || fail "$label unexpectedly passed"
  fi
  echo "ok: $label"
}
context_case 'matching PR project and subject' success '.'
context_case 'matching main project and subject' success '.details_url="https://sonarcloud.io/dashboard?id=hyperpolymath_vocarium&branch=main"' push ''
push_epoch=$(date -u -d '2026-10-30T20:16:44Z' +%s)
context_case 'numeric push timestamp accepted' success '.details_url="https://sonarcloud.io/dashboard?id=hyperpolymath_vocarium&branch=main"' push '' 10 "$push_epoch"
context_case 'old same-SHA receipt from a prior event refused' failure '.started_at="2026-10-29T20:16:50Z" | .completed_at="2026-10-29T20:17:00Z"'
context_case 'old in-progress check finishing after a new event refused' failure '.started_at="2026-10-30T20:16:40Z"'
context_case 'same-second check is not provably fresh' failure '.started_at="2026-10-30T20:16:44Z"'
context_case 'missing start time refused' failure 'del(.started_at)'
context_case 'missing completion time refused' failure 'del(.completed_at)'
context_case 'completion before start refused' failure '.completed_at="2026-10-30T20:16:49Z"'
context_case 'missing event timestamp refused' failure '.' pull_request 47 10 ''
context_case 'invalid event timestamp refused' failure '.' pull_request 47 10 'yesterday;false'
context_case 'other project refused' failure '.details_url="https://sonarcloud.io/dashboard?id=other_project&pullRequest=47"'
context_case 'other PR refused' failure '.details_url="https://sonarcloud.io/dashboard?id=hyperpolymath_vocarium&pullRequest=48"'
context_case 'other branch refused for main push' failure '.' push ''
context_case 'wrong check ID refused' failure '.id=11'
context_case 'wrong commit / stale receipt refused' failure '.head_sha="ffffffffffffffffffffffffffffffffffffffff"'
context_case 'wrong check name refused' failure '.name="SonarQube"'
context_case 'wrong app ID refused' failure '.app.id=15368'
context_case 'wrong app slug refused' failure '.app.slug="impostor"'
context_case 'pending receipt refused' failure '.status="in_progress" | .conclusion=null'
context_case 'skipped receipt refused' failure '.conclusion="skipped"'
context_case 'stale conclusion refused' failure '.conclusion="stale"'
context_case 'genuine quality-gate failure refused' failure '.conclusion="failure"'
context_case 'malformed check identity refused' failure '.' pull_request 47 '10;touch /tmp/sonar-injection'
context_case 'untrusted PR number refused' failure '.' pull_request '47;false'
MOCK_ERROR=1 context_case 'check API denial fails closed' failure '.'
echo 'SonarQube consumer contract tests passed.'
