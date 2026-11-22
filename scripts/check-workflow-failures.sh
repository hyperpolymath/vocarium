#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-workflow-failures.sh — raise an alarm when a workflow never STARTS.
#
# `startup_failure` is the only conclusion that is invisible. GitHub creates no
# job, writes no log, and emits no check run, so `gh pr checks`, the PR Files
# tab and branch protection all show nothing whatsoever. A required lane can be
# dead for weeks and the sole symptom is the absence of a check nobody was
# waiting for. That is issue #59: six lanes, five different pins, no verified
# common cause — and, until this script, no alarm.
#
# THE ALARM IS DELIBERATELY NARROW. It fires on one condition only: the latest
# run of a registered, enabled workflow concluded `startup_failure`. Everything
# else is REPORTED but does not fail the run, because a red mark has to keep
# meaning exactly one thing or people learn to ignore it:
#
#   * a run that started and FAILED is red and visible already — judging that
#     is the gate's job, not this watcher's;
#   * `action_required` waits on an approval prompt that IS rendered in the
#     Actions UI: noisy, not silent;
#   * a workflow that never triggered (`release.yml` is tag-only) has not
#     failed to start; it has not been asked;
#   * a workflow disabled by hand was switched off on purpose.
#
# WHY THE LATEST RUN AND NOT A LOOKBACK WINDOW: if a lane's most recent run is
# a startup_failure, nothing has run since, whatever the date — so the age of
# that run is irrelevant to the verdict. Age is used only to flag a lane that
# has gone quiet, which is information, not a failure.
#
# Exit codes:
#   0 — no workflow failed to start
#   1 — at least one registered, enabled workflow did not start
#   2 — cannot tell (usage, auth, or API failure) and no alarm was found.
#       Never reported as 0: "did not check" must not look like "all clear".
#
# Environment:
#   GITHUB_REPOSITORY   owner/repo (default: derived from the git remote)
#   QUIET_DAYS          window used only to flag a quiet lane (default 35:
#                       a monthly cron plus a week of grace, so an ordinary
#                       monthly job is not misreported as dead)
#   GH_BIN              gh executable (default: gh)
#   OUTPUT_FORMAT       text (default) | json
#   FIXTURES_DIR        offline mode: read API payloads from this directory
#                       instead of the network. Used by the contract test so
#                       the alarm logic is exercised, not merely grepped.
set -uo pipefail

GH_BIN="${GH_BIN:-gh}"
QUIET_DAYS="${QUIET_DAYS:-35}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-text}"
FIXTURES_DIR="${FIXTURES_DIR:-}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

printf '%s' "$QUIET_DAYS" | grep -qE '^[0-9]+$' \
    || die "QUIET_DAYS must be a whole number of days, got '$QUIET_DAYS'"

REPO="${GITHUB_REPOSITORY:-}"
if [ -z "$REPO" ]; then
    REPO="$(git config --get remote.origin.url 2>/dev/null \
        | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
fi
printf '%s' "$REPO" | grep -qE '^[^/]+/[^/]+$' \
    || die "cannot determine owner/repo (set GITHUB_REPOSITORY)"

command -v jq >/dev/null 2>&1 || die "jq not found; cannot classify workflow state"

# ---------------------------------------------------------------------------
# Where ground truth comes from.
#
# Both lists are read from the API rather than from a checkout, for two
# reasons:
#   1. A runner's working tree is whatever ref it happens to hold; the API is
#      the repository. They disagree exactly when it matters.
#   2. It keeps this workflow free of `uses:`. A watcher that depends on an
#      action is one stale `actions.lock` entry away from dying of
#      startup_failure itself — silently, which is the joke this file exists
#      to prevent.
#
# Two lists, because they answer different questions:
#   files    — every workflow the default branch *offers*   (contents API)
#   registry — every workflow GitHub has ever *registered*  (actions API)
# A file with no registry entry has never been triggered; a registry entry
# with no file is the footprint of a rename or deletion and can never run
# again. The second is reported, not alarmed: it costs nothing to know which
# lanes are ghosts.
# ---------------------------------------------------------------------------
if [ -n "$FIXTURES_DIR" ]; then
    [ -d "$FIXTURES_DIR" ] || die "FIXTURES_DIR is not a directory: $FIXTURES_DIR"
    for required in workflows-dir.json workflows.json; do
        [ -s "$FIXTURES_DIR/$required" ] \
            || die "missing or empty $FIXTURES_DIR/$required"
    done
    LISTING="$(cat "$FIXTURES_DIR/workflows-dir.json")"
    STATES="$(cat "$FIXTURES_DIR/workflows.json")"
    runs_for() { cat "$FIXTURES_DIR/runs/$1.json" 2>/dev/null; }
