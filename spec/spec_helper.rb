# frozen_string_literal: true

ENV["RACK_ENV"] = "test"

require "bundler/setup"
require "rack/test"
require "vcr"
require "webmock/rspec"
require "ostruct"

require_relative "../lib/bells"

VCR.configure do |config|
  config.cassette_library_dir = "spec/fixtures/cassettes"
  config.hook_into :webmock
  config.filter_sensitive_data("<GITHUB_TOKEN>") { ENV["GITHUB_TOKEN"] }
  config.filter_sensitive_data("<GITHUB_TOKEN>") do
    require "open3"
    stdout, status = Open3.capture2("gh", "auth", "token", err: File::NULL)
    status.success? ? stdout.strip : nil
  rescue Errno::ENOENT
    nil
  end
  config.filter_sensitive_data("<GITLAB_TOKEN>") { ENV["GITLAB_TOKEN"] }
  config.filter_sensitive_data("<GITLAB_TOKEN>") do
    require "open3"
    stdout, status = Open3.capture2("glab", "auth", "token", "--hostname", "gitlab.ddbuild.io", err: File::NULL)
    status.success? ? stdout.strip : nil
  rescue Errno::ENOENT
    nil
  end
  config.configure_rspec_metadata!
  config.allow_http_connections_when_no_cassette = false
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
end
