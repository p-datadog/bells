# frozen_string_literal: true

require_relative "bells/github_client"
require_relative "bells/junit_parser"
require_relative "bells/failure_aggregator"

module Bells
  class << self
    def analyze_pr(pr_number, cache_dir: "cache")
      client = GitHubClient.new
      parser = JunitParser.new
      aggregator = FailureAggregator.new

      artifact_dirs = client.download_junit_artifacts(pr_number, cache_dir: cache_dir)

      failures = artifact_dirs.flat_map do |dir|
        parser.parse_directory(dir) if dir && File.directory?(dir)
      end.compact

      aggregator.summary(failures)
    end
  end
end