else
    command -v "$GH_BIN" >/dev/null 2>&1 \
        || die "$GH_BIN not found; cannot read workflow state"
    LISTING="$("$GH_BIN" api "repos/$REPO/contents/.github/workflows" \
        --jq '[ .[] | { name: .name, type: .type } ]')" \
        || die "could not list .github/workflows in $REPO"
    STATES="$("$GH_BIN" api "repos/$REPO/actions/workflows?per_page=100" \
        --jq '[ .workflows[] | { path: .path, state: .state } ]')" \
        || die "could not list registered workflows in $REPO"
    runs_for() {
        "$GH_BIN" api "repos/$REPO/actions/workflows/$1/runs?per_page=100" \
            --jq '[ .workflow_runs[] | { event, head_branch, status, conclusion, created_at } ]'
    }
fi

# Only `*.yml` / `*.yaml` at the top of .github/workflows are workflows;
# `actions.lock` and `README.adoc` sit in the same directory and are not.
mapfile -t WATCH < <(
    printf '%s' "$LISTING" \
        | jq -r '.[] | select(.type == "file") | .name | select(test("\\.ya?ml$"))' 2>/dev/null \
        | sort
)
[ "${#WATCH[@]}" -gt 0 ] || die "found no workflow files in .github/workflows"

# ---------------------------------------------------------------------------
# Classification. "Did a job ever exist" is the question. `conclusion` answers
# it for a finished run; an unfinished one (queued / in_progress / waiting)
# has a null conclusion and has already started, so it counts as alive.
# ---------------------------------------------------------------------------
classify() {  # classify <runs-json-array>
    jq -r --argjson days "$QUIET_DAYS" '
        (now - ($days * 86400)) as $cutoff
        | sort_by(.created_at) as $sorted
        | ($sorted | last) as $latest
        | if ($sorted | length) == 0 then
            "never-ran\tno run has ever been recorded; has it ever been triggered?"
          elif $latest.conclusion == "startup_failure" then
            "did-not-start\tlatest run (\($latest.created_at), \($latest.event) on \($latest.head_branch // "?")) created no job"
          elif $latest.status != "completed" then
            "running\tlatest run is \($latest.status), so the lane is alive"
          elif ($latest.created_at | fromdateiso8601) < $cutoff then
            "quiet\tlast run (\($latest.conclusion)) was \($latest.created_at), older than \($days) days"
          elif $latest.conclusion == "action_required" then
            "awaiting-approval\tlatest run is waiting for an approval shown in the Actions UI"
          else
            "ok\tlatest run concluded \($latest.conclusion // "unknown") (\($latest.event), \($latest.created_at))"
          end
    ' <<<"$1" 2>/dev/null
}

ROWS=()
UNKNOWN=0

row() { ROWS+=("$1"$'\t'"$2"$'\t'"$3"); }

for workflow_file in "${WATCH[@]}"; do
    path=".github/workflows/$workflow_file"

    state="$(printf '%s' "$STATES" \
        | jq -r --arg p "$path" 'map(select(.path == $p)) | .[0].state // "unregistered"' \
            2>/dev/null)"

    case "$state" in
        disabled_manually)
            row "$workflow_file" disabled "switched off by hand; not a failure to start"
            continue ;;
        unregistered)
            row "$workflow_file" unregistered "no registered workflow for this path; never triggered"
            continue ;;
        active) ;;
        *)
            row "$workflow_file" unknown "unexpected state '$state'"
            UNKNOWN=1
            continue ;;
    esac

    if ! runs="$(runs_for "$workflow_file")" || [ -z "$runs" ]; then
        row "$workflow_file" unknown "could not read runs for this workflow"
        UNKNOWN=1
        continue
    fi
    if ! verdict="$(classify "$runs")" || [ -z "$verdict" ]; then
        row "$workflow_file" unknown "could not classify this workflow (unexpected payload)"
        UNKNOWN=1
        continue
    fi
    row "$workflow_file" "${verdict%%$'\t'*}" "${verdict#*$'\t'}"
