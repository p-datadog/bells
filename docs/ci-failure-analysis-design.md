# CI Failure Analysis - Implementation Specification

## Overview

Web application to analyze CI failures in DataDog/dd-trace-rb pull requests. Groups failures by category (lint, type check, tests, etc.) and provides detailed test failure analysis from JUnit XML artifacts.

## Tech Stack

- **Language**: Ruby
- **Web Framework**: Sinatra
- **GitHub API**: Octokit gem
- **XML Parsing**: Nokogiri
- **HTTP Client**: Faraday with follow_redirects
- **Zip Extraction**: rubyzip
- **Testing**: RSpec, VCR, WebMock, Rack::Test

## Dependencies (Gemfile)

```ruby
source "https://rubygems.org"

gem "sinatra"
gem "puma"
gem "nokogiri"
gem "octokit"
gem "faraday-retry"
gem "faraday-follow_redirects"
gem "rubyzip"

group :development, :test do
  gem "rspec"
  gem "rack-test"
  gem "vcr"
  gem "webmock"
  gem "rerun"
end
```

## File Structure

```
bells/
├── app.rb                    # Sinatra routes
├── config.ru                 # Rack config
├── Gemfile
├── lib/
│   ├── bells.rb              # Main module, analyze_pr entry point
│   └── bells/
│       ├── github_client.rb  # GitHub API integration
│       ├── junit_parser.rb   # JUnit XML parsing
│       ├── failure_aggregator.rb  # Group test failures
│       └── failure_categorizer.rb # Categorize jobs by type
├── views/
│   ├── layout.erb            # Base HTML template with CSS
│   ├── index.erb             # Home page with PR list
│   └── pr_analysis.erb       # PR failure analysis page
├── spec/
│   ├── spec_helper.rb
│   ├── lib/
│   │   ├── github_client_spec.rb
│   │   ├── junit_parser_spec.rb
│   │   ├── failure_aggregator_spec.rb
│   │   └── failure_categorizer_spec.rb
│   ├── routes/
│   │   └── pr_analysis_spec.rb
│   └── fixtures/
│       ├── cassettes/        # VCR recordings
│       └── junit_samples/    # Sample XML files
├── .cache/                   # Artifact cache (gitignored)
└── docs/
```

## Components

### 1. GitHubClient (`lib/bells/github_client.rb`)

```ruby
module Bells
  class GitHubClient
    REPO = "DataDog/dd-trace-rb"

    def initialize(token: nil)
      # Token priority: param > ENV["GITHUB_TOKEN"] > `gh auth token`
      @token = token || ENV["GITHUB_TOKEN"] || `gh auth token 2>/dev/null`.strip
      @token = nil if @token.empty?
      @client = Octokit::Client.new(access_token: @token)
      @client.auto_paginate = false
    end

    # Fetch open PRs
    def pull_requests(state: "open", per_page: 30)

    # Get CI status for a commit SHA
    # Returns: :green, :pending_clean, :pending_failing, :failed, :unknown
    def ci_status(sha)
      # Use @client.check_runs_for_ref(REPO, sha)
      # Check conclusions and statuses to determine overall state

    # Get workflow runs for PR's head SHA
    def workflow_runs_for_pr(pr_number)
      # Get PR to find head.sha and head.ref
      # Query repository_workflow_runs filtered by branch

    # Get only failed workflow runs
    def failed_runs(pr_number)

    # Get all failed check runs/jobs for a PR
    def failed_jobs_for_pr(pr_number)
      # Use check_runs_for_ref, filter by conclusion == "failure"

    # Download JUnit artifacts from failed runs
    def download_junit_artifacts(pr_number, cache_dir:)
      # For each failed run, get artifacts matching /junit|test-results/i
      # Download via API: GET /repos/{owner}/{repo}/actions/artifacts/{id}/zip
      # Use Faraday with follow_redirects (GitHub returns 302)
      # Extract zip to .cache/{pr_number}/{run_id}_{artifact_name}/
  end
end
```

### 2. JunitParser (`lib/bells/junit_parser.rb`)

```ruby
module Bells
  class JunitParser
    # Structs for parsed data
    TestFailure = Struct.new(
      :test_class,      # From testcase[@classname]
      :test_name,       # From testcase[@name]
      :failure_message, # From failure[@message] or error[@message]
      :stack_trace,     # From failure/error text content
      :execution_time,  # From testcase[@time]
      :build_context,   # BuildContext struct
      keyword_init: true
    )

    BuildContext = Struct.new(
      :workflow_name, :job_name, :run_id, :attempt, :file_path,
      keyword_init: true
    )

    def parse_file(path, build_context: nil)
    def parse_string(xml, build_context: nil)
    def parse_directory(dir_path, build_context: nil)
      # Glob for **/*.xml, parse each

    private

    def parse_document(doc, build_context:)
      # XPath: //testcase[failure or error]
      # Extract failure/error node, build TestFailure struct
  end
end
```

### 3. FailureAggregator (`lib/bells/failure_aggregator.rb`)

```ruby
module Bells
  class FailureAggregator
    AggregatedFailure = Struct.new(
      :test_class,
      :test_name,
      :failure_count,
      :instances,  # Array of TestFailure
      keyword_init: true
    ) do
      def test_id
        "#{test_class}##{test_name}"
      end

      def flaky?
        failure_count > 1  # Same test failed in multiple jobs
      end
    end

    def aggregate(failures)
      # Group by [test_class, test_name]
      # Sort by failure_count descending, then by test_id

    def summary(failures)
      # Returns hash with:
      # - total_failures: count of all failure instances
      # - unique_tests: count of unique test identities
      # - flaky_tests: count where failure_count > 1
      # - aggregated: array of AggregatedFailure
  end
end
```

