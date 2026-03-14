# PR Detail Page Performance Analysis

**URL:** `http://localhost:9292/pr/5448`

## Executive Summary

The PR detail page makes **MANY redundant API calls** and has **NO caching** for the analyze_pr operation. First-time load is extremely slow due to artifact downloads.

**Critical Issues:**
1. ❌ `pull_request()` called **3 times** per page load (no caching, no ETags)
2. ❌ `check_runs` fetched **2 times** with full pagination (200+ items × 2-4 pages each)
3. ❌ `job_logs()` called for **EVERY failed job** (slow text downloads)
4. ❌ `download_junit_artifacts()` downloads **large binary files** (multi-MB zips)
5. ✅ File cache exists but invalidates on every new commit

## API Call Breakdown

### Request Flow for `/pr/5448`

```
app.rb GET /pr/:number
│
├─ 1. client.pull_request(5448)                    [API CALL #1] ❌ No cache
│   └─ GET /repos/DataDog/dd-trace-rb/pulls/5448
│
├─ 2. client.ci_status(pr.head.sha)                [API CALLS #2-3] ✅ ETags enabled
│   ├─ GET /repos/.../commits/{sha}/check-runs?per_page=100&page=1  (with ETag)
│   └─ GET /repos/.../commits/{sha}/check-runs?per_page=100&page=2  (auto_paginate)
│
└─ 3. Bells.analyze_pr(5448)
    │
    ├─ load_cached_analysis()
    │   └─ client.pull_request(5448)              [API CALL #4] ❌ DUPLICATE!
    │       └─ GET /repos/DataDog/dd-trace-rb/pulls/5448
    │
    ├─ [CACHE MISS - expired or SHA changed]
    │
    ├─ client.failed_jobs_for_pr(5448)
    │   ├─ client.pull_request(5448)              [API CALL #5] ❌ DUPLICATE!
    │   │   └─ GET /repos/DataDog/dd-trace-rb/pulls/5448
    │   │
    │   └─ check_runs_for_ref() with auto_paginate [API CALLS #6-9] ❌ DUPLICATE!
    │       ├─ GET /repos/.../commits/{sha}/check-runs?per_page=100&page=1
    │       ├─ GET /repos/.../commits/{sha}/check-runs?per_page=100&page=2
    │       ├─ GET /repos/.../commits/{sha}/check-runs?per_page=100&page=3
    │       └─ GET /repos/.../commits/{sha}/check-runs?per_page=100&page=4
    │
    ├─ client.in_progress_jobs_for_pr(5448)       [API CALLS #10-13] ❌ DUPLICATE!
    │   ├─ client.pull_request(5448)              [API CALL #10] ❌ 4th time!
    │   │   └─ GET /repos/DataDog/dd-trace-rb/pulls/5448
    │   │
    │   └─ check_runs_for_ref() with auto_paginate [API CALLS #11-14] ❌ Fetching same data!
    │       ├─ GET /repos/.../commits/{sha}/check-runs?per_page=100&page=1
    │       ├─ GET /repos/.../commits/{sha}/check-runs?per_page=100&page=2
    │       ├─ GET /repos/.../commits/{sha}/check-runs?per_page=100&page=3
    │       └─ GET /repos/.../commits/{sha}/check-runs?per_page=100&page=4
    │
    ├─ categorizer.categorize_jobs(failed_jobs)
    │   └─ For EACH failed job (e.g., 5 jobs):
    │       └─ client.job_logs(job_id)            [API CALLS #15-19] ⚠️ Slow text downloads
    │           └─ GET /repos/.../actions/jobs/{id}/logs (redirects, downloads full log)
    │
    ├─ client.download_junit_artifacts(5448)      [API CALLS #20+] ⚠️ VERY EXPENSIVE
    │   ├─ client.failed_runs(5448)
    │   │   ├─ workflow_runs_for_pr(5448)
    │   │   │   ├─ client.pull_request(5448)      [API CALL #20] ❌ 5th time!
    │   │   │   │   └─ GET /repos/DataDog/dd-trace-rb/pulls/5448
    │   │   │   │
    │   │   │   └─ GET /repos/.../actions/runs?branch={branch}
    │   │   │
    │   │   └─ Filter to failed runs
    │   │
    │   └─ For EACH failed run (e.g., 2 runs):
    │       ├─ GET /repos/.../actions/runs/{id}/artifacts (with auto_paginate)
    │       │
    │       └─ For EACH junit artifact (e.g., 8 artifacts per run = 16 total):
    │           ├─ Check if cached on disk (artifact_path exists?)
    │           │   └─ If exists: SKIP (good!)
    │           │
    │           └─ If not cached:
    │               └─ GET /repos/.../actions/artifacts/{id}/zip
    │                   ├─ Downloads multi-MB zip file
    │                   ├─ Extracts XML files
    │                   └─ Saves to .cache/{pr_number}/
    │
    ├─ Parse JUnit XML (CPU intensive, but fast)
    │
    └─ save_cached_analysis()
        └─ client.pull_request(5448)              [API CALL #21+] ❌ 6th time!
            └─ GET /repos/DataDog/dd-trace-rb/pulls/5448
```

