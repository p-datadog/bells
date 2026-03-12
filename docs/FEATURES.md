# Features

This document tracks major features in bells.

---

## CI Failure Analysis

Analyze test failures in dd-trace-rb pull requests.

**Routes:**
- `GET /` - Home page with PR input form and list of open PRs
- `GET /?author=<login>` - Filter PRs by author
- `GET /pr/:number` - Analyze PR and display aggregated failures
- `GET /api/pr/:number` - JSON API for PR analysis

**Components:**
- `Bells::GitHubClient` - Fetches workflow runs and downloads JUnit artifacts
- `Bells::JunitParser` - Parses JUnit XML files to extract test failures
- `Bells::FailureAggregator` - Groups failures by test, identifies flaky tests

**Usage:**
```bash
# Production
bundle exec puma

# Development (auto-reload on file changes)
bundle exec rerun -- puma

# Visit http://localhost:9292
```
