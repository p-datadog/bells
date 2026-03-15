# Progressive Rendering Design

## Problem Statement

### User Experience Issue

PR analysis pages take 10-30 seconds to load due to expensive operations:
- Fetching 100-462 GitHub Actions check runs (1-7 seconds)
- Downloading job logs for infrastructure detection (2-5 seconds)
- Downloading JUnit artifacts (5-15 seconds)
- Parsing XML test results (1-3 seconds)

**Current behavior:** User clicks link → blank page → waits 10-30 seconds → complete page appears

**User impact:**
- High perceived latency (feels unresponsive)
- No feedback during wait (appears frozen)
- High bounce rate (users give up)

### Requirements

1. **Immediate feedback** - Show something within 1 second
2. **Progressive updates** - Show data as it becomes available
3. **Maintain correctness** - Don't sacrifice data accuracy for speed
4. **Backward compatibility** - Work without JavaScript (fallback)
5. **Performance** - Initial render < 2 seconds for typical PRs

---

## Design

### Architecture: Server-Sent Events (SSE)

**Chosen over alternatives:**
- ❌ Polling: Inefficient, 2-second granularity, requires page reload
- ❌ WebSockets: Overkill for one-way communication, more complex
- ✅ SSE: Simple, efficient, one-way streaming, auto-reconnect

### Two-Phase Rendering

#### Phase 1: Skeleton (Immediate)

**Route:** `GET /pr/:number`

**Fetch:**
- PR object (title, author) - ~400ms
- CI status badge - ~300ms

**Render:**
- HTML skeleton with:
  - PR header (title, author, CI badge)
  - Empty content sections
  - JavaScript that connects to SSE

**Time budget:** < 1 second

**Output:** HTML page with embedded JavaScript

#### Phase 2: Progressive Data Loading (Background)

**Route:** `GET /pr/:number/stream?ci_status=<status>`

**Process:**
1. Start SSE connection
2. Run analysis in background
3. Yield events as work completes
4. Client JavaScript updates DOM for each event

**Events:**
- `job_list` - Failed/passed/in-progress counts
- `categorized_failures_initial` - Name-based categorization (no log downloads)
- `categorized_failures_final` - With infrastructure detection (after log downloads)
- `test_details` - JUnit test results
- `complete` - Close connection

**Time budget:** Varies by PR complexity (0.1s to 30s)

---

## Data Flow

```
User clicks /pr/5448
    ↓
GET /pr/5448 (skeleton route)
├─ Fetch PR (from PR_CACHE if available)
├─ Fetch CI status (from PR_CACHE if available)
├─ Render HTML skeleton
│  └─ Includes: <script>EventSource('/pr/5448/stream?ci_status=green')</script>
└─ Return HTML (< 1 second)
    ↓
Browser receives HTML
├─ Displays: PR title, author, CI badge
├─ Shows: Empty content sections
└─ JavaScript executes: new EventSource(...)
    ↓
GET /pr/5448/stream?ci_status=green (SSE route)
├─ Parse ci_status parameter
├─ IF ci_status == :green
│  ├─ Skip ALL expensive operations
│  ├─ Yield: job_list (empty, 0ms)
│  ├─ Yield: categorized_failures_initial (empty, 0ms)
│  ├─ Yield: categorized_failures_final (empty, 0ms)
│  ├─ Yield: test_details (empty, 0ms)
│  └─ Yield: complete
│  └─ Total: ~30ms
├─ ELSE (has failures or unknown status)
│  ├─ Fetch check runs (~1-7s)
│  ├─ Yield: job_list (~1s)
│  ├─ Categorize (name-based, no logs)
│  ├─ Yield: categorized_failures_initial (~1s)
│  ├─ Download logs in parallel (~1s)
│  ├─ Yield: categorized_failures_final (~2s)
│  ├─ Download artifacts (~5-15s)
│  ├─ Parse JUnit (~1-3s)
│  ├─ Yield: test_details (~10-30s)
│  └─ Yield: complete
└─ Close SSE connection
    ↓
JavaScript receives events
├─ On job_list: Update job summary section
├─ On categorized_failures_initial: Show categories (preliminary)
├─ On categorized_failures_final: Update categories (with infrastructure detection)
├─ On test_details: Show test failure table
└─ On complete: Close connection
```

---

## Optimization Strategies

