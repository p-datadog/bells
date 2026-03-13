# frozen_string_literal: true

module Bells
  class FailureCategorizer
    # Order matters - more specific patterns first
    CATEGORIES = [
      [:meta, /\Aall-jobs-are-green\z/],
      [:type_check, /steep|typecheck|type.?check|rbs/i],
      [:lint, %r{lint|rubocop|standard/|actionlint|yaml-lint|semgrep|zizmor}i],
      [:security, /codeql|security|semgrep/i],
      [:tests, %r{test|spec|build & test|parametric|end-to-end|junit}i],
      [:build, /\bbuild\b|compile|bundle/i]
    ].freeze

    CATEGORY_LABELS = {
      meta: "Meta",
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

    def categorize_job(job)
      name = job.name
      category = detect_category(name)

      JobFailure.new(
        job_name: name,
        job_id: job.id,
        category: category,
        url: job.html_url,
        details: nil
      )
    end

    def categorize_jobs(jobs)
      jobs.map { |job| categorize_job(job) }
    end

    def group_by_category(job_failures)
      grouped = job_failures.group_by(&:category)

      # Ensure consistent ordering
      result = {}
      [:meta, :type_check, :lint, :security, :tests, :build, :uncategorized].each do |cat|
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
  end
end
