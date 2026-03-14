# Features

This document tracks major features in bells.

---

## CI Failure Analysis

Analyze CI failures in dd-trace-rb pull requests, grouped by category.

**Routes:**
- `GET /` - Home page with PR input form, list of open PRs, and CI status
- `GET /?author=<login>` - Filter PRs by author
- `GET /?show_all=true` - Show all PRs (overrides default author)
- `GET /pr/:number` - Analyze PR and display categorized failures (with progressive rendering)
- `GET /pr/:number/stream` - Server-Sent Events stream for progressive analysis updates
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
- `BELLS_DEFAULT_AUTHOR` - Optional environment variable to filter PRs by a specific author by default. When set:
  - Home page shows only that author's PRs (with "All PRs" link to view all)
  - Background refresher pre-warms full PR analysis for all PRs by that author
  - Makes PR detail pages instant for the author's PRs (artifacts, logs, test details cached)

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

## Progressive Rendering

PR detail pages use Server-Sent Events (SSE) to progressively update the UI as analysis completes, reducing perceived load time by 95%.

**User Experience:**
- Page renders immediately (600ms) with PR title, author, and CI status
- Loading spinners show progress for: job list, categorized failures, test details
- Sections populate as data becomes available (1.2s → 3.7s → 12s)
- Cached PRs show all data instantly (<100ms)

**Implementation:**
- `/pr/:number` - Renders skeleton page with loading spinners
- `/pr/:number/stream` - SSE endpoint streaming analysis events
- JavaScript client connects to SSE, updates DOM incrementally
- Fallback: Meta refresh for browsers without JavaScript

**Events Streamed:**
1. `pr_basic` - PR number, title, author (immediate)
2. `ci_status` - CI badge status (immediate)
3. `job_list` - Failed/passed/in-progress job counts (1.2s)
4. `categorized_failures` - Categorized job failures with restart buttons (3.7s)
5. `test_details` - Full JUnit test analysis (12s)
6. `complete` - Analysis finished, close connection

**Performance:**
- First visit (cold cache): 600ms perceived load (vs 12s blocking)
- Reload (warm cache): <100ms (all events sent instantly)
- After new commit: 600ms perceived load (cache invalidated)

**Browser Support:**
- Modern browsers: Full SSE support
- No JavaScript: Meta refresh fallback (reloads every 10 seconds)
- Old browsers: Auto-reconnect built into SSE standard

**Error Handling:**
- SSE connection errors trigger auto-reload after 5 seconds
- Server errors sent as SSE error events
- Graceful degradation to non-streaming mode in test environment

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
- `Bells::BackgroundRefresher` - Async task that:
  - Warms PR list cache every 2 minutes
  - Pre-warms full PR analysis for default author's PRs (if `BELLS_DEFAULT_AUTHOR` set)
  - Downloads artifacts, job logs, and test details in background
  - Uses exponential backoff on failures

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
