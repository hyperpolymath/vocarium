#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Contract test for the workflow-execution watcher (issue #59).
#
# Two halves, deliberately:
#
#   1. STATIC. The watch workflow must call the script, and must not depend on
#      any action — see the header of the workflow for why: a watchdog that
#      shares its subject's failure mode is not a watchdog. It must also be
#      registered in `actions.lock`, which is keyed by workflow path.
#
#   2. BEHAVIOURAL. The alarm logic is exercised against fixtures, because a
#      grep proves a file exists and this contract is about what the script
#      CONCLUDES. The fixtures are modelled on the real runs measured in #59:
#      a lane whose latest run is `startup_failure`, a lane that is alive, a
#      lane that merely failed (must not alarm), a tag-only lane that has never
#      run (must not alarm), a hand-disabled lane (must not alarm), and a
#      registry entry whose file is gone.
#
# The behavioural half runs offline via FIXTURES_DIR; it never touches the
# network and never needs a token.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

WORKFLOW=.github/workflows/workflow-execution-watch.yml
SCRIPT=scripts/check-workflow-failures.sh
LOCK=.github/workflows/actions.lock

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Static contract
# ---------------------------------------------------------------------------
[ -f "$WORKFLOW" ] || fail "missing $WORKFLOW"
[ -x "$SCRIPT" ] || fail "$SCRIPT is missing or not executable"
[ -f "$LOCK" ] || fail "missing $LOCK"

bash -n "$SCRIPT" || fail "$SCRIPT does not parse"

grep -Fxq "  schedule:" "$WORKFLOW" || fail 'watch workflow has no schedule trigger'
grep -Eq "^    - cron: '[0-9*/, -]+'$" "$WORKFLOW" || fail 'watch workflow has no cron'
grep -Fxq "  workflow_dispatch:" "$WORKFLOW" || fail 'watch workflow cannot be dispatched by hand'
grep -Fxq "  actions: read" "$WORKFLOW" || fail 'watch workflow cannot read run state'
grep -Fxq "  contents: read" "$WORKFLOW" || fail 'watch workflow cannot read the workflow directory'

# The whole point. `uses:` at any indentation, in a step or as a job.
if grep -Eq '^[[:space:]]*(uses|- +uses):' "$WORKFLOW"; then
    fail 'watch workflow depends on an action; it would die of a stale actions.lock'
fi
grep -q 'scripts/check-workflow-failures.sh' "$WORKFLOW" \
    || fail 'watch workflow does not run the checker'

# actions.lock is keyed by workflow path. An unlisted workflow never starts.
grep -Fxq "    '.github/workflows/workflow-execution-watch.yml': []" "$LOCK" \
    || fail 'watch workflow is not registered in actions.lock (it would startup_failure)'
pass 'static contract: no actions, registered, least privilege'

# ---------------------------------------------------------------------------
# 2. Behavioural contract
# ---------------------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/runs"

# Mirrors the contents API listing: workflows are files, plus two non-workflows
# that must be ignored.
cat > "$tmp/workflows-dir.json" <<'JSON'
[
  {"name": "alive.yml",          "type": "file"},
  {"name": "silent.yml",         "type": "file"},
  {"name": "red-but-started.yml","type": "file"},
  {"name": "tag-only.yml",       "type": "file"},
  {"name": "switched-off.yml",   "type": "file"},
  {"name": "deleted.yml",        "type": "file"},
  {"name": "actions.lock",       "type": "file"},
  {"name": "README.adoc",        "type": "file"}
]
JSON

cat > "$tmp/workflows.json" <<'JSON'
[
  {"path": ".github/workflows/alive.yml",          "state": "active"},
  {"path": ".github/workflows/silent.yml",         "state": "active"},
  {"path": ".github/workflows/red-but-started.yml","state": "active"},
  {"path": ".github/workflows/tag-only.yml",       "state": "active"},
  {"path": ".github/workflows/switched-off.yml",   "state": "disabled_manually"},
  {"path": ".github/workflows/deleted.yml",        "state": "active"},
  {"path": ".github/workflows/removed.yml",        "state": "active"},
  {"path": "dynamic/dependabot/dependabot-updates","state": "active"}
]
JSON

# A lane whose latest run created a job.
cat > "$tmp/runs/alive.yml.json" <<'JSON'
[{"event":"push","head_branch":"main","status":"completed","conclusion":"success","created_at":"2026-11-22T23:14:48Z"}]
JSON

