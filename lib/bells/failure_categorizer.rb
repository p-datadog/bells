# frozen_string_literal: true

module Bells
  class FailureCategorizer
    # Order matters - more specific patterns first
    CATEGORIES = [
      [:meta, /\Aall-jobs-are-green\z/],
      [:type_check, /steep|typecheck|type.?check|rbs/i],
      [:lint, %r{lint|rubocop|standard/|actionlint|yaml-lint|semgrep|zizmor}i],
      [:security, /codeql|security|semgrep/i],
      [:tests, %r{test|spec|build & test|parametric|end-to-end|junit|batch}i],
      [:build, /\bbuild\b|compile|bundle/i]
    ].freeze

    # Patterns that indicate infrastructure/CI failures (not code issues)
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

      # Git/checkout authentication failures
      /fatal: could not read Username/i,
      /fatal: could not read Password/i,
      /terminal prompts disabled/i,
      /##\[error\].*failed with exit code 128/i, # Git authentication error
      /Authentication failed/i,
      /fatal: Authentication failed for/i,
      /fatal: repository.*not found/i, # Often indicates auth issues

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
      /Disk quota exceeded/i
    ].freeze

    CATEGORY_LABELS = {
      meta: "Meta",
      infrastructure: "Infrastructure",
      type_check: "Type Check",
      lint: "Lint",
      security: "Security",
      tests: "Tests",
      build: "Build",
      uncategorized: "Uncategorized"
    }.freeze

    JobFailure = Struct.new(
      :job_name,
      :job_id,
      :category,
      :url,
      :details,
      keyword_init: true
    )

    def categorize_job(job, github_client: nil)
      name = job.name
      details = nil

      # Check for infrastructure failures first (takes precedence)
      # Infrastructure failures are not code issues, so they should be
      # identified regardless of the job name
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

    def categorize_jobs(jobs, github_client: nil)
      jobs.map { |job| categorize_job(job, github_client: github_client) }
    end

    def group_by_category(job_failures)
      grouped = job_failures.group_by(&:category)

      # Order: tests first (most important), then type/lint, uncategorized, infrastructure, meta last
      result = {}
      [:tests, :type_check, :lint, :security, :build, :uncategorized, :infrastructure, :meta].each do |cat|
        result[cat] = grouped[cat] if grouped[cat]&.any?
      end
      result
    end

    def self.category_label(category)
      CATEGORY_LABELS[category] || category.to_s.titleize
    end

    private

    def detect_category(name)
      CATEGORIES.each do |category, pattern|
        return category if name.match?(pattern)
      end
      :uncategorized
    end

    def check_for_infrastructure_failure(job_id, github_client)
      logs = github_client.job_logs(job_id)
      return { is_infrastructure: false } unless logs

      # Check for infrastructure failure patterns
      INFRASTRUCTURE_PATTERNS.each do |pattern|
        if match = logs.match(pattern)
          # Extract a snippet of context around the match
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
  end
end