### 4. FailureCategorizer (`lib/bells/failure_categorizer.rb`)

```ruby
module Bells
  class FailureCategorizer
    # Pattern matching for job names (order matters - specific first)
    CATEGORIES = [
      [:type_check, /steep|typecheck|type.?check|rbs/i],
      [:lint, %r{lint|rubocop|standard/|actionlint|yaml-lint|semgrep|zizmor}i],
      [:security, /codeql|security|semgrep/i],
      [:tests, %r{test|spec|build & test|parametric|end-to-end|junit}i],
      [:build, /\bbuild\b|compile|bundle/i]
    ]

    CATEGORY_LABELS = {
      type_check: "Type Check",
      lint: "Lint",
      security: "Security",
      tests: "Tests",
      build: "Build",
      uncategorized: "Uncategorized"
    }

    JobFailure = Struct.new(
      :job_name, :job_id, :category, :url, :details,
      keyword_init: true
    )

    def categorize_job(job)
      # Match job.name against patterns, return JobFailure

    def categorize_jobs(jobs)
    def group_by_category(job_failures)
      # Return hash ordered by: type_check, lint, security, tests, build, uncategorized

    def self.category_label(category)
  end
end
```

### 5. Main Module (`lib/bells.rb`)

```ruby
module Bells
  class << self
    def analyze_pr(pr_number, cache_dir: ".cache")
      client = GitHubClient.new
      parser = JunitParser.new
      aggregator = FailureAggregator.new
      categorizer = FailureCategorizer.new

      # Get all failed jobs and categorize
      failed_jobs = client.failed_jobs_for_pr(pr_number)
      job_failures = categorizer.categorize_jobs(failed_jobs)
      categorized = categorizer.group_by_category(job_failures)

      # Get detailed test failures from JUnit
      artifact_dirs = client.download_junit_artifacts(pr_number, cache_dir: cache_dir)
      test_failures = artifact_dirs.flat_map { |dir| parser.parse_directory(dir) if dir }.compact
      test_summary = aggregator.summary(test_failures)

      {
        categorized_failures: categorized,
        test_details: test_summary,
        total_failed_jobs: failed_jobs.size
      }
    end
  end
end
```

## Routes (`app.rb`)

```ruby
get "/" do
  # Fetch PRs, extract authors for filter links
  # Check BELLS_DEFAULT_AUTHOR env var
  # Apply default filter unless show_all=true or author param set
  # Get CI status for each PR
  # @pull_requests, @authors, @author_filter, @default_author, @ci_status
  erb :index
end

get "/pr/:number" do
  @pr_number = params[:number].to_i
  # Fetch PR details for title and CI status
  @results = Bells.analyze_pr(@pr_number)
  erb :pr_analysis
end

get "/api/pr/:number" do
  # JSON response with categorized_failures, test_details, total_failed_jobs
end
```

## Views

### Layout (`views/layout.erb`)
- System font stack
- Card-based layout with shadows
- Table styling with hover states
- CI status badges (green/yellow/red colors)
- Expandable detail rows (click to toggle)
- Filter pills for author selection
- Search input for filtering test failures

### Index (`views/index.erb`)
- PR number input form
- Author filter pills (with "All PRs" link when default author is set)
- Default author marked with "(default)" label
- PR table: #, Title, Author, CI Status, Updated, Analyze link

### PR Analysis (`views/pr_analysis.erb`)
- Summary stats: Failed Jobs, Failed Tests, Flaky Tests
- Category sections (Type Check, Lint, etc.) with job tables
- Test failure details table with expandable rows showing:
  - Test class and name
  - Failure count
  - Flaky badge if count > 1
  - Expandable: failure message, stack trace, build context

## CI Status Logic

```ruby
def ci_status(sha)
  check_runs = @client.check_runs_for_ref(REPO, sha)[:check_runs]
  return :unknown if check_runs.empty?

  conclusions = check_runs.map(&:conclusion)
  statuses = check_runs.map(&:status)

  has_failures = conclusions.include?("failure")
  all_complete = statuses.all? { |s| s == "completed" }

  if all_complete
    has_failures ? :failed : :green
  else
    has_failures ? :pending_failing : :pending_clean
  end
end
```

## Testing Strategy

### Unit Tests (no mocking)
- JunitParser: parse various XML formats, extract failures
- FailureAggregator: grouping, counting, flaky detection
- FailureCategorizer: pattern matching for all job types

### Integration Tests (VCR)
- GitHubClient: record real API responses, replay in tests
- Filter tokens from cassettes

### Route Tests (Rack::Test)
- Mock Bells module to return controlled data
- Verify response status and content

### spec_helper.rb
```ruby
ENV["RACK_ENV"] = "test"

VCR.configure do |config|
  config.cassette_library_dir = "spec/fixtures/cassettes"
  config.hook_into :webmock
  config.filter_sensitive_data("<GITHUB_TOKEN>") { ENV["GITHUB_TOKEN"] }
  config.filter_sensitive_data("<GITHUB_TOKEN>") { `gh auth token 2>/dev/null`.strip }
  config.configure_rspec_metadata!
end
```

## Configuration

### .gitignore
```
Gemfile.lock
.cache/
.env
coverage/
```

### Environment
- `GITHUB_TOKEN`: Optional, falls back to `gh auth token`
- `BELLS_DEFAULT_AUTHOR`: Optional, filters PRs by author on homepage by default

## Usage

```bash
# Install
bundle install

# Development (auto-reload)
bundle exec rerun -- puma

# Production
bundle exec puma

# Test
bundle exec rspec

# Visit http://localhost:9292
```
