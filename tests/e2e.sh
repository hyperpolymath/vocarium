#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# RSR Standard E2E Test Template — UNINSTANTIATED for vocarium.
#
# This is inherited mint-template scaffolding: every test section is commented
# out, so it has always exited 0 with PASS=0 FAIL=0 SKIP=0. A green run of this
# file is NOT evidence that anything was verified, and CI reported it as
# "E2E — template smoke" which reads as coverage that does not exist (#67).
#
# The real end-to-end proof for this repository is tests/e2e/invoke_slice.sh,
# run as the `invoke-slice gate` in vocarium-ci.yml. It asserts against the
# built `voc` binary and the pinned tropecheck-rs.
#
# This file therefore now REFUSES to report success when it ran no checks.
# Add real checks below and it will report them; until then it fails loudly
# rather than sitting green and empty.
#
# Usage:
#   bash tests/e2e.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # kept for the check bodies a project adds below
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
SKIP=0

# ─── Colour helpers ──────────────────────────────────────────────────
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

# ─── Assertion helpers ───────────────────────────────────────────────

# check <label> <expected-substring> <actual>
# shellcheck disable=SC2329,SC2317  # invoked by the checks a project adds below
check() {
    local name="$1" expected="$2" actual="$3"
    if echo "$actual" | grep -q "$expected"; then
        green "  PASS: $name"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $name (expected '$expected', got '${actual:0:120}')"
        FAIL=$((FAIL + 1))
    fi
}

# check_status <label> <expected-http-status> <actual-http-status>
# shellcheck disable=SC2329,SC2317  # invoked by the checks a project adds below
check_status() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        green "  PASS: $name (HTTP $actual)"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $name (expected HTTP $expected, got HTTP $actual)"
        FAIL=$((FAIL + 1))
    fi
}

# skip <label> <reason>
# shellcheck disable=SC2329,SC2317  # invoked by the checks a project adds below
skip_test() {
    yellow "  SKIP: $1 ($2)"
    SKIP=$((SKIP + 1))
}

echo "═══════════════════════════════════════════════════════════════"
echo "  vocarium — End-to-End Tests (template harness)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ─── Preflight ───────────────────────────────────────────────────────
bold "Preflight checks"

# TODO: Check that your binary/server is built
# Example:
# BINARY="$PROJECT_DIR/target/release/my-tool"
# if [ ! -f "$BINARY" ]; then
#     red "Binary not found at $BINARY — run 'just build' first"
#     exit 1
# fi
# green "  Binary found: $BINARY"

# TODO: Check dependencies
# command -v curl >/dev/null 2>&1 || { red "curl not found"; exit 1; }
# command -v jq >/dev/null 2>&1   || { red "jq not found"; exit 1; }

echo ""

# ═══════════════════════════════════════════════════════════════════════
# TODO: Add your E2E test sections below. Examples:
# ═══════════════════════════════════════════════════════════════════════

# ─── Example: CLI tool E2E ───────────────────────────────────────────
# bold "Section 1: CLI happy path"
# OUTPUT=$($BINARY --help 2>&1)
# check "help flag works" "Usage:" "$OUTPUT"
#
# OUTPUT=$($BINARY process input.txt --output /tmp/e2e-output.json 2>&1)
# check "process command succeeds" "complete" "$OUTPUT"
#
# OUTPUT=$(cat /tmp/e2e-output.json)
# check "output is valid JSON" '"status"' "$OUTPUT"

# ─── Example: Server E2E ────────────────────────────────────────────
# bold "Section 2: Server lifecycle"
# $BINARY serve --port 9999 &
# SERVER_PID=$!
# trap "kill $SERVER_PID 2>/dev/null" EXIT
# sleep 2
#
# STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9999/health)
# check_status "health endpoint" "200" "$STATUS"
#
# BODY=$(curl -s http://localhost:9999/health)
# check "health response" '"status":"ok"' "$BODY"
#
# kill $SERVER_PID 2>/dev/null

# ─── Example: VeriSimDB integration ─────────────────────────────────
# bold "Section 3: VeriSimDB persistence"
# VERISIM_URL="${VERISIM_API_URL:-http://localhost:9090}"
# if ! curl -sf "$VERISIM_URL/health" >/dev/null 2>&1; then
#     skip_test "VeriSimDB integration" "gateway not available"
# else
#     STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$VERISIM_URL/api/v1/hexads" \
#         -H "Content-Type: application/json" \
#         -d '{"tool":"vocarium","modality":"document","content":"e2e test"}')
#     check_status "hexad POST" "201" "$STATUS"
# fi

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════"
printf "  Results: "
green "PASS=$PASS" | tr -d '\n'
echo -n "  "
if [ "$FAIL" -gt 0 ]; then red "FAIL=$FAIL" | tr -d '\n'; else echo -n "FAIL=0"; fi
echo -n "  "
if [ "$SKIP" -gt 0 ]; then yellow "SKIP=$SKIP"; else echo "SKIP=0"; fi
echo "═══════════════════════════════════════════════════════════════"

# A suite that ran nothing must not exit 0. This is the whole point of the
# change: "PASS=0" was being read as a pass.
if [ "$PASS" -eq 0 ] && [ "$FAIL" -eq 0 ] && [ "$SKIP" -eq 0 ]; then
    red "No checks were defined or executed."
    echo "  This file is uninstantiated template scaffolding. A green run here"
    echo "  proves nothing. Either add real checks, or rely on the real gate:"
    echo "    bash tests/e2e/invoke_slice.sh   # invoke-slice gate (vocarium-ci)"
    exit 1
fi

exit "$FAIL"
