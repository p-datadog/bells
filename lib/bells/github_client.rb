# frozen_string_literal: true

require "octokit"
require "zip"
require "fileutils"

module Bells
  class GitHubClient
    REPO = "DataDog/dd-trace-rb"

    def initialize(token: ENV["GITHUB_TOKEN"])
      @client = Octokit::Client.new(access_token: token)
      @client.auto_paginate = true
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
      return artifact_path if File.exist?(artifact_path)

      zip_path = "#{artifact_path}.zip"
      url = @client.workflow_run_artifact_download_url(REPO, artifact.id)

      response = Faraday.get(url) do |req|
        req.headers["Authorization"] = "Bearer #{@client.access_token}"
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
