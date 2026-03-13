#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/bells/failure_categorizer'

# Test infrastructure pattern detection
patterns = Bells::FailureCategorizer::INFRASTRUCTURE_PATTERNS

test_cases = [
  {
    log: "##[warning]Failed to download action 'https://api.github.com/repos/actions/checkout/tarball/v2'",
    should_match: true,
    description: "GitHub action download failure"
  },
  {
    log: "##[error]Response status code does not indicate success: 401 (Unauthorized).",
    should_match: true,
    description: "401 Unauthorized error"
  },
  {
    log: "##[error]Response status code does not indicate success: 503 (Service Unavailable).",
    should_match: true,
    description: "503 Service error"
  },
  {
    log: "The self-hosted runner worker-01 lost communication with the server.",
    should_match: true,
    description: "Runner communication failure"
  },
  {
    log: "Error: No space left on device",
    should_match: true,
    description: "Disk space issue"
  },
  {
    log: "Connection timed out after 30 seconds",
    should_match: true,
    description: "Network timeout"
  },
  {
    log: "1 example, 1 failure",
    should_match: false,
    description: "Regular test failure (should NOT match)"
  },
  {
    log: "Rubocop detected 5 offenses",
    should_match: false,
    description: "Lint failure (should NOT match)"
  }
]

puts "Testing Infrastructure Failure Detection Patterns"
puts "=" * 50
puts

all_passed = true
test_cases.each_with_index do |test_case, i|
  matched = patterns.any? { |pattern| test_case[:log].match?(pattern) }

  if matched == test_case[:should_match]
    puts "✓ Test #{i + 1}: #{test_case[:description]}"
  else
    puts "✗ Test #{i + 1}: #{test_case[:description]}"
    puts "  Expected: #{test_case[:should_match] ? 'MATCH' : 'NO MATCH'}"
    puts "  Got: #{matched ? 'MATCH' : 'NO MATCH'}"
    puts "  Log: #{test_case[:log]}"
    all_passed = false
  end
end

puts
puts "=" * 50
if all_passed
  puts "All tests passed! ✓"
  exit 0
else
  puts "Some tests failed! ✗"
  exit 1
end
