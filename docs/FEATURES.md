# Features

This document tracks major features in bells.

---

## CI Failure Analysis

Analyze CI failures in dd-trace-rb pull requests, grouped by category.

**Routes:**
- `GET /` - Home page with PR input form, list of open PRs, and CI status
- `GET /?author=<login>` - Filter PRs by author
- `GET /pr/:number` - Analyze PR and display categorized failures
- `GET /api/pr/:number` - JSON API for PR analysis

**CI Status:**
- Green - All checks passed
- Pending - In progress, no failures yet
- Pending (failing) - In progress, some already failed
- Failed - Completed with failures

**Failure Categories:**
- Type Check - steep/typecheck, type checking jobs
- Lint - rubocop, standard, actionlint, yaml-lint
- Security - CodeQL, semgrep
- Tests - unit tests, integration tests, e2e tests
- Build - build/compile jobs
- Uncategorized - anything else

**Components:**
- `Bells::GitHubClient` - Fetches workflow runs, CI status, failed jobs, and JUnit artifacts
- `Bells::FailureCategorizer` - Categorizes failed jobs by type
- `Bells::JunitParser` - Parses JUnit XML files to extract test failures
- `Bells::FailureAggregator` - Groups test failures, identifies flaky tests

**Usage:**
```bash
# Production
bundle exec puma

# Development (auto-reload on file changes)
bundle exec rerun -- puma

# Visit http://localhost:9292
```
