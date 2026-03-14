# Infrastructure Failure Detection

This feature automatically detects and categorizes CI job failures that are caused by infrastructure issues (GitHub Actions, runners, network, etc.) rather than actual code problems.

## How It Works

When analyzing failed jobs, the system:

1. **Fetches job logs** from GitHub Actions for each failed job
2. **Scans logs** for infrastructure failure patterns
3. **Categorizes** jobs as "Infrastructure" if patterns match
4. **Extracts context** from the logs showing the specific error

Infrastructure detection takes **precedence** over name-based categorization. This means even if a job is named "Test XYZ", if it failed due to a 401 Unauthorized error when downloading actions, it will be correctly categorized as an infrastructure failure.

## Detected Infrastructure Failures

### GitHub Actions/API Failures
- Failed to download actions
- 401 Unauthorized errors
- 403 Forbidden errors
- 404 Not Found errors
- 429 Rate limit errors
- 5xx server errors (500, 503, etc.)
- API rate limit exceeded
- Unable to download actions

### Git/Checkout Authentication Failures
- `fatal: could not read Username` - GitHub authentication token issues
- `fatal: could not read Password` - GitHub credential failures
- `terminal prompts disabled` - Non-interactive authentication failures
- Git exit code 128 - General git authentication/permission errors
- `Authentication failed` - Git authentication failures
- `fatal: repository not found` - Often indicates authentication/permission issues

### Runner/VM Failures
- Self-hosted runner lost communication
- Runner unexpectedly terminated
- Missing commands or file processing errors

### Network/Connectivity Issues
- Unable to resolve host
- Connection timed out
- Network is unreachable
- Operation canceled (often indicates timeout)

### MongoDB/Database Service Failures
- MongoDB NoServerAvailable with dead monitor threads
- Database cluster topology unknown with dead monitoring
- Container services failed to initialize properly
- Docker Compose service health checks passed prematurely

**Key Indicator:** "dead monitor threads" - the MongoDB Ruby driver's health monitoring threads died, indicating runner-level threading/resource issues rather than application code problems.

**Common Causes:**
- MongoDB Docker container failed to start properly
- GitHub Actions runner resource constraints (CPU/memory starvation)
- Container health check passed before service was fully ready
- JRuby-specific threading issues on the runner (more common than MRI Ruby)

**Why This Is Infrastructure (Not Code):**
- The pattern requires "dead monitor threads" - application code doesn't cause driver threads to die
- Cluster topology being "Unknown" with "NO-MONITORING" indicates service never initialized
- Timing-dependent failures suggest container orchestration issues
- Same tests pass on other runners or retry attempts

### Resource/Quota Issues
- No space left on device
- Out of memory
- Disk quota exceeded

## Examples

### Example 1: GitHub Actions API Failure

For a job that fails with:
```
##[warning]Failed to download action 'https://api.github.com/repos/DeterminateSystems/nix-installer-action/tarball/...'.
Error: Response status code does not indicate success: 401 (Unauthorized).
```

The system will:
1. Categorize it as **Infrastructure** (not "Tests" based on job name)
2. Extract the relevant error context
3. Display it prominently in the UI with error details

### Example 2: Git Checkout Authentication Failure

For a job that fails during checkout with:
```
2026-03-12T03:07:12Z ##[group]Run actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
2026-03-12T03:07:12Z ##[error]fatal: could not read Username for 'https://github.com': terminal prompts disabled
2026-03-12T03:07:44Z ##[error]The process '/usr/bin/git' failed with exit code 128
```

The system will:
1. Detect the `fatal: could not read Username` pattern
2. Categorize it as **Infrastructure** (GitHub authentication issue)
3. Extract context showing the checkout failure
4. Allow automatic restart since it's not a code issue

### Example 3: MongoDB Service Initialization Failure

For a job that fails with:
```
Failures:

  1) Mongo::Client instrumentation with json_command configured to false behaves like with json_command configured to a failed query behaves like a MongoDB trace behaves like analytics for integration when configured by environment variable and explicitly disabled and global flag is explicitly enabled behaves like sample rate value isn't set
     Got 0 failures and 2 other errors:

     1.1) Failure/Error: before { client[collection].drop }
          Mongo::Error::NoServerAvailable:
            No primary_preferred server is available in cluster: #<Cluster topology=Unknown[mongodb:27017] servers=[#<Server address=mongodb:27017 UNKNOWN NO-MONITORING>]> with timeout=30, LT=0.015. The following servers have dead monitor threads: #<Server address=mongodb:27017 UNKNOWN NO-MONITORING>

     1.2) Failure/Error: client.database.drop if drop_database?
          Mongo::Error::NoServerAvailable:
            No primary_preferred server is available in cluster: #<Cluster topology=Unknown[mongodb:27017] servers=[#<Server address=mongodb:27017 UNKNOWN NO-MONITORING>]> with timeout=30, LT=0.015. The following servers have dead monitor threads: #<Server address=mongodb:27017 UNKNOWN NO-MONITORING>

911 examples, 1 failure, 1 pending
```

**Real Failure:** https://github.com/DataDog/dd-trace-rb/actions/runs/23075327378/job/67034401797

The system will:
1. Detect the **"dead monitor threads"** pattern (key infrastructure indicator)
2. Categorize it as **Infrastructure** (not "Tests" based on job name)
3. Recognize this as a MongoDB Docker container initialization failure
4. Avoid blaming the code when it's a runner/container orchestration issue

**Why This Is Infrastructure:**
- 911 examples passed, only 1 failed (not a systemic code issue)
- "dead monitor threads" indicates MongoDB driver's health monitoring failed
- Cluster topology "Unknown" with "NO-MONITORING" shows service never initialized
- Test expects MongoDB to be available via Docker Compose
- More common on JRuby due to different threading model

**Why Pattern Is Specific:**
- Plain `Mongo::Error::NoServerAvailable` would catch legitimate code failures
- Requiring "dead monitor threads" ensures high specificity (only infrastructure)
- Prevents false positives from application-level connection bugs

## Benefits

- **Distinguish** infrastructure issues from code issues
- **Avoid** wasting time investigating "test failures" that are actually GitHub outages
- **Prioritize** real code issues that need developer attention
- **Track** infrastructure reliability over time

## Performance

- Job logs are fetched **only for failed jobs**
- Logs are analyzed **once per job** during categorization
- Pattern matching is efficient using regex
- Results are **cached** for 5 minutes per PR

## Adding New Patterns

To detect new infrastructure failure patterns, add them to `INFRASTRUCTURE_PATTERNS` in `lib/bells/failure_categorizer.rb`:

```ruby
INFRASTRUCTURE_PATTERNS = [
  /Your new pattern here/i,
  # ... existing patterns
].freeze
```

Patterns should:
- Be specific enough to avoid false positives
- Use case-insensitive matching (`/i` flag)
- Match error messages that clearly indicate infrastructure (not code) issues
