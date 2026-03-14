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
      # Use ETag for first page as freshness indicator
      # If first page returns 304, skip fetching - data likely unchanged
      # If first page returns 200, fetch all pages
      first_page_fresh = fetch_with_etag("check_runs:#{sha}:page1") do |cached_etag|
        options = { per_page: 100 }
        options[:headers] = { "If-None-Match" => cached_etag } if cached_etag

        response = @client.check_runs_for_ref(REPO, sha, **options)

        # Check if response was 304 Not Modified
        last_response = @client.last_response
        if last_response && last_response.status == 304
          # 304 - first page unchanged, likely rest unchanged too
          { data: nil, etag: cached_etag, not_modified: true }
        else
          # New data received
          etag = last_response&.headers&.[]("etag")
          { data: response, etag: etag, not_modified: false }
        end
      end

      # If first page returned 304, return cached result if available
      if first_page_fresh.nil?
        cached_status = @etag_cache.fetch("ci_status_result:#{sha}") do |_|
          # No cached result, need to fetch
          { data: nil, etag: nil, not_modified: false }
        end
        return cached_status if cached_status
      end

      # Limit to first 100 check runs for performance
      # Recent check runs are sufficient to determine overall CI status
      response = @client.check_runs_for_ref(REPO, sha, per_page: 100)
      check_runs = response[:check_runs]
      return :unknown if check_runs.empty?

      conclusions = check_runs.map(&:conclusion)
      statuses = check_runs.map(&:status)

      has_failures = conclusions.include?("failure")
      all_complete = statuses.all? { |s| s == "completed" }

      result = if all_complete
        has_failures ? :failed : :green
      else
        has_failures ? :pending_failing : :pending_clean
      end

      # Cache the computed result
      @etag_cache.fetch("ci_status_result:#{sha}") do |_|
        { data: result, etag: nil, not_modified: false }
      end

      result
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

    def check_runs_for_pr(pr_number, pr: nil, limit: 100)
      pr ||= @client.pull_request(REPO, pr_number)
      # Limit to most recent check runs for performance
      # Don't use auto_paginate - just get first page
      response = @client.check_runs_for_ref(REPO, pr.head.sha, per_page: limit)
      response[:check_runs]
    end

    def failed_jobs_for_pr(pr_number, pr: nil, check_runs: nil)
      check_runs ||= check_runs_for_pr(pr_number, pr: pr)
      check_runs.select { |run| run.conclusion == "failure" }
    end

    def in_progress_jobs_for_pr(pr_number, pr: nil, check_runs: nil)
      check_runs ||= check_runs_for_pr(pr_number, pr: pr)
      check_runs.select { |run| run.status != "completed" }
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
        # Cache the logs
        FileUtils.mkdir_p(File.dirname(cache_path))
        File.write(cache_path, response.body)
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

      FileUtils.mkdir_p(cache_dir)
      File.binwrite(zip_path, response.body)

      unless File.exist?(zip_path)
        error_msg = "Failed to write artifact #{artifact.name}: zip file not created"
        warn error_msg
        @download_errors << error_msg if @download_errors
        return nil
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
