# Contributing to hackathon-tools

Thank you for your interest in contributing! This document covers everything you need to know to get started.

---

## Prerequisites

Make sure the following tools are installed and available on your `PATH` before contributing:

| Tool | Minimum Version | Check |
|------|----------------|-------|
| **Bash** | 4.x+ | `bash --version` |
| **gh CLI** | 2.x+ | `gh --version` |
| **jq** | 1.6+ | `jq --version` |
| **git** | any recent | `git --version` |

> [!NOTE]
> macOS ships with Bash 3.2. Install a newer version via Homebrew: `brew install bash`.
> The scripts rely on `date` flags that differ between GNU and BSD — see [Coding Style](#coding-style) for how to handle this.

---

## Getting Started

1. **Fork** the repository and clone your fork:
   ```bash
   git clone https://github.com/<your-username>/hackathon-tools.git
   cd hackathon-tools
   ```

2. **Make the scripts executable:**
   ```bash
   chmod +x scripts/*.sh
   ```

3. **Authenticate with GitHub** (required for scripts that call the `gh` CLI):
   ```bash
   gh auth login
   ```

4. Create a new branch for your change:
   ```bash
   git checkout -b feat/my-improvement
   ```

---

## Testing Locally

### Syntax Check (required before every PR)

Run `bash -n` on all scripts to catch syntax errors without executing them:

```bash
for script in scripts/*.sh; do
  echo "Checking $script..."
  bash -n "$script" && echo "  OK"
done
```

### Functional Testing

Test against a real (or sandbox) GitHub organisation:

```bash
MY_ORG="my-sandbox-org"

# Export repos for an org
./scripts/export_org_repos.sh "$MY_ORG" -f repos.json

# Set up repos using the sample CSV
./scripts/setup_repos.sh -o "$MY_ORG" -f examples/collaborators.csv

# Audit commits in a time window (HH:MM, today)
./scripts/check_commits_window.sh repos.json 13:30 16:30 -o "$MY_ORG"

# Audit push activity in a time window
./scripts/check_inactive_pushes.sh "$MY_ORG" 17:00 18:30
```

---

## Coding Style

Follow these conventions to keep the codebase consistent:

### 1. Strict mode at the top of every script
```bash
#!/usr/bin/env bash
set -uo pipefail
```
> [!NOTE]
> We intentionally omit `-e` (`errexit`) because several scripts use `|| true` patterns
> around date-parsing commands that may return non-zero on certain inputs. Use explicit
> `|| { echo "error" >&2; exit 1; }` guards instead.

### 2. GNU + BSD `date` compatibility
Scripts must work on both Linux (GNU `date`) and macOS (BSD `date`). Use a cross-platform pattern:
```bash
# Prefer a helper that tries GNU first, then BSD
now_epoch() {
  date +%s 2>/dev/null || gdate +%s
}
```
Document any platform-specific workarounds with a comment.

### 3. `--help` via `sed`
Expose usage information through a heredoc at the top of the script, printed with `sed`:
```bash
# Usage: ./scripts/my_script.sh [OPTIONS]
# ...
[[ "${1:-}" == "--help" ]] && sed -n '/^# /s/^# //p' "$0" && exit 0
```

### 4. Consistent argument parsing
- Validate required positional arguments early and print usage on failure.
- Avoid `getopts` unless flags are genuinely needed — keep scripts simple.

### 5. Error messages and exit codes
- Print errors to `stderr`: `echo "Error: ..." >&2`
- Exit with code `1` on errors, `0` on success.

### 6. Comments
- Add a comment for every non-obvious command or logic block.
- Keep comments current — outdated comments are worse than no comments.

---

## Submitting a Pull Request

1. Ensure all scripts pass `bash -n` syntax checks.
2. Update `CHANGELOG.md` under the `[Unreleased]` section.
3. Push your branch and open a PR against `main`.
4. Fill in the PR template completely.
5. A maintainer will review within a few days.

---

## Reporting Bugs

Please use the [Bug Report](.github/ISSUE_TEMPLATE/bug_report.md) issue template and include:
- Your OS and tool versions (Bash, gh CLI, jq)
- The exact command you ran
- The full error output
