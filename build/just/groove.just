# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# GROOVE PROTOCOL
#
# Imported by ../../Justfile via `import? "build/just/groove.just"`.
# The old Groove template manifest was retired with A2ML. Do not generate
# service configuration for this repository without an actual service contract.

groove-setup:
    @echo "Groove setup unavailable: no Vocarium service manifest is declared." >&2; exit 1

# Check for template placeholders that haven't been replaced
verify-template:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Checking for unreplaced template placeholders..."
    FOUND=0

    # Check for double-brace placeholder patterns
    HITS=$(grep -rn '{{'{{'}}[A-Z_]*{{'}}'}}' --include="*.adoc" --include="*.md" --include="*.deed" \
          --include="*.scm" --include="*.toml" --include="*.yml" --include="*.yaml" \
          . 2>/dev/null | grep -v 'node_modules\|\.git/' | grep -v 'PLACEHOLDERS.adoc' || true)
    if [ -n "$HITS" ]; then
        echo ""
        echo "⚠ Unreplaced placeholders found:"
        echo "$HITS" | head -20
        FOUND=1
    fi

    # Check for template defaults still present
    if grep -q 'rsr-template-repo' Justfile 2>/dev/null; then
        echo "⚠ Justfile still references 'rsr-template-repo' — update project name"
        FOUND=1
    fi

    # Check for empty SCM files
    for f in .machine_readable/descriptiles/STATE.deed .machine_readable/descriptiles/META.deed vocarium_chora.deed; do
        if [ -f "$f" ] && grep -q '{{'{{'}}' "$f" 2>/dev/null; then
            echo "⚠ $f still has template placeholders"
            FOUND=1
        fi
    done

    if [ $FOUND -eq 0 ]; then
        echo "✓ No template placeholders found — project is properly customised."
    else
        echo ""
        echo "Run 'just init' to replace placeholders, or edit files manually."
        exit 1
    fi
