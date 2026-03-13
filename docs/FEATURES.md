# Features

This document tracks major features in bells.

---

## CI Failure Analysis

Analyze CI failures in dd-trace-rb pull requests, grouped by category.

**Routes:**
- `GET /` - Home page with PR input form, list of open PRs, and CI status
- `GET /?author=<login>` - Filter PRs by author
- `GET /?show_all=true` - Show all PRs (overrides default author)
- `GET /pr/:number` - Analyze PR and display categorized failures
- `GET /api/pr/:number` - JSON API for PR analysis

**CI Status:**
- Green - All checks passed
- Pending - In progress, no failures yet
- Pending (failing) - In progress, some already failed
- Failed - Completed with failures

**Failure Categories:**
- Meta - all-jobs-are-green (meta-check that waits for other jobs)
- Type Check - steep/typecheck, type checking jobs
- Lint - rubocop, standard, actionlint, yaml-lint
- Security - CodeQL, semgrep
- Tests - unit tests, integration tests, e2e tests
- Build - build/compile jobs
- Uncategorized - anything else

**Components:**
- `Bells::GitHubClient` - Fetches workflow runs, CI status, failed jobs, and JUnit artifacts. Includes restart_job method.
- `Bells::FailureCategorizer` - Categorizes failed jobs by type
- `Bells::JunitParser` - Parses JUnit XML files to extract all test results (passes and failures)
- `Bells::FailureAggregator` - Groups test results and detects true flaky tests (tests that both pass and fail in the same PR)

**Auto-Restart:**
When "all-jobs-are-green" is the only failing job, it's automatically restarted in the background. This meta-check often fails due to race conditions when it runs before other jobs complete. A notice is displayed on the PR analysis page when auto-restart occurs.

**Configuration:**
- `BELLS_DEFAULT_AUTHOR` - Optional environment variable to filter PRs by a specific author by default. When set, the home page shows only that author's PRs, with an "All PRs" link to view all.

**Usage:**
```bash
# Production
bundle exec puma

# Development (auto-reload on file changes)
bundle exec rerun -- puma

# With default author filter
BELLS_DEFAULT_AUTHOR=ivoanjo bundle exec puma

# Visit http://localhost:9292
```
