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
