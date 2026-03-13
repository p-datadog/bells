# Implementing Infrastructure Failure Detection

This document provides step-by-step instructions for implementing infrastructure failure detection in a CI analysis system. Use this to replicate the infrastructure detection feature implemented in the bells codebase.

## Overview

Infrastructure failure detection identifies CI job failures caused by GitHub Actions, runners, network, or resource issues rather than code problems. It analyzes job logs to detect specific failure patterns and categorizes jobs accordingly.

## Implementation Steps

### 1. Define Infrastructure Failure Patterns

Add a constant containing regex patterns that match infrastructure failures:

```ruby
# In your FailureCategorizer class
INFRASTRUCTURE_PATTERNS = [
  # GitHub Actions/API failures
  /Failed to download action/i,
  /Response status code does not indicate success.*\(Unauthorized\)/i,
  /Response status code does not indicate success.*401/i,
  /Response status code does not indicate success.*403/i,
  /Response status code does not indicate success.*404/i,
  /Response status code does not indicate success.*429/i, # Rate limit
  /Response status code does not indicate success.*5\d{2}/i, # 5xx errors
  /##\[error\].*Unauthorized/i,
  /##\[error\].*API rate limit/i,
  /##\[error\].*Unable to download actions/i,

  # Runner/VM failures
  /The self-hosted runner.*lost communication/i,
  /runner.*unexpectedly terminated/i,
  /Unable to process file command.*\[missing `\w+` command\]/i,

  # Network/connectivity issues
  /Error: Unable to resolve host/i,
  /Connection timed out/i,
  /Network is unreachable/i,
  /The operation was canceled/i, # Often indicates timeout

  # Resource/quota issues
  /Error: No space left on device/i,
  /Out of memory/i,
  /Disk quota exceeded/i,

  # Git authentication failures
  /fatal: could not read Username/i,
  /terminal prompts disabled/i,
  /Authentication failed/i,
  /fatal:.*exit code 128/i
].freeze
```

### 2. Add Infrastructure Category

Add `:infrastructure` to your category labels and ordering:

```ruby
CATEGORY_LABELS = {
  meta: "Meta",
  infrastructure: "Infrastructure",  # Add this
  type_check: "Type Check",
  lint: "Lint",
  security: "Security",
  tests: "Tests",
  build: "Build",
  uncategorized: "Uncategorized"
}.freeze
```

Update category ordering to prioritize infrastructure (show it early):

```ruby
def group_by_category(job_failures)
  grouped = job_failures.group_by(&:category)

  result = {}
  [:meta, :infrastructure, :type_check, :lint, :security, :tests, :build, :uncategorized].each do |cat|
    result[cat] = grouped[cat] if grouped[cat]&.any?
  end
  result
end
```

### 3. Add Details Field to JobFailure

Modify your JobFailure struct to include a `details` field for error snippets:

```ruby
JobFailure = Struct.new(
  :job_name,
  :job_id,
  :category,
  :url,
  :details,  # Add this field
  keyword_init: true
)
```

### 4. Implement Log Analysis Methods

Add methods to check logs for infrastructure failures:

```ruby
def categorize_job(job, github_client: nil)
  name = job.name
  details = nil

  # Check for infrastructure failures first (takes precedence)
  category = if github_client
    infra_check = check_for_infrastructure_failure(job.id, github_client)
    if infra_check[:is_infrastructure]
      details = infra_check[:details]
      :infrastructure
    else
      detect_category(name)
    end
  else
    detect_category(name)
  end

  JobFailure.new(
    job_name: name,
    job_id: job.id,
    category: category,
    url: job.html_url,
    details: details
  )
end

private

def check_for_infrastructure_failure(job_id, github_client)
  logs = github_client.job_logs(job_id)
  return { is_infrastructure: false } unless logs

  # Check for infrastructure failure patterns
  INFRASTRUCTURE_PATTERNS.each do |pattern|
    if match = logs.match(pattern)
      snippet = extract_error_snippet(logs, match)
      return {
        is_infrastructure: true,
        details: snippet
      }
    end
  end

  { is_infrastructure: false }
rescue => e
  warn "Failed to check infrastructure failure for job #{job_id}: #{e.message}"
  { is_infrastructure: false }
end

def extract_error_snippet(logs, match)
  # Find the line containing the match
  lines = logs.lines
  match_line_index = lines.find_index { |line| line.include?(match[0]) }
  return match[0].strip unless match_line_index

  # Get 2 lines before and after for context
  start_index = [match_line_index - 2, 0].max
  end_index = [match_line_index + 2, lines.size - 1].min

  context_lines = lines[start_index..end_index]
  context_lines.map(&:strip).reject(&:empty?).join("\n")
end
```