### 1. Green PR Fast Path

**Trigger:** `ci_status == :green` (all jobs passed)

**Logic:**
```ruby
if ci_status == :green
  # All passed - no failures to analyze
  # Skip: check_runs, job logs, artifacts, parsing
  # Return: Empty results in ~30ms
end
```

**Rationale:** Passing PRs have no failures to analyze, so expensive operations produce no value.

**Correctness:** Safe - if CI is green, there are definitionally no failures.

### 2. Progressive Event Streaming

**Trigger:** Always (for non-green PRs)

**Logic:**
```ruby
# Send job counts FIRST (fast)
yield(:job_list, counts)

# THEN categorize (slower)
yield(:categorized_failures_initial, categories_without_logs)

# THEN infrastructure detection (slowest)
yield(:categorized_failures_final, categories_with_logs)

# THEN test details (slowest)
yield(:test_details, junit_results)
```

**Rationale:** Show something quickly, refine later.

**Correctness:** Initial categorization approximate (name-based), final categorization accurate (with log analysis).

### 3. Two-Phase Categorization

**Phase 1 (Fast):** Name-based categorization
- No log downloads
- Pattern matching on job names
- Sent immediately

**Phase 2 (Accurate):** Infrastructure detection
- Download job logs in parallel
- Scan for infrastructure patterns
- Update categorization

**Rationale:** Show initial results quickly, refine with infrastructure detection.

**Correctness:** Phase 1 may misclassify infrastructure failures as code failures. Phase 2 corrects this.

### 4. Cache Reuse

**Skeleton route caches:**
- Individual PRs in PR_CACHE (from background refresh)
- CI statuses in PR_CACHE (from background refresh)

**SSE route reuses:**
- PR object (if cached, no API call)
- CI status (passed as parameter, no recomputation)

**Rationale:** Background refresh work should benefit user requests.

**Correctness:** Cache has TTL (2 minutes) and validates HEAD SHA.

---

## Caching Strategy

### PR_CACHE (In-Memory)

**Keys:**
- `"pr_list"` → { prs: [...], ci_statuses: {...} }
- `"pr:5448"` → PR object
- (Used by skeleton route)

**TTL:** 2 minutes (background refresh interval)

### File Cache (Disk)

**Keys:**
- `.cache/5447/analysis.json` → Full analysis results
- `.cache/logs/12345.log` → Job logs
- `.cache/5447/23075_artifact/` → JUnit artifacts

**TTL:**
- Analysis: 5 minutes OR HEAD SHA change
- Logs: Permanent (immutable)
- Artifacts: Permanent (immutable)

### ETag Cache (In-Memory)

**Keys:**
- `"pull:5448"` → PR ETag
- `"combined_status:abc123"` → CI status ETag

**TTL:** None (validated on each request with If-None-Match)

---

## Performance Budget

### Skeleton Route (Phase 1)

**Goal:** < 1 second

**Operations:**
- GitHubClient init: ~30ms
- PR fetch (cache hit): ~0ms (cache miss: ~400ms)
- CI status (cache hit): ~0ms (cache miss: ~300ms)
- ERB render: ~50ms

**Total:** 50-800ms ✅

### SSE Route (Phase 2) - Green PRs

**Goal:** < 100ms for green PRs

**Operations:**
- Detect ci_status=:green
- Skip all expensive work
- Send empty events
- Close

**Total:** ~30ms ✅

### SSE Route (Phase 2) - Failing PRs

**Goal:** First event < 2 seconds

**Operations:**
- Fetch check runs: ~1-7s (depends on count)
- Send job_list event: < 2s ⚠️
- (Background: logs, artifacts, parsing)

**Total to first event:** 1-7s ⚠️ (violates goal for >100 check runs)

---

## Critical Requirements (Correctness)

### Must Be Accurate

1. **CI status** - Must reflect actual GitHub state (not stale)
2. **Job counts** - Failed/passed/in-progress must be correct
3. **Infrastructure detection** - Must analyze logs (cannot skip)
4. **Test failures** - Must parse actual JUnit results (cannot skip)

### Can Be Progressive

1. **Initial categorization** - Can show name-based first, refine later
2. **Test details** - Can load in background (not needed for initial decision)
3. **Artifact downloads** - Can defer until user requests detail view

### Cannot Skip (Correctness)

