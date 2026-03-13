# Instructions: Update pr-fix-tests Skill for Infrastructure Failures

This document provides instructions for a new Claude instance to update the `pr-fix-tests` skill (or similar CI failure fixing skills) to automatically restart jobs that failed due to infrastructure issues.

## Background

The bells repository has implemented infrastructure failure detection that identifies CI job failures caused by GitHub Actions, runners, network, or resource issues rather than code problems. This detection analyzes job logs using pattern matching.

The `pr-fix-tests` skill should be updated to:
1. Detect when failures are infrastructure-related (not code issues)
2. Automatically restart infrastructure failures
3. Only attempt to fix actual code failures (tests, lint, etc.)

## Current Skill Behavior

The existing skill likely:
- Analyzes failed CI jobs in a PR
- Attempts to fix test failures by modifying code
- May restart jobs manually or require user confirmation

## Required Updates

### 1. Add Infrastructure Failure Detection

The skill needs to identify infrastructure failures using one of these approaches:

**Option A: Use the bells API endpoint**
If the skill has access to the bells web service:

```ruby
# Fetch PR analysis from bells
response = HTTP.get("http://localhost:9292/api/pr/#{pr_number}")
result = JSON.parse(response.body, symbolize_names: true)

# Check for infrastructure failures
if result[:categorized_failures][:infrastructure]
  infrastructure_jobs = result[:categorized_failures][:infrastructure]
  # Handle infrastructure failures (see step 2)
end
```

**Option B: Implement detection directly**
If the skill needs to detect infrastructure failures independently, use the implementation guide at `docs/implementing-infrastructure-failure-detection.md` to add detection logic to the skill.

### 2. Restart Infrastructure Failures Automatically

When infrastructure failures are detected, restart them without attempting to fix code:

```ruby
infrastructure_jobs = result[:categorized_failures][:infrastructure]

if infrastructure_jobs&.any?
  puts "Found #{infrastructure_jobs.size} infrastructure failure(s):"
  infrastructure_jobs.each do |job|
    puts "  - #{job[:job_name]}"
    if job[:details]
      puts "    Error: #{job[:details].lines.first&.strip}"
    end
  end

  # Restart all infrastructure failures
  restart_count = 0
  infrastructure_jobs.each do |job|
    begin
      github_client.restart_job(job[:job_id])
      restart_count += 1
      puts "  ✓ Restarted: #{job[:job_name]}"
    rescue => e
      puts "  ✗ Failed to restart #{job[:job_name]}: #{e.message}"
    end
  end

  puts "\nRestarted #{restart_count}/#{infrastructure_jobs.size} infrastructure job(s)."
  puts "These failures are not code issues and may resolve on retry."
end
```

### 3. Update Skill Logic Flow

Modify the skill's main logic:

```ruby
def fix_pr_tests(pr_number)
  # Analyze PR failures
  result = analyze_pr(pr_number)

  # Separate infrastructure from code failures
  infrastructure_failures = result[:categorized_failures][:infrastructure] || []
  code_failures = result[:categorized_failures].reject { |k, _| k == :infrastructure }

  # Handle infrastructure failures first
  if infrastructure_failures.any?
    puts "\n=== Infrastructure Failures ==="
    restart_infrastructure_failures(infrastructure_failures)
  end

  # Only attempt to fix code failures
  if code_failures.any?
    puts "\n=== Code Failures ==="
    code_failures.each do |category, failures|
      case category
      when :tests
        fix_test_failures(failures)
      when :lint
        fix_lint_failures(failures)
      when :type_check
        fix_type_check_failures(failures)
      # ... other categories
      end
    end
  else
    puts "\nNo code failures to fix. All failures are infrastructure-related."
  end

  # Summary
  puts "\n=== Summary ==="
  puts "Infrastructure failures restarted: #{infrastructure_failures.size}"
  puts "Code failures fixed: #{count_fixed_failures(code_failures)}"
end
```

### 4. Add User Messaging

Clearly communicate to users when failures are infrastructure-related:

```ruby
if infrastructure_failures.any? && code_failures.empty?
  puts <<~MSG

    ✓ All #{infrastructure_failures.size} failure(s) are infrastructure-related.

    These are not code issues:
    - GitHub Actions API errors (401, 5xx)
    - Runner communication failures
    - Network timeouts
    - Resource constraints (disk space, memory)

    Jobs have been automatically restarted and may pass on retry.
    No code changes are needed.
  MSG
end
```

### 5. Handle Mixed Failures

When both infrastructure and code failures exist:

```ruby
if infrastructure_failures.any? && code_failures.any?
  puts <<~MSG

    Note: Found both infrastructure and code failures.

    Infrastructure failures (#{infrastructure_failures.size}): Automatically restarted
    Code failures (#{code_failures.values.sum(&:size)}): Attempting to fix below

    Infrastructure failures may resolve after restart, but code failures
    require fixes.
  MSG
end
```

## Testing the Updated Skill

Test with these scenarios:

1. **Only infrastructure failures**: Verify jobs are restarted, no code changes attempted
2. **Only code failures**: Verify normal fix behavior, no restarts
3. **Mixed failures**: Verify infrastructure jobs restarted AND code fixes attempted
4. **No infrastructure patterns**: Verify skill doesn't misidentify code failures

## Example Test Cases

Use these PRs for testing (if they exist in dd-trace-rb):
- Pure infrastructure failure: Find a PR with 401 Unauthorized or runner failures
- Pure code failure: Find a PR with test or lint failures
- Mixed: Find a PR with both types

## Integration Points

The updated skill should:
- Use the same `INFRASTRUCTURE_PATTERNS` as bells (import or duplicate)
- Share infrastructure detection logic if possible (DRY principle)
- Coordinate with bells API if available
- Log all restart attempts for debugging

## Additional Considerations

1. **Rate limiting**: GitHub has rate limits for job restarts (consider adding delays)
2. **Retry limits**: Don't restart the same job multiple times in a short period
3. **Meta-check handling**: If the `all-jobs-are-green` meta-check also failed, restart it after infrastructure jobs
4. **User confirmation**: Consider asking before restarting (unless auto-restart is enabled)

## Files to Modify

Likely locations in the skill repository:
- Main skill entry point (where PR analysis happens)
- GitHub client wrapper (to add job restart capability)
- Test files (to add infrastructure failure test cases)

## Reference Implementation

See bells repository:
- `lib/bells/failure_categorizer.rb` - Infrastructure detection logic
- `lib/bells/github_client.rb` - Job restart method
- `docs/implementing-infrastructure-failure-detection.md` - Full implementation guide
- `docs/INFRASTRUCTURE_DETECTION.md` - Feature documentation
