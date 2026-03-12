# frozen_string_literal: true

require "octokit"
require "fileutils"

module Bells
  class GitHubClient
    REPO = "DataDog/dd-trace-rb"

    def initialize(token: ENV["GITHUB_TOKEN"])
      @token = token
      @client = Octokit::Client.new(access_token: token)
      @client.auto_paginate = false
    end

    def pull_requests(state: "open", per_page: 30)
      @client.pull_requests(REPO, state: state, per_page: per_page)
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

    def download_junit_artifacts(pr_number, cache_dir:)
      pr_cache = File.join(cache_dir, pr_number.to_s)
      FileUtils.mkdir_p(pr_cache)

      failed_runs(pr_number).flat_map do |run|
        download_artifacts_for_run(run, pr_cache)
      end
    end

    private

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

      FileUtils.mkdir_p(artifact_path)

      result = system(
        "gh", "run", "download", run.id.to_s,
        "-R", REPO,
        "-n", artifact.name,
        "-D", artifact_path,
        out: File::NULL,
        err: File::NULL
      )

      unless result
        warn "Failed to download artifact #{artifact.name} from run #{run.id}"
        FileUtils.rm_rf(artifact_path)
        return nil
      end

      artifact_path
    rescue => e
      warn "Failed to download artifact #{artifact.id}: #{e.message}"
      nil
    end
  end
end