1. **CI status validation** - Must know if PR is passing/failing
2. **Failed job list** - Must know which jobs failed
3. **Job logs for infrastructure** - Must distinguish infrastructure vs code failures

### Can Skip (Optimization)

1. **All work for green PRs** - If CI green, no failures to analyze
2. **Artifacts for passing PRs** - No test failures to show
3. **GitLab statuses if GitHub has no failures** - Only relevant if GitHub green but GitLab red

---

## Event Contract

### job_list

```json
{
  "failed_jobs": 5,
  "in_progress": 2,
  "passed_jobs": 100,
  "failed_job_names": ["steep/typecheck", "rubocop/lint", ...]
}
```

**When sent:** Immediately after counting jobs (~1s)

**Allows user to:** See which jobs failed, decide if worth investigating

### categorized_failures_initial

```json
{
  "categorized": {
    "tests": [{job_name: "...", job_id: 123, url: "...", details: null}],
    "lint": [...]
  },
  "meta_failures": null,
  "auto_restarted": false
}
```

**When sent:** After name-based categorization (~1s)

**Accuracy:** Approximate (may misclassify infrastructure as code)

### categorized_failures_final

```json
{
  "categorized": {
    "infrastructure": [{..., details: "Error: API rate limit"}],
    "tests": [...]
  },
  "meta_failures": [...],
  "auto_restarted": true
}
```

**When sent:** After log analysis (~2-5s)

**Accuracy:** Accurate (includes infrastructure detection)

### test_details

```json
{
  "total_failures": 10,
  "unique_tests": 5,
  "flaky_tests": 2,
  "aggregated": [{test_class: "...", test_name: "...", failure_count: 3, ...}]
}
```

**When sent:** After artifact download and parsing (~10-30s)

**Accuracy:** Complete (all test failures with stack traces)

---

## CRITICAL REVIEW

### Completeness Issues

#### ❌ Missing: Performance Budget Enforcement

**Problem:** No code that actually enforces < 2s goal for first event

**Evidence:** We're fetching 462 check runs before first event (7 seconds)

**Missing from design:**
- How to handle PRs with >100 check runs
- Whether to limit pagination for first event
- Trade-off between accuracy and speed

**Needs:** Specify that first event MUST use limited pagination or cached data

#### ❌ Missing: ci_status Optimization Implementation Details

**Problem:** Design says "skip if green" but doesn't specify:
- Where does ci_status come from? (homepage cache? API call?)
- What if cache miss? (do we compute or skip optimization?)
- How to ensure it's passed correctly to SSE route?

**Current issue:** ci_status optimization exists in code but isn't consistently working

**Needs:** Specify complete flow: skeleton fetches → passes to JavaScript → JavaScript passes to SSE

#### ❌ Missing: Cache Key Strategy

**Problem:** Design mentions caching but doesn't specify:
- Exact cache keys for each operation
- Which cache (PR_CACHE vs file cache vs ETag cache) for what data
- How background refresh data should be keyed for user request reuse

**Evidence of problem:** Background refresh wasn't helping because cache keys didn't match

**Needs:** Explicit cache key specification for each data type

#### ❌ Missing: Error/Edge Case Handling

**Not specified:**
- What if SSE connection fails? (currently: auto-reload after 5s)
- What if PR has no check runs? (unknown status)
- What if GitHub API rate limited during streaming?
- What if analysis throws exception mid-stream?

**Needs:** Error handling specification for each edge case

#### ❌ Missing: Fallback Behavior

**Design mentions:** "Meta refresh for browsers without JavaScript"

**Not specified:**
- How often does meta refresh run?
- Does it fall back to blocking render?
- What's the degraded experience?

**Current implementation:** 10-second meta refresh, but unclear if blocking or non-blocking

### Accuracy Issues

#### ⚠️ Inaccurate: Performance Claims

**Design says:**
- "600ms perceived load"
- "First event at 1.2s"

**Reality (measured):**
- Skeleton: 650-1900ms (depends on cache)
- First event: 1-7s (depends on check run count)

**Issue:** Performance numbers in design don't match implementation

#### ⚠️ Inaccurate: Event List

**Design lists events:**
1. pr_basic
2. ci_status
3. job_list
4. categorized_failures
5. test_details
6. complete

**Actual implementation:**
1. job_list
2. categorized_failures_initial
3. categorized_failures_final
4. test_details
5. complete

