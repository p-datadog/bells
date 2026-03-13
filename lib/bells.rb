# frozen_string_literal: true

require_relative "bells/github_client"
require_relative "bells/junit_parser"
require_relative "bells/failure_aggregator"
require_relative "bells/failure_categorizer"
require "json"
require "fileutils"

module Bells
  # Job name for the meta-check that waits for all other jobs
  META_CHECK_JOB_NAME = "all-jobs-are-green"
  CACHE_TTL = 300 # 5 minutes

  class << self
    def analyze_pr(pr_number, cache_dir: ".cache")
      client = GitHubClient.new

      # Check cache first
      cached = load_cached_analysis(pr_number, cache_dir, client)
      return cached if cached
      client = GitHubClient.new
      parser = JunitParser.new
      aggregator = FailureAggregator.new
      categorizer = FailureCategorizer.new

      # Get all failed jobs and categorize them
      failed_jobs = client.failed_jobs_for_pr(pr_number)
      in_progress_jobs = client.in_progress_jobs_for_pr(pr_number)
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

      # Extract meta-check failures to show separately when there are other failures
      meta_failures = nil
      if categorized.size > 1 && categorized[:meta]
        meta_failures = categorized.delete(:meta)
      end

      # Get detailed test failures from JUnit artifacts
      download_result = client.download_junit_artifacts(pr_number, cache_dir: cache_dir)
      artifact_dirs = download_result[:artifact_dirs]
      download_errors = download_result[:errors]

      test_failures = artifact_dirs.flat_map do |dir|
        parser.parse_directory(dir) if dir && File.directory?(dir)
      end.compact
      test_summary = aggregator.summary(test_failures)

      result = {
        categorized_failures: categorized,
        meta_failures: meta_failures,
        test_details: test_summary,
        total_failed_jobs: failed_jobs.size,
        in_progress_jobs: in_progress_jobs.size,
        auto_restarted: auto_restarted,
        download_errors: download_errors
      }

      # Save to cache
      save_cached_analysis(pr_number, cache_dir, client, result)

      result
    end

    private

    def cache_path(pr_number, cache_dir)
      File.join(cache_dir, pr_number.to_s, "analysis.json")
    end

    def load_cached_analysis(pr_number, cache_dir, client)
      path = cache_path(pr_number, cache_dir)
      return nil unless File.exist?(path)

      cached = JSON.parse(File.read(path), symbolize_names: true)

      # Invalidate if stale (> 5 minutes old)
      return nil if Time.now - Time.parse(cached[:cached_at]) > CACHE_TTL

      # Invalidate if PR head SHA changed
      pr = client.pull_request(pr_number)
      return nil if cached[:head_sha] != pr.head.sha

      # Convert JobFailure structs back from hashes
      if cached[:categorized_failures]
        cached[:categorized_failures] = cached[:categorized_failures].transform_values do |failures|
          failures.map { |f| FailureCategorizer::JobFailure.new(**f) }
        end
      end

      if cached[:meta_failures]
        cached[:meta_failures] = cached[:meta_failures].map { |f| FailureCategorizer::JobFailure.new(**f) }
      end

      # Convert AggregatedFailure structs back
      if cached[:test_details][:aggregated]
        cached[:test_details][:aggregated] = cached[:test_details][:aggregated].map do |f|
          # Convert instances back to TestResult structs
          instances = f[:instances].map do |i|
            ctx = i[:build_context] ? JunitParser::BuildContext.new(**i[:build_context]) : nil
            JunitParser::TestResult.new(**i.merge(build_context: ctx))
          end
          FailureAggregator::AggregatedFailure.new(**f.merge(instances: instances))
        end
      end

      cached
    rescue => e
      warn "Failed to load cache for PR #{pr_number}: #{e.message}"
      nil
    end

    def save_cached_analysis(pr_number, cache_dir, client, result)
      pr = client.pull_request(pr_number)
      path = cache_path(pr_number, cache_dir)
      FileUtils.mkdir_p(File.dirname(path))

      # Convert structs to hashes for JSON serialization
      serialized = result.dup
      serialized[:head_sha] = pr.head.sha
      serialized[:cached_at] = Time.now.iso8601

      # Convert JobFailure structs to hashes
      if serialized[:categorized_failures]
        serialized[:categorized_failures] = serialized[:categorized_failures].transform_values do |failures|
          failures.map(&:to_h)
        end
      end

      if serialized[:meta_failures]
        serialized[:meta_failures] = serialized[:meta_failures].map(&:to_h)
      end

      # Convert AggregatedFailure structs (including nested TestResult instances)
      if serialized[:test_details][:aggregated]
        serialized[:test_details][:aggregated] = serialized[:test_details][:aggregated].map do |f|
          f_hash = f.to_h
          f_hash[:instances] = f.instances.map do |i|
            i_hash = i.to_h
            i_hash[:build_context] = i.build_context&.to_h
            i_hash
          end
          f_hash
        end
      end

      File.write(path, JSON.pretty_generate(serialized))
    rescue => e
      warn "Failed to save cache for PR #{pr_number}: #{e.message}"
    end
  end
end