done

# Registry entries whose file no longer exists. `dynamic/...` paths are GitHub's
# own, not ours, and are skipped.
while IFS=$'\t' read -r ghost_path ghost_state; do
    [ -n "$ghost_path" ] || continue
    case "$ghost_path" in .github/workflows/*) ;; *) continue ;; esac
    ghost_file="${ghost_path#.github/workflows/}"
    printf '%s\n' "${WATCH[@]}" | grep -Fxq "$ghost_file" && continue
    row "$ghost_file" ghost "registered ($ghost_state) but no such file on the default branch; it can never run"
done < <(printf '%s' "$STATES" \
    | jq -r '.[] | [ .path, .state ] | @tsv' 2>/dev/null)

PATTERN=$'\t'"did-not-start"$'\t'
ALARM_COUNT=0
for r in "${ROWS[@]}"; do
    case "$r" in *"$PATTERN"*) ALARM_COUNT=$((ALARM_COUNT + 1)) ;; esac
done

# ---------------------------------------------------------------------------
# Render.
# ---------------------------------------------------------------------------
if [ "$OUTPUT_FORMAT" = "json" ]; then
    printf '%s\n' "${ROWS[@]}" | jq -R -s --arg repo "$REPO" --argjson days "$QUIET_DAYS" '
        split("\n") | map(select(length > 0) | split("\t")
            | { workflow: .[0], verdict: .[1], detail: (.[2] // "") })
        | { repo: $repo, quiet_days: $days, workflows: .,
            alarms: [ .[] | select(.verdict == "did-not-start") ] }
    '
else
    printf '=== Workflow execution watch: %s ===\n' "$REPO"
    printf '    A workflow whose latest run says startup_failure created no job,\n'
    printf '    no log and no check run. Nothing else in this repository reports it.\n\n'
    printf '%s\n' "${ROWS[@]}" | awk -F'\t' '
        { mark = ($2 == "did-not-start") ? "ALARM" : ($2 == "ok") ? "  ok " : "  -- "
          printf "  %s  %-42s %s\n", mark, $1, $2
          printf "            %s\n", $3 }
    '
    printf '\n'
    if [ "$ALARM_COUNT" -gt 0 ]; then
        printf '%s workflow(s) did not start:\n' "$ALARM_COUNT"
        printf '%s\n' "${ROWS[@]}" \
            | awk -F'\t' '$2 == "did-not-start" { printf "  - %s (%s)\n", $1, $3 }'
        printf '\nThe GitHub API does not expose the startup_failure reason, so the\n'
        printf 'run page carries an annotation or nothing at all. See issue #59.\n'
    else
        printf 'No workflow failed to start.\n'
    fi

    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            printf '## Workflow execution watch\n\n'
            printf '| Workflow | Verdict | Detail |\n| --- | --- | --- |\n'
            printf '%s\n' "${ROWS[@]}" | awk -F'\t' '{ printf "| `%s` | %s | %s |\n", $1, $2, $3 }'
        } >> "$GITHUB_STEP_SUMMARY"
    fi
fi

# Annotations survive above the fold on the run page; the step log does not.
# In json mode they go to stderr, so stdout stays a single parseable document.
if [ "$ALARM_COUNT" -gt 0 ]; then
    if [ "$OUTPUT_FORMAT" = "json" ]; then
        ANNOTATE_TO=/dev/stderr
    else
        ANNOTATE_TO=/dev/stdout
    fi
    printf '%s\n' "${ROWS[@]}" | awk -F'\t' -v out="$ANNOTATE_TO" '$2 == "did-not-start" {
        printf "::error title=Workflow did not start::%s %s. GitHub created no job, so no check run exists to be red.\n", $1, $3 > out
    }'
fi

# A finding outranks an unknown: report what is known, then say what is not.
if [ "$ALARM_COUNT" -gt 0 ]; then
    [ "$UNKNOWN" -eq 1 ] && printf 'NOTE: some workflows could not be read; see the table above.\n' >&2
    exit 1
fi
[ "$UNKNOWN" -eq 1 ] && exit 2
exit 0
