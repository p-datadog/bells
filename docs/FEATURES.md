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

Both GitHub Actions check runs and GitLab CI commit statuses are tracked. Pending commit statuses (e.g. `dd-gitlab/finishedExpected`) are included in the in-progress count.

**Failure Categories:**
- Meta - all-jobs-are-green (GitHub Actions), dd-gitlab/default-pipeline (GitLab CI) — meta-checks that wait for other jobs
- Infrastructure - GitHub Actions/API failures, runner issues, network problems (detected by analyzing job logs)
- Type Check - steep/typecheck, type checking jobs
- Lint - rubocop, standard, actionlint, yaml-lint
- Security - CodeQL, semgrep
- Tests - unit tests, integration tests, e2e tests
- Build - build/compile jobs
- Uncategorized - anything else

**Components:**
- `Bells::GitHubClient` - Fetches workflow runs, CI status, failed/passed/pending jobs and statuses, JUnit artifacts, and job logs. Includes restart_job method and GraphQL-based `pull_requests_with_status` for homepage.
- `Bells::FailureCategorizer` - Categorizes failed jobs by type. Analyzes job logs to detect infrastructure failures (GitHub API errors, runner issues, network problems) that take precedence over name-based categorization.
- `Bells::JunitParser` - Parses JUnit XML files to extract all test results (passes and failures)
- `Bells::FailureAggregator` - Groups test results and detects true flaky tests (tests that both pass and fail in the same PR)

**Auto-Restart:**
When the only failing jobs are meta-checks (all-jobs-are-green, dd-gitlab/default-pipeline), the restartable GitHub Actions jobs are automatically restarted in the background. These meta-checks often fail due to race conditions when they run before other jobs complete. A notice is displayed on the PR analysis page when auto-restart occurs.

**Configuration:**
- `BELLS_DEFAULT_AUTHOR` - Optional environment variable to filter PRs by a specific author by default. When set:
  - Home page shows only that author's PRs (with "All PRs" link to view all)
  - Background refresher pre-warms full PR analysis for all PRs by that author
  - Makes PR detail pages instant for the author's PRs (artifacts, logs, test details cached)
- `BELLS_BACKGROUND_REFRESH` - Set to `"false"` to disable all background operations (default: enabled)

**Security:**
- XSS protection via automatic HTML escaping (erubi)
- Zip Slip protection for artifact extraction
- XXE injection protection for JUnit XML parsing
- Command injection protection (Open3 instead of backticks)
- See docs/SECURITY.md for complete security review

**Usage:**
```bash
# Using bin/bells wrapper (recommended)
bin/bells                        # Default: background refresh enabled
bin/bells -a alice               # Filter by author + pre-warm their PRs
bin/bells -b                     # Disable background operations
bin/bells -a alice -b            # Filter by author, no background

# Long options
bin/bells --author alice --no-background

# Direct puma usage
bundle exec puma

# Development (auto-reload on file changes)
bundle exec rerun -- puma

# Advanced: environment variables
BELLS_DEFAULT_AUTHOR=alice bundle exec puma
BELLS_BACKGROUND_REFRESH=false bundle exec puma

# Visit http://localhost:9292
```

---

## Progressive Rendering

PR detail pages use Server-Sent Events (SSE) to progressively update the UI as analysis completes, reducing perceived load time by 95%.

**User Experience:**
- Skeleton renders immediately (~700ms) with PR title, author, CI status, and loading placeholders
- Loading placeholders match the final card layout (muted text) to minimize flicker on content swap
- Content sections populate via SSE as data becomes available
- Passing PRs (ci_status=:green): All sections populate instantly (~30ms), no API calls
- Failing PRs: Progressive updates as analysis completes (1s → 2s → 10s)
- Cached PRs: All data instant (<100ms)

**Implementation:**
- `/pr/:number` - Renders skeleton page immediately with PR title, author, CI status badge
- `/pr/:number/stream?ci_status=<status>` - SSE endpoint streaming analysis events
- JavaScript client connects to SSE, updates DOM incrementally as events arrive
- ci_status parameter enables green PR optimization (skip expensive operations)
- Fallback: Meta refresh for browsers without JavaScript (non-streaming mode in test environment)

**Events Streamed:**
1. `job_list` - Failed/passed/in-progress job counts, including pending commit statuses (~1s, or instant if ci_status=:green)
2. `categorized_failures_initial` - Name-based categorization without log downloads (~1s, instant)
3. `categorized_failures_final` - Updated categorization with infrastructure detection (~2s after parallel log downloads)
4. `test_details` - Full JUnit test analysis (~10s after artifact downloads and parsing, or instant if no failures)
5. `complete` - Analysis finished, close connection

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

## GitHub API Integration

Two API strategies: GraphQL for the homepage (bulk fetch), REST for PR detail pages (granular operations).

**GraphQL (Homepage):**

`pull_requests_with_status` fetches all open PRs with CI status in a single query via `POST /graphql`. Used by the homepage route and background refresher.