# The #59 shape: every run dies before a job exists.
cat > "$tmp/runs/silent.yml.json" <<'JSON'
[{"event":"push","head_branch":"main","status":"completed","conclusion":"startup_failure","created_at":"2026-11-22T23:14:49Z"}]
JSON

# Red, but it started. The gate's business, not this watcher's.
cat > "$tmp/runs/red-but-started.yml.json" <<'JSON'
[{"event":"push","head_branch":"main","status":"completed","conclusion":"failure","created_at":"2026-11-22T23:13:25Z"}]
JSON

# Tag-only: never asked, so never failed to start.
cat > "$tmp/runs/tag-only.yml.json" <<'JSON'
[]
JSON

# Waiting for a human approval: rendered in the UI, so not silent.
cat > "$tmp/runs/switched-off.yml.json" <<'JSON'
[{"event":"push","head_branch":"main","status":"completed","conclusion":"action_required","created_at":"2026-11-22T23:00:00Z"}]
JSON

# `deleted.yml` has a file but no registry entry; `removed.yml` has a registry
# entry but no file. Neither can have failed to start.
cat > "$tmp/runs/deleted.yml.json" <<'JSON'
[]
JSON

# --- the alarming repository -------------------------------------------------
set +e
out="$(FIXTURES_DIR="$tmp" GITHUB_REPOSITORY=example/repo OUTPUT_FORMAT=text \
        bash "$SCRIPT" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "expected exit 1 when a workflow did not start, got $rc"
printf '%s' "$out" | grep -q 'silent.yml' || fail 'the silenced workflow was not reported'
printf '%s' "$out" | grep -q '::error title=Workflow did not start::silent.yml' \
    || fail 'no error annotation was emitted for the silenced workflow'
printf '%s' "$out" | grep -q '1 workflow(s) did not start' \
    || fail 'the alarm count is wrong (expected exactly one)'
pass 'behaviour: a startup_failure is reported, annotated and fails the run'

# A failure that started, a tag-only lane, a disabled lane, a never-registered
# file and a ghost registry entry must NOT raise the alarm — otherwise the red
# mark stops meaning "it did not start".
if printf '%s' "$out" | grep -qE '::error.*(red-but-started|tag-only|switched-off|deleted\.yml|removed\.yml)'; then
    fail 'a non-silent condition raised the alarm; red must mean only "did not start"'
fi
pass 'behaviour: failure, tag-only, disabled and ghost lanes stay silent'

# The json surface exists for a caller that wants to diff it.
json="$(FIXTURES_DIR="$tmp" GITHUB_REPOSITORY=example/repo OUTPUT_FORMAT=json \
        bash "$SCRIPT" 2>/dev/null || true)"
printf '%s' "$json" | jq -e '.alarms | length == 1' >/dev/null \
    || fail 'json output does not carry exactly one alarm'
printf '%s' "$json" | jq -e '.alarms[0].workflow == "silent.yml"' >/dev/null \
    || fail 'json alarm names the wrong workflow'
pass 'behaviour: json surface is machine-readable'

# --- a clean repository ------------------------------------------------------
rm -f "$tmp/runs/silent.yml.json"
cat > "$tmp/runs/silent.yml.json" <<'JSON'
[{"event":"push","head_branch":"main","status":"in_progress","conclusion":null,"created_at":"2026-11-22T23:20:00Z"}]
JSON
set +e
out="$(FIXTURES_DIR="$tmp" GITHUB_REPOSITORY=example/repo bash "$SCRIPT" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "expected exit 0 when every lane started, got $rc"
printf '%s' "$out" | grep -q 'No workflow failed to start' \
    || fail 'the clean case did not say so in words'
pass 'behaviour: an in-progress run counts as started, so the run is green'

# --- cannot tell must never look like all-clear ------------------------------
rm -rf "$tmp"
tmp="$(mktemp -d)"
set +e
out="$(FIXTURES_DIR="$tmp" GITHUB_REPOSITORY=example/repo bash "$SCRIPT" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "expected exit 2 on an unreadable source, got $rc"
pass 'behaviour: an unreadable source exits 2, never 0'

# --- usage errors are not silently tolerated --------------------------------
set +e
GITHUB_REPOSITORY=not-a-repo FIXTURES_DIR=/nonexistent bash "$SCRIPT" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "expected exit 2 on bad input, got $rc"
pass 'behaviour: bad input exits 2'

printf '\nWorkflow execution watch contract passed: static shape, alarm logic, \n'
printf 'silence for non-silent conditions, and fail-closed on "cannot tell".\n'