## API Call Summary

### Minimum API Calls (if all caches hit)
- 1× `pull_request()` - PR details
- 2-4× `check_runs_for_ref()` - CI status (paginated)
- **Total: 3-5 API calls** ✅ Fast (~500ms)

### Actual API Calls (cache miss)
- **6×** `pull_request(5448)` - ❌ Same PR fetched 6 times!
- **8-16×** `check_runs_for_ref()` - ❌ Check runs fetched twice (2 methods × 2-4 pages each)
- **5-20×** `job_logs()` - ⚠️ One per failed job
- **1×** `workflow_runs()` - Workflow runs list
- **2-4×** `workflow_run_artifacts()` - Artifact list per failed run
- **8-50×** `artifact zip downloads` - ⚠️ Large binary downloads (only if not cached on disk)

**Total: 30-97 API calls** ❌ Extremely slow (10-30 seconds)

## Why Is This Taking So Long?

### 1. Redundant API Calls (Latency × Volume)

**pull_request() called 6 times:**
- app.rb line 66: Fetch PR details for display
- bells.rb line 108: Validate cache (load_cached_analysis)
- github_client.rb line 118: failed_jobs_for_pr needs SHA
- github_client.rb line 124: in_progress_jobs_for_pr needs SHA
- github_client.rb line 106: workflow_runs_for_pr needs SHA
- bells.rb line 141: Save cache with PR SHA

**Each call = ~200ms latency → 1200ms total just for PR details!**

**check_runs fetched twice:**
- Once for failed jobs (lines 28)
- Again for in-progress jobs (line 29)
- Each fetch = 2-4 paginated requests × ~200ms = 400-800ms
- **Total: 800-1600ms for duplicate data!**

### 2. Job Logs Downloads (Sequential)

For each failed job, download full log file:
- HTTP redirect (GitHub CDN)
- Download entire log (can be 1-10MB)
- Parse for infrastructure patterns

**5 failed jobs × 500ms each = 2500ms**

### 3. Artifact Downloads (Parallel but Large)

First time visiting a PR:
- Downloads ALL JUnit artifacts from failed runs
- Typically 8-16 artifacts × 2-5MB each = 16-80MB total
- Parallel threads help but network I/O still dominates

**Estimated: 5-15 seconds for artifact downloads**

Subsequent visits:
- Artifacts cached on disk
- Skip downloads (fast!)

### 4. No Request-Level Caching

Current caching:
- ✅ File cache for analysis results (5 min TTL)
- ✅ Disk cache for artifacts (permanent)
- ✅ ETags for ci_status() check runs
- ❌ **NO caching for pull_request() calls**
- ❌ **NO caching for job_logs()**
- ❌ **NO request-scoped check_runs caching**

File cache invalidates on:
- PR head SHA change (every new commit)
- 5 minute expiration

## Current Caching Implementation

### ✅ What IS Cached

1. **ETag Cache (NEW - just implemented)**
   - Location: `GitHubClient::ETAG_CACHE` (in-memory)
   - Cached: `ci_status()` check runs (first page)
   - TTL: None (ETag-based validation)
   - Benefit: Saves 2-4 API calls if CI unchanged

2. **File Cache**
   - Location: `.cache/{pr_number}/analysis.json`
   - Cached: Full analysis results
   - TTL: 5 minutes
   - Invalidation: PR head SHA change
   - Benefit: Entire page instant on cache hit

3. **Artifact Cache**
   - Location: `.cache/{pr_number}/{run_id}_{artifact_name}/`
   - Cached: Downloaded + extracted JUnit XML files
   - TTL: Permanent (immutable)
   - Benefit: Never re-download same artifact

### ❌ What is NOT Cached

1. **pull_request() calls** - No caching at all
   - Called 6 times per request
   - ~200ms each = 1200ms wasted

2. **check_runs** for failed/in-progress jobs
   - Fetched twice with full pagination
   - Not cached between the two calls
   - ~800-1600ms wasted

3. **job_logs()** - No caching
   - Downloaded every time
   - Can be large (1-10MB)
   - ~500ms per job

