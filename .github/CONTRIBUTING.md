<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# Clone the repository
git clone https://github.com/hyperpolymath/vocarium.git
cd vocarium

# Using Guix (recommended for reproducibility)
guix shell -D -f build/guix.scm

# Or using toolbox/distrobox
toolbox create vocarium-dev
toolbox enter vocarium-dev
# Install dependencies manually

# Verify setup
just check   # or: cargo check / mix compile / etc.
just test    # Run test suite
```

### Repository Structure
```
vocarium/
├── src/                 # Source code (store: Zig, Perimeter 1-2)
│   ├── store/           # The voc store (src/store/main.zig → `voc`)
│   ├── contracts/       # Idris2 ABI contracts
│   ├── definitions/     # Shared definitions
│   ├── errors/          # Error specifications
│   └── aspects/         # Aspect specifications
├── build.zig            # Zig build (executable `voc`, zig-out/bin/voc)
├── docs/                # Documentation (Perimeter 3)
├── examples/            # Examples (Perimeter 3)
├── tests/               # Test suite (Perimeter 2-3)
├── .machine_readable/   # ALL machine-readable content (Perimeter 1)
│   ├── *.deed           # Deeds (STATE, META, NEUROSYM, AGENTIC, …)
│   ├── bot_directives/  # Bot configs
│   └── contractiles/    # Policy contracts (k9, dust, lust, must, trust)
├── .well-known/         # Protocol files (Perimeter 1-3)
├── .github/             # GitHub config (Perimeter 1)
│   ├── ISSUE_TEMPLATE/
│   ├── CODE_OF_CONDUCT.md
│   ├── CONTRIBUTING.md  # This file
│   ├── GOVERNANCE.md
│   ├── MAINTAINERS      # Maintainer contact (this repo: lead maintainer)
│   ├── SECURITY.md      # GitHub security policy
│   └── workflows/
├── CHANGELOG.adoc
├── CONTRIBUTING.adoc    # Root contributor guide
├── GOVERNANCE.adoc
├── LICENSE
├── MAINTAINERS.adoc
├── README.adoc
├── build/
│   └── guix.scm         # Guix package — primary (Perimeter 1)
└── Justfile             # Task runner (Perimeter 1)
```

---

## How to Contribute

### Reporting Bugs

**Before reporting**:
1. Search existing issues
2. Check if it's already fixed in `main`
3. Determine which perimeter the bug affects

**When reporting**:

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md) and include:

- Clear, descriptive title
- Environment details (OS, versions, toolchain)
- Steps to reproduce
- Expected vs actual behaviour
- Logs, screenshots, or minimal reproduction

### Suggesting Features

**Before suggesting**:
1. Check the [roadmap](ROADMAP.md) if available
2. Search existing issues and discussions
3. Consider which perimeter the feature belongs to

**When suggesting**:

Use the [feature request template](.github/ISSUE_TEMPLATE/feature_request.md) and include:

- Problem statement (what pain point does this solve?)
- Proposed solution
- Alternatives considered
- Which perimeter this affects

### Your First Contribution

Look for issues labelled:

- [`good first issue`](https://github.com/hyperpolymath/vocarium/labels/good%20first%20issue) — Simple Perimeter 3 tasks
- [`help wanted`](https://github.com/hyperpolymath/vocarium/labels/help%20wanted) — Community help needed
- [`documentation`](https://github.com/hyperpolymath/vocarium/labels/documentation) — Docs improvements
- [`perimeter-3`](https://github.com/hyperpolymath/vocarium/labels/perimeter-3) — Community sandbox scope

---

## Development Workflow

### Branch Naming
```
docs/short-description       # Documentation (P3)
test/what-added              # Test additions (P3)
feat/short-description       # New features (P2)
fix/issue-number-description # Bug fixes (P2)
refactor/what-changed        # Code improvements (P2)
security/what-fixed          # Security fixes (P1-2)
```

### Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/):
```
<type>(<scope>): <description>

[optional body]

[optional footer]

## Signed commits

Every commit that reaches the default branch must be signed; a ruleset refuses
unsigned pushes. Estate policy:
[SIGNING-POLICY](https://github.com/hyperpolymath/standards/blob/main/docs/SIGNING-POLICY.adoc).

- **People and interactive agents** sign with an SSH key registered on GitHub
  as a *signing* key (`gpg.format=ssh`, `user.signingkey=<key>.pub`,
  `commit.gpgsign=true`). The committer email must be verified on that account.
- **Apps, bots and workflows** never `git push` local commits. They write
  through the API (`createCommitOnBranch` or the estate `signed-push` action)
  so that GitHub signs each commit.
- Merge PRs with **squash**. The ruleset checks every commit on the PR branch,
  not just the result, so one unsigned commit blocks the merge. Re-create such a
  branch with signed commits (`git cherry-pick -S`) and open a new PR.
  Rebase-merge replays commits unsigned and is disabled.