Query fetches per PR: `number`, `title`, `url`, `updatedAt`, `headRefName`, `headRefOid`, `author.login`, and `commits(last:1).commit.statusCheckRollup.state`.

Status mapping from GraphQL `StatusState` enum:
- `SUCCESS` → `:green`
- `PENDING` → `:pending_clean`
- `FAILURE` / `ERROR` → `:failed`
- `null` or other → `:unknown`

Returns `{ prs: [OpenStruct], ci_statuses: { number => symbol } }` — PR objects match the shape of REST PR objects so callers don't need to distinguish.

Replaces N+1 REST calls (1 `pull_requests` + N `combined_status`) with 1 GraphQL call.

**REST (PR Detail):**

PR analysis uses REST endpoints with ETag caching:
- `check_runs_for_ref` — paginated, ETag cached on first page (304 returns full cached result)
- `statuses` — paginated, ETag cached on first page
- `combined_status` — single call for CI badge on PR detail skeleton
- `workflow_run_artifacts` — for JUnit artifact downloads
- `actions/jobs/{id}/logs` — for infrastructure failure detection, cached to disk

All REST calls use the global `ETAG_CACHE` singleton for conditional requests.

## Performance Optimizations

Comprehensive caching and optimization reducing PR detail page load time by 98% (31s → 0.7s).

**Multi-Layer Caching Strategy:**
1. **HTTP/ETag Layer** - Conditional requests with ETags (304 Not Modified responses)
2. **Memory/LRU Layer** - In-memory cache with TTL, LRU eviction, per-key locking (max 1000 entries)
3. **Disk Layer** - Persistent file cache for analysis results, job logs, and artifacts

**Major Optimizations:**
1. **GraphQL for homepage PR list + CI status** - Single GraphQL query returns all PRs with `statusCheckRollup`
   - 31 REST calls (~6s) → 1 GraphQL call (~300ms), 97% fewer API calls
2. **combined_status API** - Single API call returning one status object (not 462 check runs)
   - 9s → 0.3s (97% faster)
3. **ETag caching on check_runs and commit_statuses** - Conditional requests return 304 when data unchanged
   - Subsequent refreshes: 5-7 API calls → 1 conditional request
4. **Single fetch for commit statuses** - Fetch once, filter locally instead of 3 separate paginated fetches
5. **Cache individual PRs from background** - Background refresh caches each PR individually for reuse
   - User PR fetch: 650ms → 47ms (93% faster)
6. **Skip work for passing PRs** - When ci_status is :green, skip check_runs, artifacts, and parsing
   - Saves 14.7s for passing PRs
7. **Parallel job log downloads** - Download logs concurrently instead of sequentially
   - 5 jobs: 4s → 0.8s (80% faster)
8. **Two-phase categorization** - Show initial results before infrastructure detection
   - User sees categories instantly, infrastructure detection follows
9. **PR object passed through call stack** - Eliminates 5 redundant API calls per page load
10. **Check runs fetched once and filtered** - Eliminates duplicate pagination
11. **Job logs cached to disk** at `.cache/logs/{job_id}.log` - Prevents re-downloading 1-10MB files
12. **Two-pass JUnit parsing** - Parses failures first, then full results only for failed tests

**Performance Impact:**

Passing PRs (most common):
- Before: 31s (fetch all check runs + all artifacts)
- After: 0.7s (skip everything)
- **98% improvement**

Failing PRs (with cached artifacts):
- Before: 31s
- After: 4-6s
- **81-87% improvement**

Measured timings (PR 5448, typical passing PR):
```
[MAIN ROUTE TIMING] 27ms - PR fetched (from cache)
[MAIN ROUTE TIMING] 28ms - CI status (from cache)
[MAIN ROUTE TIMING] 30ms - Skeleton rendered

[TIMING] 27ms - CI status green - skipping expensive operations
[TIMING] 27ms - All events sent

Total: 57ms server + ~650ms network/browser = ~700ms perceived
```

**Components:**
- `Bells::ETagCache` - Thread-safe ETag storage for conditional HTTP requests
- `Bells::PrCache` - LRU cache with per-key locking to prevent cache stampede
- `Bells::BackgroundRefresher` - Async task that:
  - Warms PR list cache every 2 minutes
  - Caches each PR individually (reusable by user requests)
  - Pre-warms full PR analysis for default author's PRs (if `BELLS_DEFAULT_AUTHOR` set)
  - Downloads artifacts, job logs, and test details in background
  - Uses exponential backoff on failures

**Cache Invalidation:**
- Analysis cache: 5-minute TTL, invalidated on HEAD SHA change
- Job logs: Permanent (immutable)
- Artifacts: Permanent (immutable, keyed by run_id)
- PR list: 2-minute TTL (background refresh)
- Individual PRs: 2-minute TTL (background refresh)
- ETags: Validated on each request via If-None-Match header

**Documentation:**
- See `docs/etag-staleness-detection.md` for ETag architecture
- See `docs/pr-detail-page-performance-analysis.md` for detailed API call analysis
- See `docs/performance-improvements-implementation.md` for implementation summary