## Recommendations

### High Impact (Quick Wins)

1. **Cache PR object in request scope**
   ```ruby
   # In app.rb
   get "/pr/:number" do
     @pr_number = params[:number].to_i
     client = Bells::GitHubClient.new
     @pr = client.pull_request(@pr_number)  # Fetch once
     @ci_status = client.ci_status(@pr.head.sha)
     @results = Bells.analyze_pr(@pr_number, pr: @pr)  # Pass PR object
   end

   # In bells.rb
   def analyze_pr(pr_number, cache_dir: ".cache", pr: nil)
     pr ||= client.pull_request(pr_number)  # Only fetch if not provided
     # ...
   end
   ```
   **Savings: 1000ms (5 redundant API calls eliminated)**

2. **Fetch check_runs once, filter twice**
   ```ruby
   # In bells.rb
   def analyze_pr(pr_number, cache_dir: ".cache", pr: nil)
     pr ||= client.pull_request(pr_number)
     all_check_runs = client.check_runs_for_pr(pr.head.sha)  # Fetch once
     failed_jobs = all_check_runs.select { |r| r.conclusion == "failure" }
     in_progress_jobs = all_check_runs.select { |r| r.status != "completed" }
     # ...
   end
   ```
   **Savings: 800-1600ms (4-8 redundant paginated API calls eliminated)**

3. **Add ETag support to pull_request()**
   ```ruby
   def pull_request(pr_number)
     fetch_with_etag("pull:#{pr_number}") do |cached_etag|
       # ... similar to pull_requests() implementation
     end
   end
   ```
   **Savings: 0-1200ms (depends on how often PR changes)**

4. **Cache job logs in file cache**
   ```ruby
   def job_logs(job_id, cache_dir: ".cache")
     cache_path = File.join(cache_dir, "logs", "#{job_id}.log")
     return File.read(cache_path) if File.exist?(cache_path)

     logs = fetch_job_logs(job_id)
     FileUtils.mkdir_p(File.dirname(cache_path))
     File.write(cache_path, logs) if logs
     logs
   end
   ```
   **Savings: 500-5000ms (depends on number of failed jobs)**

### Medium Impact

5. **Use PR_CACHE for pull_request() calls**
   - Same in-memory cache used for homepage
   - TTL: 2 minutes (same as background refresher)

6. **Combine failed_runs and workflow_runs_for_pr queries**
   - Both fetch workflow runs
   - Cache workflow runs by PR number

### Low Impact (Micro-optimizations)

7. **Parallel job log downloads**
   - Already have parallel artifact downloads
   - Apply same pattern to job logs

8. **Background warm cache**
   - Pre-fetch analysis for all open PRs
   - Refresh on interval

## Performance Targets

### Current Performance
- **First visit (cold cache):** 10-30 seconds
- **Cached visit (same SHA):** 50-200ms (instant)
- **After new commit:** 10-30 seconds (cache invalidated)

### After Quick Wins (#1-4)
- **First visit (cold cache):** 3-8 seconds (70% improvement)
  - Eliminated: 6-13 redundant API calls (2-3 seconds)
  - Eliminated: 5 redundant log downloads (2-5 seconds)
- **Cached visit:** 50-200ms (unchanged)
- **After new commit (PR changed):** 3-8 seconds
- **After new commit (PR unchanged):** 200-500ms (ETag cache hit)

### Ideal Performance (All optimizations)
- **First visit (cold cache):** 2-5 seconds
- **Cached visit:** <100ms
- **After new commit:** 200-500ms (ETags save most calls)

## Next Steps

1. ✅ Implement ETag caching (DONE)
2. ⏭️ **Eliminate redundant pull_request() calls** (High impact, easy)
3. ⏭️ **Deduplicate check_runs fetching** (High impact, easy)
4. ⏭️ **Add file cache for job logs** (High impact, medium effort)
5. ⏭️ **Add ETag support to pull_request()** (Medium impact, easy)

## Conclusion

The PR detail page is slow because:
1. ❌ **6 redundant pull_request() API calls** → 1200ms wasted
2. ❌ **8-16 redundant check_runs API calls** → 1600ms wasted
3. ❌ **No caching for job logs** → 2500ms wasted
4. ⚠️ **Artifact downloads** → 5-15 seconds (but cached on disk)

**Total waste: 5-20 seconds per request**

The file cache helps but invalidates on every commit. ETag caching (just implemented) helps with ci_status but doesn't cover pull_request() or the redundant check_runs calls in analyze_pr.

**Immediate action:** Implement recommendations #1-4 to reduce load time by 70%.
