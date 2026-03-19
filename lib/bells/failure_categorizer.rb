# frozen_string_literal: true

module Bells
  class FailureCategorizer
    # Order matters - more specific patterns first
    CATEGORIES = [
      [:meta, /\Aall-jobs-are-green\z|\Add-gitlab\/default-pipeline\z/],
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

      # MongoDB/Database service failures (container initialization issues)
      /Mongo::Error::NoServerAvailable.*dead monitor threads/m,
      /No \w+ server is available in cluster.*topology=Unknown.*UNKNOWN NO-MONITORING/m,

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
      other: "Other"
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

    # Categorize commit statuses (GitLab CI)
    # When gitlab_client is provided, fetches job logs for infrastructure detection
    def categorize_status(status, gitlab_client: nil)
      name = status.context
      details = nil

      category = if gitlab_client&.available?
        parsed = GitLabClient.parse_target_url(status.target_url)
        if parsed && parsed[:type] == :build
          infra_check = check_for_gitlab_infrastructure_failure(parsed[:project_path], parsed[:id], gitlab_client)
          if infra_check[:is_infrastructure]
            details = infra_check[:details]
            :infrastructure
          else
            detect_category(name)
          end
        else
          detect_category(name)
        end
      else
        detect_category(name)
      end

      JobFailure.new(
        job_name: name,
        job_id: nil,
        category: category,
        url: status.target_url,
        details: details || status.description
      )
    end

    def categorize_statuses(statuses, gitlab_client: nil)
      statuses.map { |status| categorize_status(status, gitlab_client: gitlab_client) }
    end

    def group_by_category(job_failures)
      grouped = job_failures.group_by(&:category)

      # Order: tests first (most important), then type/lint, other, infrastructure, meta last
      result = {}
      [:tests, :type_check, :lint, :security, :build, :other, :infrastructure, :meta].each do |cat|
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
      :other
    end

    def check_for_gitlab_infrastructure_failure(project_path, job_id, gitlab_client)
      logs = gitlab_client.job_log(project_path, job_id)
      return { is_infrastructure: false } unless logs

      check_logs_for_infrastructure_failure(logs)
    rescue => e
      warn "Failed to check GitLab infrastructure failure for job #{job_id}: #{e.class}: #{e}"
      { is_infrastructure: false }
    end

    def check_for_infrastructure_failure(job_id, github_client)
      logs = github_client.job_logs(job_id)
      return { is_infrastructure: false } unless logs

      check_logs_for_infrastructure_failure(logs)
    rescue => e
      warn "Failed to check infrastructure failure for job #{job_id}: #{e.class}: #{e}"
      { is_infrastructure: false }
    end

    def check_logs_for_infrastructure_failure(logs)
      INFRASTRUCTURE_PATTERNS.each do |pattern|
        if (match = logs.match(pattern))
          snippet = extract_error_snippet(logs, match)
          return { is_infrastructure: true, details: snippet }
        end
      end

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
