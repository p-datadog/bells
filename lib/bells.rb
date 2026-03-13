# frozen_string_literal: true

require_relative "bells/github_client"
require_relative "bells/junit_parser"
require_relative "bells/failure_aggregator"
require_relative "bells/failure_categorizer"

module Bells
  # Job name for the meta-check that waits for all other jobs
  META_CHECK_JOB_NAME = "all-jobs-are-green"

  class << self
    def analyze_pr(pr_number, cache_dir: ".cache")
      client = GitHubClient.new
      parser = JunitParser.new
      aggregator = FailureAggregator.new
      categorizer = FailureCategorizer.new

      # Get all failed jobs and categorize them
      failed_jobs = client.failed_jobs_for_pr(pr_number)
      job_failures = categorizer.categorize_jobs(failed_jobs)
      categorized = categorizer.group_by_category(job_failures)

      # Auto-restart meta-check job if it's the only failure
      auto_restarted = false
      if failed_jobs.size == 1 && failed_jobs.first.name == META_CHECK_JOB_NAME
        job_id = failed_jobs.first.id
        Thread.new do
          puts "Auto-restarting #{META_CHECK_JOB_NAME} job #{job_id} for PR #{pr_number}"
          client.restart_job(job_id)
        rescue => e
          warn "Failed to restart job #{job_id}: #{e.message}"
        end
        auto_restarted = true
      end

      # Get detailed test failures from JUnit artifacts
      artifact_dirs = client.download_junit_artifacts(pr_number, cache_dir: cache_dir)
      test_failures = artifact_dirs.flat_map do |dir|
        parser.parse_directory(dir) if dir && File.directory?(dir)
      end.compact
      test_summary = aggregator.summary(test_failures)

      {
        categorized_failures: categorized,
        test_details: test_summary,
        total_failed_jobs: failed_jobs.size,
        auto_restarted: auto_restarted
      }
    end
  end
end
