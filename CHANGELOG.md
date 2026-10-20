# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

---

## [1.0.0] - 2026-10-20

### Added

- **`scripts/setup_repos.sh`** — Provisions private GitHub repositories for each team in a hackathon organisation and invites listed members as collaborators. Reads a headerless CSV (`team,user1,user2,...`). Supports configurable org (`-o`), CSV path (`-f`), permission level (`-p`), and a `CREATE_IF_MISSING` env flag to skip repo creation on re-runs.

- **`scripts/export_org_repos.sh`** — Lists all repositories in a GitHub organisation and writes them to a JSON file (`{ "repo-name": [], ... }`) ready for the checkpoint checkers. Supports prefix/regex filtering, archived/fork exclusion, and optional collaborator fetching (`--members`).

- **`scripts/check_commits_window.sh`** — Checkpoint auditor using the GitHub Commits API. Verifies each team's default branch has at least one commit within a given time window. Accepts `HH:MM` or `"YYYY-MM-DD HH:MM"` time formats with full timezone and midnight-crossing support.

- **`scripts/check_inactive_pushes.sh`** — Checkpoint auditor using the GitHub Activity API. Identifies repos with zero push events to any branch during a time window. Accepts the same time formats as `check_commits_window.sh`. Discovers repos live via `gh repo list` — no JSON file needed.

- **`examples/collaborators.csv`** — Sample CSV input for `setup_repos.sh` with 6 teams and 3 members each.

- **`examples/repos.json`** — Sample JSON output of `export_org_repos.sh` matching the example CSV.

[Unreleased]: https://github.com/your-org/hackathon-tools/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/your-org/hackathon-tools/releases/tag/v1.0.0
