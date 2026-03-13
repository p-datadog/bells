# frozen_string_literal: true

require "octokit"
require "faraday"
require "faraday/follow_redirects"
require "zip"
require "fileutils"

module Bells
  class GitHubClient
    REPO = "DataDog/dd-trace-rb"

    def initialize(token: nil)
      @token = token || ENV["GITHUB_TOKEN"] || `gh auth token 2>/dev/null`.strip
      @token = nil if @token.empty?
      @client = Octokit::Client.new(access_token: @token)
      @client.auto_paginate = false
    end

    def pull_requests(state: "open", per_page: 30)
      @client.pull_requests(REPO, state: state, per_page: per_page)
    end

    def pull_request(pr_number)
      @client.pull_request(REPO, pr_number)
    end

    def ci_status(sha)
      check_runs = with_auto_paginate { @client.check_runs_for_ref(REPO, sha)[:check_runs] }
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

    def workflow_runs_for_pr(pr_number)
      pr = @client.pull_request(REPO, pr_number)
      head_sha = pr.head.sha

      runs = @client.repository_workflow_runs(REPO, branch: pr.head.ref)[:workflow_runs]
      runs.select { |run| run.head_sha == head_sha }
    end

    def failed_runs(pr_number)
      workflow_runs_for_pr(pr_number).select { |run| run.conclusion == "failure" }
    end

    def failed_jobs_for_pr(pr_number)
      pr = @client.pull_request(REPO, pr_number)
      check_runs = with_auto_paginate { @client.check_runs_for_ref(REPO, pr.head.sha)[:check_runs] }
      check_runs.select { |run| run.conclusion == "failure" }
    end

    def job_logs(job_id)
      url = "https://api.github.com/repos/#{REPO}/actions/jobs/#{job_id}/logs"

      conn = Faraday.new do |f|
        f.response :follow_redirects
      end

      response = conn.get(url) do |req|
        req.headers["Authorization"] = "Bearer #{@token}" if @token
        req.headers["Accept"] = "application/vnd.github+json"
      end

      response.success? ? response.body : nil
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

    def download_junit_artifacts(pr_number, cache_dir:)
      pr_cache = File.join(cache_dir, pr_number.to_s)
      FileUtils.mkdir_p(pr_cache)

      failed_runs(pr_number).flat_map do |run|
        download_artifacts_for_run(run, pr_cache)
      end
    end

    private

    def with_auto_paginate
      original = @client.auto_paginate
      @client.auto_paginate = true
      yield
    ensure
      @client.auto_paginate = original
    end

    def download_artifacts_for_run(run, cache_dir)
      artifacts = @client.workflow_run_artifacts(REPO, run.id)[:artifacts]
      junit_artifacts = artifacts.select { |a| a.name.match?(/junit|test-results/i) }

      junit_artifacts.map do |artifact|
        download_artifact(artifact, run, cache_dir)
      end.compact
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
        warn "Failed to download artifact #{artifact.name}: HTTP #{response.status}"
        return nil
      end

      File.binwrite(zip_path, response.body)
      extract_zip(zip_path, artifact_path)
      FileUtils.rm_f(zip_path)

      artifact_path
    rescue => e
      warn "Failed to download artifact #{artifact.id}: #{e.message}"
      nil
    end

    def extract_zip(zip_path, dest_dir)
      FileUtils.mkdir_p(dest_dir)
      Zip::File.open(zip_path) do |zip|
        zip.each do |entry|
          entry.extract(File.join(dest_dir, entry.name)) { true }
        end
      end
    end
  end
end
