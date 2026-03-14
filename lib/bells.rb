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

  # Atomic file write helper to prevent corruption from concurrent writes
  # Writes to a temporary file with unique suffix then renames atomically
  # Optional validate block: called with temp_path before rename, should return true if valid
  def self.atomic_write(path, content, binary: false, &validate)
    # Use unique suffix to prevent conflicts from concurrent writes
    temp_path = "#{path}.part.#{Process.pid}.#{Thread.current.object_id}"
    FileUtils.mkdir_p(File.dirname(path))

    if binary
      File.binwrite(temp_path, content)
    else
      File.write(temp_path, content)
    end

    # Validate before renaming if block provided
    if validate
      unless validate.call(temp_path)
        File.delete(temp_path)
        raise "Validation failed for #{path}"
      end
    end

    File.rename(temp_path, path)
  rescue => e
    File.delete(temp_path) if File.exist?(temp_path)
    raise
  end

  class << self
    def analyze_pr(pr_number, cache_dir: ".cache", pr: nil)
      client = GitHubClient.new

      # Fetch PR once if not provided - check cache first (background refresh populates this)
      pr ||= PR_CACHE.fetch("pr:#{pr_number}") do
        client.pull_request(pr_number)
      end

      # Check cache first
      cached = load_cached_analysis(pr_number, cache_dir, pr)
      return cached if cached
      client = GitHubClient.new
      parser = JunitParser.new
      aggregator = FailureAggregator.new
      categorizer = FailureCategorizer.new

      # Fetch check runs once and filter for failed/in-progress/passed jobs
      check_runs = client.check_runs_for_pr(pr_number, pr: pr)
      failed_jobs = client.failed_jobs_for_pr(pr_number, pr: pr, check_runs: check_runs)
      in_progress_jobs = client.in_progress_jobs_for_pr(pr_number, pr: pr, check_runs: check_runs)
      passed_jobs = check_runs.select { |run| run.conclusion == "success" }
      job_failures = categorizer.categorize_jobs(failed_jobs, github_client: client)
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
      download_result = client.download_junit_artifacts(pr_number, cache_dir: cache_dir, pr: pr)
      artifact_dirs = download_result[:artifact_dirs]
      download_errors = download_result[:errors]

      # Two-pass parsing for performance:
      # Pass 1: Parse only failures to identify which tests failed
      test_failures = artifact_dirs.flat_map do |dir|
        parser.parse_directory_failures_only(dir) if dir && File.directory?(dir)
      end.compact

      # Pass 2: Parse all results (passes + failures) for only the tests that failed
      failed_test_ids = test_failures.map { |f| "#{f.test_class}##{f.test_name}" }.uniq

      test_results = if failed_test_ids.any?
        artifact_dirs.flat_map do |dir|
          parser.parse_directory_for_tests(dir, failed_test_ids) if dir && File.directory?(dir)
        end.compact
      else
        []
      end

      test_summary = aggregator.summary(test_results)

      result = {
        categorized_failures: categorized,
        meta_failures: meta_failures,
        test_details: test_summary,
        total_failed_jobs: failed_jobs.size,
        in_progress_jobs: in_progress_jobs.size,
        passed_jobs: passed_jobs.size,
        auto_restarted: auto_restarted,
        download_errors: download_errors
      }

      # Save to cache
      save_cached_analysis(pr_number, cache_dir, pr, result)

      result
    end

    def analyze_pr_streaming(pr_number, cache_dir: ".cache", pr: nil, ci_status: nil, &on_progress)
      start_time = Time.now
      log_timing = ->(msg) { puts "[TIMING] #{((Time.now - start_time) * 1000).to_i}ms - #{msg}" }

      client = GitHubClient.new
      log_timing.call("GitHubClient initialized")

      # Debug: Log what ci_status we received
      puts "[DEBUG] ci_status parameter: #{ci_status.inspect} (class: #{ci_status.class})"

      # If CI status is green, skip everything - all jobs passed
      if ci_status == :green
        log_timing.call("CI status green - skipping expensive operations (no failures)")

        yield(:job_list, { failed_jobs: 0, in_progress: 0, passed_jobs: 0 })
        yield(:categorized_failures_initial, { categorized: {}, meta_failures: nil, auto_restarted: false })
        yield(:categorized_failures_final, { categorized: {}, meta_failures: nil, auto_restarted: false })
        yield(:test_details, { total_failures: 0, unique_tests: 0, flaky_tests: 0, aggregated: [] })

        log_timing.call("All events sent for passing PR")
        return nil
      end

      # Fetch PR if not provided - check cache first (background refresh populates this)
      pr ||= PR_CACHE.fetch("pr:#{pr_number}") do
        client.pull_request(pr_number)
      end
      cache_source = PR_CACHE.fetch("pr:#{pr_number}") { nil } ? "cache" : "API"
      log_timing.call("PR fetched (from #{cache_source})")

      # Check cache first - if cached, send all events immediately
      cached = load_cached_analysis(pr_number, cache_dir, pr)
      log_timing.call("Cache checked (#{cached ? 'HIT' : 'MISS'})")

      if cached
        yield(:job_list, {
          failed_jobs: cached[:total_failed_jobs],
          in_progress: cached[:in_progress_jobs],
          passed_jobs: cached[:passed_jobs]
        })

        # For cached results, send both categorization events immediately
        # (no delay since we already have the final data)
        yield(:categorized_failures_initial, {
          categorized: serialize_failures_for_json(cached[:categorized_failures]),
          meta_failures: serialize_failures_for_json(cached[:meta_failures]),
          auto_restarted: cached[:auto_restarted]
        })

        yield(:categorized_failures_final, {
          categorized: serialize_failures_for_json(cached[:categorized_failures]),
          meta_failures: serialize_failures_for_json(cached[:meta_failures]),
          auto_restarted: cached[:auto_restarted]
        })

        yield(:test_details, cached[:test_details])
        return cached
      end

      # Not cached - run analysis with progress updates
      parser = JunitParser.new
      aggregator = FailureAggregator.new
      categorizer = FailureCategorizer.new

      # Fetch check runs
      check_runs = client.check_runs_for_pr(pr_number, pr: pr)
      log_timing.call("Check runs fetched (#{check_runs.size} total)")

      failed_jobs = client.failed_jobs_for_pr(pr_number, pr: pr, check_runs: check_runs)
      in_progress_jobs = client.in_progress_jobs_for_pr(pr_number, pr: pr, check_runs: check_runs)
      passed_jobs = check_runs.select { |run| run.conclusion == "success" }
      log_timing.call("Jobs filtered (#{failed_jobs.size} failed, #{in_progress_jobs.size} in progress, #{passed_jobs.size} passed)")

      # Send job list event
      yield(:job_list, {
        failed_jobs: failed_jobs.size,
        in_progress: in_progress_jobs.size,
        passed_jobs: passed_jobs.size,
        failed_job_names: failed_jobs.map(&:name)
      })

      log_timing.call("EVENT 1: job_list sent")

      # Phase 1: Send initial categorization WITHOUT infrastructure detection
      # This is fast (name-based only, no log downloads)
      initial_job_failures = categorizer.categorize_jobs(failed_jobs, github_client: nil)
      initial_categorized = categorizer.group_by_category(initial_job_failures)
      log_timing.call("Initial categorization complete (name-based, no logs)")

      yield(:categorized_failures_initial, {
        categorized: serialize_failures_for_json(initial_categorized),
        meta_failures: nil,
        auto_restarted: false
      })
      log_timing.call("EVENT 2: categorized_failures_initial sent")

      # Phase 2: Download logs in parallel and send updated categorization
      # Parallelize the log downloads for infrastructure detection
      log_timing.call("Starting parallel log downloads for #{failed_jobs.size} jobs...")
      threads = failed_jobs.map do |job|
        Thread.new { categorizer.categorize_job(job, github_client: client) }
      end
      job_failures = threads.map(&:value)
      log_timing.call("Parallel log downloads complete")

      categorized = categorizer.group_by_category(job_failures)
      log_timing.call("Final categorization complete (with infrastructure detection)")

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

      # Extract meta-check failures
      meta_failures = nil
      if categorized.size > 1 && categorized[:meta]
        meta_failures = categorized.delete(:meta)
      end

      # Send final categorized failures event
      yield(:categorized_failures_final, {
        categorized: serialize_failures_for_json(categorized),
        meta_failures: serialize_failures_for_json(meta_failures),
        auto_restarted: auto_restarted
      })
      log_timing.call("EVENT 3: categorized_failures_final sent")

      # Skip artifact downloads if no failed jobs (all passed or only in-progress)
      if failed_jobs.empty?
        log_timing.call("No failed jobs - skipping artifact downloads and parsing")

        yield(:test_details, {
          total_failures: 0,
          unique_tests: 0,
          flaky_tests: 0,
          aggregated: []
        })
        log_timing.call("EVENT 4: test_details sent (empty)")

        result = {
          categorized_failures: categorized,
          meta_failures: meta_failures,
          test_details: { total_failures: 0, unique_tests: 0, flaky_tests: 0, aggregated: [] },
          total_failed_jobs: 0,
          in_progress_jobs: in_progress_jobs.size,
          passed_jobs: passed_jobs.size,
          auto_restarted: auto_restarted,
          download_errors: []
        }

        save_cached_analysis(pr_number, cache_dir, pr, result)
        log_timing.call("Analysis cached to disk")
        log_timing.call("COMPLETE - Total time: #{((Time.now - start_time) * 1000).to_i}ms")

        return result
      end

      # Download artifacts and parse (slowest part)
      log_timing.call("Starting artifact downloads...")
      download_result = client.download_junit_artifacts(pr_number, cache_dir: cache_dir, pr: pr)
      artifact_dirs = download_result[:artifact_dirs]
      download_errors = download_result[:errors]
      log_timing.call("Artifact downloads complete (#{artifact_dirs.compact.size} artifacts)")

      # Parse JUnit
      log_timing.call("Starting JUnit parsing (pass 1: failures only)...")
      test_failures = artifact_dirs.flat_map do |dir|
        parser.parse_directory_failures_only(dir) if dir && File.directory?(dir)
      end.compact
      log_timing.call("JUnit pass 1 complete (#{test_failures.size} failures found)")

      failed_test_ids = test_failures.map { |f| "#{f.test_class}##{f.test_name}" }.uniq

      log_timing.call("Starting JUnit parsing (pass 2: full results for #{failed_test_ids.size} tests)...")
      test_results = if failed_test_ids.any?
        artifact_dirs.flat_map do |dir|
          parser.parse_directory_for_tests(dir, failed_test_ids) if dir && File.directory?(dir)
        end.compact
      else
        []
      end
      log_timing.call("JUnit pass 2 complete (#{test_results.size} test results)")

      test_summary = aggregator.summary(test_results)
      log_timing.call("Test summary aggregated")

      # Send test details event
      yield(:test_details, test_summary)
      log_timing.call("EVENT 4: test_details sent")

      # Build result for caching
      result = {
        categorized_failures: categorized,
        meta_failures: meta_failures,
        test_details: test_summary,
        total_failed_jobs: failed_jobs.size,
        in_progress_jobs: in_progress_jobs.size,
        passed_jobs: passed_jobs.size,
        auto_restarted: auto_restarted,
        download_errors: download_errors
      }

      save_cached_analysis(pr_number, cache_dir, pr, result)
      result
    end

    private

    def serialize_failures_for_json(failures)
      return nil if failures.nil?
      return {} if failures.is_a?(Hash) && failures.empty?

      if failures.is_a?(Hash)
        failures.transform_values { |f| f.map(&:to_h) }
      elsif failures.is_a?(Array)
        failures.map(&:to_h)
      else
        failures
      end
    end

    def cache_path(pr_number, cache_dir)
      File.join(cache_dir, pr_number.to_s, "analysis.json")
    end

    def load_cached_analysis(pr_number, cache_dir, pr)
      path = cache_path(pr_number, cache_dir)
      return nil unless File.exist?(path)

      cached = JSON.parse(File.read(path), symbolize_names: true)

      # Invalidate if stale (> 5 minutes old)
      return nil if Time.now - Time.parse(cached[:cached_at]) > CACHE_TTL

      # Invalidate if PR head SHA changed
      return nil if cached[:head_sha] != pr.head.sha

      # Convert structs back
      deserialize_cached_analysis(cached)
    rescue => e
      warn "Failed to load cache for PR #{pr_number}: #{e.message}"
      nil
    end

    def deserialize_cached_analysis(cached)

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
      if cached[:test_details] && cached[:test_details][:aggregated]
        cached[:test_details][:aggregated] = cached[:test_details][:aggregated].map do |f|
          # Convert instances back to TestResult structs
          instances = f[:instances].map do |i|
            ctx = i[:build_context] ? JunitParser::BuildContext.new(**i[:build_context]) : nil
            # Convert status string back to symbol
            status = i[:status].is_a?(String) ? i[:status].to_sym : i[:status]
            JunitParser::TestResult.new(**i.merge(build_context: ctx, status: status))
          end
          FailureAggregator::AggregatedFailure.new(**f.merge(instances: instances))
        end
      end

      # Download errors are not cached (they're transient)
      cached[:download_errors] ||= []

      cached
    rescue => e
      warn "Failed to load cache for PR #{pr_number}: #{e.message}"
      nil
    end

    def save_cached_analysis(pr_number, cache_dir, pr, result)
      path = cache_path(pr_number, cache_dir)
      FileUtils.mkdir_p(File.dirname(path))

      # Convert structs to hashes for JSON serialization
      # Deep copy to avoid modifying the original result
      serialized = result.dup
      if result[:test_details]
        serialized[:test_details] = result[:test_details].dup
        serialized[:test_details][:aggregated] = result[:test_details][:aggregated].dup if result[:test_details][:aggregated]
      end
      serialized[:categorized_failures] = result[:categorized_failures].dup if result[:categorized_failures]
      serialized[:meta_failures] = result[:meta_failures].dup if result[:meta_failures]
      serialized[:head_sha] = pr.head.sha
      serialized[:cached_at] = Time.now.iso8601

      # Don't cache download_errors (they're transient/retriable)
      serialized.delete(:download_errors)

      # Convert JobFailure structs to hashes
      if serialized[:categorized_failures]
        serialized[:categorized_failures] = serialized[:categorized_failures].transform_values do |failures|
          failures.dup.map(&:to_h)
        end
      end

      if serialized[:meta_failures]
        serialized[:meta_failures] = serialized[:meta_failures].dup.map(&:to_h)
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

      Bells.atomic_write(path, JSON.pretty_generate(serialized))
    rescue => e
      warn "Failed to save cache for PR #{pr_number}: #{e.message}"
    end
  end
end
