#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Local verification entry point required by the reusable governance workflow.
# Install the extension as documented by CI: gh extension install github/gh-actions-lock.
# Lockfile generation is deliberately a separate, explicit gh actions-lock run.
set -euo pipefail

if [[ $# -ne 1 || "$1" != "--verify-local" ]]; then
    echo "Usage: bash scripts/update-actions-lock.sh --verify-local" >&2
    exit 2
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ ! -f .github/workflows/actions.lock ]]; then
    echo "ERROR: .github/workflows/actions.lock is missing" >&2
    exit 1
fi

# --verify-local checks coverage offline without updating workflow references
# or the lockfile. Propagate failures; a stale lock must never look successful.
exec "${GH_BIN:-gh}" actions-lock --verify-local