### 5. Update Categorization Call Sites

Pass the GitHub client when categorizing jobs:

```ruby
# In your main analysis method
job_failures = categorizer.categorize_jobs(failed_jobs, github_client: client)
```

### 6. Add GitHub Client Method for Job Logs

Ensure your GitHub client can fetch job logs:

```ruby
def job_logs(job_id)
  url = "https://api.github.com/repos/#{REPO}/actions/jobs/#{job_id}/logs"

  conn = Faraday.new do |f|
    f.response :follow_redirects
  end

  response = conn.get(url) do |req|
    req.headers["Authorization"] = "Bearer #{@token}" if @token
    req.headers["Accept"] = "application/vnd.github+json"
  end

  response.success? ? response.body : nil
rescue
  nil
end
```

### 7. Display Infrastructure Failure Details in UI

If using a web UI, show the error details:

```erb
<% failures.each do |failure| %>
<tr>
  <td>
    <%= failure.job_name %>
    <% if failure.details %>
      <details style="margin-top: 8px;">
        <summary style="cursor: pointer; color: #333; font-size: 0.9em;">Show error details</summary>
        <pre style="margin-top: 8px; padding: 8px; background: #f5f5f5; border-radius: 4px; overflow-x: auto; font-size: 0.85em; color: #000;"><%= failure.details %></pre>
      </details>
    <% end %>
  </td>
  <td><a href="<%= failure.url %>" target="_blank">View Logs</a></td>
</tr>
<% end %>
```

## Testing

Add comprehensive tests for infrastructure detection:

```ruby
context "infrastructure failure detection" do
  it "detects 'Failed to download action' as infrastructure failure"
  it "detects 401 Unauthorized as infrastructure failure"
  it "detects 5xx server errors as infrastructure failure"
  it "detects runner communication loss as infrastructure failure"
  it "detects connection timeouts as infrastructure failure"
  it "detects out of disk space as infrastructure failure"
  it "does not categorize test failures as infrastructure"
  it "falls back to job name categorization when log fetching fails"
  it "extracts context around the error"
end
```

## Key Design Decisions

1. **Log analysis takes precedence** - Infrastructure detection happens before name-based categorization, so even a job named "Test XYZ" will be categorized as infrastructure if logs show infrastructure failures.

2. **Error context extraction** - Extract 2 lines before and after the matched error for better debugging context.

3. **Graceful degradation** - If log fetching fails, fall back to name-based categorization.

4. **Performance** - Logs are fetched only for failed jobs, and only once per job during categorization.

5. **Pattern specificity** - Patterns should be specific enough to avoid false positives but general enough to catch variations.

## Extending the Pattern List

To add new infrastructure failure patterns:

1. Identify the error message from job logs
2. Create a regex that matches the error (use `/i` for case-insensitive)
3. Add to `INFRASTRUCTURE_PATTERNS` with a descriptive comment
4. Add a corresponding test case
5. Test on real PRs to verify accuracy

## Integration Points

Infrastructure failure detection integrates with:
- **Job categorization** - Primary categorization logic
- **Log fetching** - Requires GitHub Actions API access
- **UI display** - Shows error details to users
- **Restart automation** - Can trigger automatic restarts for infrastructure failures
