# frozen_string_literal: true

require "octokit"
require "faraday"
require "faraday/follow_redirects"
require "zip"
require "fileutils"
require "open3"
require_relative "etag_cache"

module Bells
  class GitHubClient
    REPO = "DataDog/dd-trace-rb"

    # Global ETag cache shared across all instances
    ETAG_CACHE = ETagCache.new

    def initialize(token: nil, etag_cache: ETAG_CACHE)
      @token = token || ENV["GITHUB_TOKEN"] || fetch_gh_token
      @token = nil if @token&.empty?
      @client = Octokit::Client.new(access_token: @token)
      @client.auto_paginate = false
      @etag_cache = etag_cache
    end

    def pull_requests(state: "open", per_page: 30)
      fetch_with_etag("pulls:#{state}:#{per_page}") do |cached_etag|
        options = {}
        options[:headers] = { "If-None-Match" => cached_etag } if cached_etag

        response = @client.pull_requests(REPO, state: state, per_page: per_page, **options)

        # Check if response was 304 Not Modified
        last_response = @client.last_response
        if last_response && last_response.status == 304
          # Data not modified, return cached indicator
          { data: nil, etag: cached_etag, not_modified: true }
        else
          # New data received
          etag = last_response&.headers&.[]("etag")
          { data: response, etag: etag, not_modified: false }
        end
      end
    end

    def pull_request(pr_number)
      fetch_with_etag("pull:#{pr_number}") do |cached_etag|
        options = {}
        options[:headers] = { "If-None-Match" => cached_etag } if cached_etag

        response = @client.pull_request(REPO, pr_number, **options)

        # Check if response was 304 Not Modified
        last_response = @client.last_response
        if last_response && last_response.status == 304
          # Data not modified, return cached indicator
          { data: nil, etag: cached_etag, not_modified: true }
        else
          # New data received
          etag = last_response&.headers&.[]("etag")
          { data: response, etag: etag, not_modified: false }
        end
      end
    end

    def ci_status(sha)
      # Use combined_status API - single call returns rollup state
      fetch_with_etag("combined_status:#{sha}") do |cached_etag|
        options = {}
        options[:headers] = { "If-None-Match" => cached_etag } if cached_etag

        response = @client.combined_status(REPO, sha, **options)

        # Check if response was 304 Not Modified
        last_response = @client.last_response
        if last_response && last_response.status == 304
          # Data not modified, return cached indicator
          { data: nil, etag: cached_etag, not_modified: true }
        else
          # Convert GitHub state to our status symbols
          status = case response.state
          when "success"
            :green
          when "pending", "queued", "in_progress"
            :pending_clean  # Simplified - can't distinguish pending_failing without check runs
          when "failure", "error"
            :failed
          else
            :unknown
          end

          etag = last_response&.headers&.[]("etag")
          { data: status, etag: etag, not_modified: false }
        end
      end
    end

    def workflow_runs_for_pr(pr_number, pr: nil)
      pr ||= @client.pull_request(REPO, pr_number)
      head_sha = pr.head.sha

      runs = @client.repository_workflow_runs(REPO, branch: pr.head.ref)[:workflow_runs]
      runs.select { |run| run.head_sha == head_sha }
    end

    def failed_runs(pr_number, pr: nil)
      workflow_runs_for_pr(pr_number, pr: pr).select { |run| run.conclusion == "failure" }
    end

    def check_runs_for_pr(pr_number, pr: nil)
      pr ||= @client.pull_request(REPO, pr_number)

      # Fetch all check runs with filter='latest' to get only the most recent run of each job
      # This excludes re-runs and gives us the same count as GitHub's UI
      all_runs = []
      page = 1
      loop do
        response = @client.check_runs_for_ref(REPO, pr.head.sha, per_page: 100, page: page, filter: 'latest')
        all_runs.concat(response[:check_runs])
        break if response[:check_runs].size < 100
        page += 1
      end
      all_runs
    end

    def failed_jobs_for_pr(pr_number, pr: nil, check_runs: nil)
      check_runs ||= check_runs_for_pr(pr_number, pr: pr)
      check_runs.select { |run| run.conclusion == "failure" }
    end

    def in_progress_jobs_for_pr(pr_number, pr: nil, check_runs: nil)
      check_runs ||= check_runs_for_pr(pr_number, pr: pr)
      check_runs.select { |run| run.status != "completed" }
    end

    # Fetch commit statuses (GitLab CI that reports via GitHub status API)
    # Returns the latest status for each unique context
    def commit_statuses_for_pr(pr_number, pr: nil)
      pr ||= pull_request(pr_number)
      sha = pr.head.sha

      # Temporarily enable auto_paginate to fetch all statuses
      old_auto_paginate = @client.auto_paginate
      @client.auto_paginate = true

      # Fetch all statuses (paginated automatically)
      # Note: statuses API returns statuses in reverse chronological order,
      # so the first occurrence of each context is the latest
      all_statuses = @client.statuses(REPO, sha)

      # Group by context and take the first (latest) status for each
      by_context = all_statuses.group_by(&:context)
      by_context.values.map(&:first)
    ensure
      @client.auto_paginate = old_auto_paginate if old_auto_paginate != nil
    end

    def failed_statuses_for_pr(pr_number, pr: nil)
      statuses = commit_statuses_for_pr(pr_number, pr: pr)
      statuses.select { |status| status.state == "failure" || status.state == "error" }
    end

    def passed_statuses_for_pr(pr_number, pr: nil)
      statuses = commit_statuses_for_pr(pr_number, pr: pr)
      statuses.select { |status| status.state == "success" }
    end

    def pending_statuses_for_pr(pr_number, pr: nil)
      statuses = commit_statuses_for_pr(pr_number, pr: pr)
      statuses.select { |status| status.state == "pending" }
    end

    def job_logs(job_id, cache_dir: ".cache")
      # Check cache first
      cache_path = File.join(cache_dir, "logs", "#{job_id}.log")
      return File.read(cache_path) if File.exist?(cache_path)

      # Fetch from API
      url = "https://api.github.com/repos/#{REPO}/actions/jobs/#{job_id}/logs"

      conn = Faraday.new do |f|
        f.response :follow_redirects
      end

      response = conn.get(url) do |req|
        req.headers["Authorization"] = "Bearer #{@token}" if @token
        req.headers["Accept"] = "application/vnd.github+json"
      end

      if response.success? && response.body
        # Cache the logs using atomic write to prevent corruption
        Bells.atomic_write(cache_path, response.body)
        response.body
      else
        nil
      end
    rescue
      nil
    end

    def restart_job(job_id)
      url = "https://api.github.com/repos/#{REPO}/actions/jobs/#{job_id}/rerun"

      conn = Faraday.new do |f|
        f.response :follow_redirects
      end

      response = conn.post(url) do |req|
        req.headers["Authorization"] = "Bearer #{@token}" if @token
        req.headers["Accept"] = "application/vnd.github+json"
      end

      response.success?
    end

    def download_junit_artifacts(pr_number, cache_dir:, pr: nil)
      pr_cache = File.join(cache_dir, pr_number.to_s)
      FileUtils.mkdir_p(pr_cache)
      @download_errors = []

      result = workflow_runs_for_pr(pr_number, pr: pr).flat_map do |run|
        download_artifacts_for_run(run, pr_cache)
      end

      { artifact_dirs: result, errors: @download_errors }
    end

    private

    # Wrapper for ETag-based conditional requests
    def fetch_with_etag(cache_key)
      @etag_cache.fetch(cache_key) do |cached_etag|
        yield(cached_etag)
      end
    end

    def with_auto_paginate
      original = @client.auto_paginate
      @client.auto_paginate = true
      yield
    ensure
      @client.auto_paginate = original
    end

    def download_artifacts_for_run(run, cache_dir)
      artifacts = with_auto_paginate { @client.workflow_run_artifacts(REPO, run.id)[:artifacts] }
      junit_artifacts = artifacts.select { |a| a.name.match?(/junit|test-results/i) }

      # Download artifacts in parallel
      threads = junit_artifacts.map do |artifact|
        Thread.new { download_artifact(artifact, run, cache_dir) }
      end

      threads.map(&:value).compact
    end

    def download_artifact(artifact, run, cache_dir)
      artifact_path = File.join(cache_dir, "#{run.id}_#{artifact.name}")
      return artifact_path if Dir.exist?(artifact_path)

      zip_path = "#{artifact_path}.zip"
      url = "https://api.github.com/repos/#{REPO}/actions/artifacts/#{artifact.id}/zip"

      conn = Faraday.new do |f|
        f.response :follow_redirects
      end

      response = conn.get(url) do |req|
        req.headers["Authorization"] = "Bearer #{@token}" if @token
        req.headers["Accept"] = "application/vnd.github+json"
      end

      unless response.success?
        error_msg = "Failed to download artifact #{artifact.name}: HTTP #{response.status}"
        warn error_msg
        @download_errors << error_msg if @download_errors
        return nil
      end

      if response.body.nil? || response.body.empty?
        error_msg = "Failed to download artifact #{artifact.name}: empty response"
        warn error_msg
        @download_errors << error_msg if @download_errors
        return nil
      end

      # Use atomic write with validation to prevent corruption from concurrent downloads
      # Validate zip integrity before renaming from .part to .zip
      Bells.atomic_write(zip_path, response.body, binary: true) do |temp_path|
        valid_zip?(temp_path)
      end

      extract_zip(zip_path, artifact_path)
      FileUtils.rm_f(zip_path)

      artifact_path
    rescue => e
      error_msg = "Failed to download artifact #{artifact.name}: #{e.message}"
      warn error_msg
      @download_errors << error_msg if @download_errors
      FileUtils.rm_f(zip_path) if zip_path
      nil
    end

    def valid_zip?(zip_path)
      # Try to open the zip file to verify it's valid
      # Don't extract, just verify structure
      Zip::File.open(zip_path) do |zip|
        # If we can open it and iterate entries, it's valid
        zip.count
      end
      true
    rescue Zip::Error, Errno::EINVAL => e
      # Zip is corrupted or invalid
      false
    end

    def extract_zip(zip_path, dest_dir)
      FileUtils.mkdir_p(dest_dir)
      dest_dir_real = File.realpath(dest_dir)

      Zip::File.open(zip_path) do |zip|
        zip.each do |entry|
          # Prevent Zip Slip: validate that extraction path stays within dest_dir
          extract_path = File.join(dest_dir, entry.name)
          extract_path_real = File.expand_path(extract_path)

          unless extract_path_real.start_with?(dest_dir_real + File::SEPARATOR) || extract_path_real == dest_dir_real
            error_msg = "Zip Slip attempt detected: #{entry.name}"
            warn error_msg
            @download_errors << error_msg if @download_errors
            next
          end

          FileUtils.mkdir_p(File.dirname(extract_path))
          entry.extract(extract_path) { true }
        end
      end
    end

    def fetch_gh_token
      # Use Open3 instead of backticks to avoid shell injection
      stdout, status = Open3.capture2("gh", "auth", "token", err: File::NULL)
      status.success? ? stdout.strip : nil
    rescue Errno::ENOENT
      # gh command not found
      nil
    end
  end
end
