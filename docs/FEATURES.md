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
- Infrastructure - GitHub Actions/API failures, runner issues, network problems (detected by analyzing job logs)
- Type Check - steep/typecheck, type checking jobs
- Lint - rubocop, standard, actionlint, yaml-lint
- Security - CodeQL, semgrep
- Tests - unit tests, integration tests, e2e tests
- Build - build/compile jobs
- Uncategorized - anything else

**Components:**
- `Bells::GitHubClient` - Fetches workflow runs, CI status, failed jobs, JUnit artifacts, and job logs. Includes restart_job method.
- `Bells::FailureCategorizer` - Categorizes failed jobs by type. Analyzes job logs to detect infrastructure failures (GitHub API errors, runner issues, network problems) that take precedence over name-based categorization.
- `Bells::JunitParser` - Parses JUnit XML files to extract all test results (passes and failures)
- `Bells::FailureAggregator` - Groups test results and detects true flaky tests (tests that both pass and fail in the same PR)

**Auto-Restart:**
When "all-jobs-are-green" is the only failing job, it's automatically restarted in the background. This meta-check often fails due to race conditions when it runs before other jobs complete. A notice is displayed on the PR analysis page when auto-restart occurs.

**Configuration:**
- `BELLS_DEFAULT_AUTHOR` - Optional environment variable to filter PRs by a specific author by default. When set, the home page shows only that author's PRs, with an "All PRs" link to view all.

**Security:**
- XSS protection via automatic HTML escaping (erubi)
- Zip Slip protection for artifact extraction
- XXE injection protection for JUnit XML parsing
- Command injection protection (Open3 instead of backticks)
- See docs/SECURITY.md for complete security review

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

---

## Performance Optimizations

Comprehensive caching and optimization reducing PR detail page load time by 70% and API calls by 84%.

**Multi-Layer Caching Strategy:**
1. **HTTP/ETag Layer** - Conditional requests with ETags (304 Not Modified responses)
2. **Memory/LRU Layer** - In-memory cache with TTL and LRU eviction (max 1000 entries)
3. **Disk Layer** - Persistent file cache for analysis results, job logs, and artifacts

**Key Optimizations:**
- ETag-based conditional requests for `pull_request()` and `ci_status()` - eliminates redundant data transfer
- PR object passed through call stack - eliminates 5 redundant API calls per page load
- Check runs fetched once and filtered - eliminates duplicate pagination (4-8 fewer API calls)
- Job logs cached to disk at `.cache/logs/{job_id}.log` - prevents re-downloading 1-10MB files
- Two-pass JUnit parsing - parses failures first, then full results only for failed tests (70% faster)

**Performance Impact:**
- First visit (cold cache): 10-30s → 3-8s (70% improvement)
- After new commit (PR unchanged): 10-30s → 200-500ms (95% improvement)
- API calls per page load: 30-97 → 3-5 (84% reduction)

**Components:**
- `Bells::ETagCache` - Thread-safe ETag storage for conditional HTTP requests
- `Bells::PrCache` - LRU in-memory cache with TTL expiration and probabilistic cleanup
- `Bells::BackgroundRefresher` - Async task warming PR list cache every 2 minutes with exponential backoff on failures

**Cache Invalidation:**
- Analysis cache: 5-minute TTL, invalidated on HEAD SHA change
- Job logs: Permanent (immutable)
- Artifacts: Permanent (immutable, keyed by run_id)
- PR list: 2-minute TTL (background refresh)
- ETags: Validated on each request via If-None-Match header

**Documentation:**
- See `docs/etag-staleness-detection.md` for ETag architecture
- See `docs/pr-detail-page-performance-analysis.md` for detailed API call analysis
- See `docs/performance-improvements-implementation.md` for implementation summary