**Issue:** Design lists 6 events including pr_basic/ci_status, implementation has 5 different events

**This is a critical discrepancy!**

#### ⚠️ Incomplete: Green PR Optimization

**Design says:** "Skip expensive operations for green PRs"

**Not specified:**
- How is "green" determined? (ci_status parameter? API call?)
- What exactly is skipped? (check_runs? artifacts? both?)
- What's returned? (empty events? cached data?)
- What if ci_status is stale/wrong?

**Implementation exists but design doesn't fully specify it**

### Missing Design Decisions

#### ❌ Not Addressed: Check Run Pagination Limit

**Question:** Should we limit check runs to 100 for performance?

**Trade-off:**
- Limit to 100: Fast (1 API call, 1.5s)
- Fetch all 462: Slow (5-7 API calls, 7s)
- Risk: Might miss old failures

**Design should specify:** What's the pagination strategy and trade-off decision

#### ❌ Not Addressed: When to Skip GitLab Statuses

**Question:** Should we fetch GitLab CI statuses for every PR?

**Trade-off:**
- Always fetch: Accurate but slow (~1.3s extra)
- Skip if GitHub has no failures: Fast but might miss GitLab-only failures
- Skip always: Fast but incomplete

**Design should specify:** GitLab integration strategy

#### ❌ Not Addressed: Concurrency Strategy

**Questions:**
- Can multiple SSE streams run for same PR simultaneously?
- Should we lock to prevent duplicate expensive work?
- What if user opens 5 tabs to same PR?

**Current:** No locking, duplicate work happens

**Design should specify:** Concurrency behavior and trade-offs

---

## What's Well-Designed ✅

### Good: SSE Protocol Choice

**Rationale documented:** Simple, efficient, auto-reconnect
**Implementation:** Standard SSE with proper headers
**Fallback:** Meta refresh for no-JS browsers

### Good: Progressive Data Strategy

**Concept:** Show cheap data first, expensive data later
**Implementation:** Multiple events in sequence
**User benefit:** Immediate feedback

### Good: Cache Integration

**Concept:** Reuse background refresh work
**Implementation:** Check PR_CACHE before API calls
**User benefit:** Instant response when cache hit

---

## Critical Gaps Summary

### Must Fix in Design:

1. **Specify exact event sequence** - Current mismatch between docs and implementation
2. **Define performance budgets** - What's the time limit for each operation?
3. **Specify cache key strategy** - How should each data type be cached?
4. **Document green PR optimization flow** - Complete flow from detection to skip
5. **Define pagination strategy** - How many check runs to fetch?
6. **Specify error handling** - What happens when things fail?
7. **Address concurrency** - Multiple simultaneous requests for same PR?

### Should Clarify:

8. GitLab CI integration strategy
9. Cache invalidation rules
10. Fallback behavior details
11. Browser compatibility requirements

---

## Assessment

**Overall Design Quality: 6/10**

**Strengths:**
- ✅ Core concept (progressive rendering with SSE) is sound
- ✅ Architecture choice (SSE) is well-justified
- ✅ Caching strategy is good
- ✅ Event-based design allows flexibility

**Critical Weaknesses:**
- ❌ Event schema mismatch between design and implementation
- ❌ Performance budgets not enforced
- ❌ Green PR optimization incompletely specified
- ❌ Cache key strategy not documented
- ❌ Edge cases and errors not addressed
- ❌ Concurrency behavior undefined

**Recommendation:**

This design document needs significant additions to be "implementation-complete." A new Claude instance could not implement this from the design alone because:

1. Event sequence is ambiguous (6 events listed, 5 actually sent)
2. Performance requirements are stated but not enforced mechanisms specified
3. Cache usage is mentioned but keys/strategy not defined
4. Green PR optimization mentioned but flow not documented
5. Error cases not specified

**To make this implementation-complete, need:**
- Exact event schemas
- Complete flow diagrams
- Cache key specifications
- Error handling specifications
- Performance enforcement mechanisms
- Concurrency strategy
- Trade-off decisions documented

---

## Next Steps

1. Align design with actual implementation (fix event list)
2. Add missing specifications (cache keys, error handling, concurrency)
3. Document all optimization strategies completely
4. Specify trade-offs and decision rationale
5. Add performance budget enforcement mechanisms

Only then will this be a true "implementation-complete specification."
