# frozen_string_literal: true

require "spec_helper"

RSpec.describe Bells::GitHubClient do
  subject(:client) { described_class.new }

  describe "#pull_requests" do
    it "fetches open pull requests", :vcr do
      prs = client.pull_requests(per_page: 5)

      expect(prs).to be_an(Array)
      expect(prs.size).to be <= 5
      expect(prs.first).to respond_to(:number)
      expect(prs.first).to respond_to(:title)
    end
  end

  describe "#ci_status" do
    let(:octokit_client) { instance_double(Octokit::Client) }
    let(:last_response) { OpenStruct.new(status: 200, headers: { "etag" => '"abc123"' }) }

    before do
      allow(Octokit::Client).to receive(:new).and_return(octokit_client)
      allow(octokit_client).to receive(:auto_paginate=)
      allow(octokit_client).to receive(:auto_paginate).and_return(false)
      allow(octokit_client).to receive(:last_response).and_return(last_response)
    end

    it "returns :green when all checks pass" do
      allow(octokit_client).to receive(:check_runs_for_ref).and_return(
        check_runs: [
          OpenStruct.new(status: "completed", conclusion: "success"),
          OpenStruct.new(status: "completed", conclusion: "success")
        ]
      )
      client = described_class.new
      expect(client.ci_status("abc123")).to eq(:green)
    end

    it "returns :failed when checks complete with failures" do
      allow(octokit_client).to receive(:check_runs_for_ref).and_return(
        check_runs: [
          OpenStruct.new(status: "completed", conclusion: "success"),
          OpenStruct.new(status: "completed", conclusion: "failure")
        ]
      )
      client = described_class.new
      expect(client.ci_status("abc123")).to eq(:failed)
    end

    it "returns :pending_clean when in progress with no failures" do
      allow(octokit_client).to receive(:check_runs_for_ref).and_return(
        check_runs: [
          OpenStruct.new(status: "completed", conclusion: "success"),
          OpenStruct.new(status: "in_progress", conclusion: nil)
        ]
      )
      client = described_class.new
      expect(client.ci_status("abc123")).to eq(:pending_clean)
    end

    it "returns :pending_failing when in progress with failures" do
      allow(octokit_client).to receive(:check_runs_for_ref).and_return(
        check_runs: [
          OpenStruct.new(status: "completed", conclusion: "failure"),
          OpenStruct.new(status: "in_progress", conclusion: nil)
        ]
      )
      client = described_class.new
      expect(client.ci_status("abc123")).to eq(:pending_failing)
    end

    it "returns :unknown when no check runs exist" do
      allow(octokit_client).to receive(:check_runs_for_ref).and_return(check_runs: [])
      client = described_class.new
      expect(client.ci_status("abc123")).to eq(:unknown)
    end
  end

  describe "#workflow_runs_for_pr" do
    it "fetches workflow runs for a PR", :vcr do
      runs = client.workflow_runs_for_pr(5431)

      expect(runs).to be_an(Array)
      runs.each do |run|
        expect(run).to respond_to(:id)
        expect(run).to respond_to(:conclusion)
      end
    end
  end

  describe "#failed_runs" do
    it "filters to only failed runs", :vcr do
      failed = client.failed_runs(5431)

      expect(failed).to be_an(Array)
      failed.each do |run|
        expect(run.conclusion).to eq("failure")
      end
    end
  end

  describe "#download_junit_artifacts" do
    let(:cache_dir) { "tmp/test_cache" }

    before do
      FileUtils.rm_rf(cache_dir)
    end

    after do
      FileUtils.rm_rf(cache_dir)
    end

    it "downloads and extracts junit artifacts", :vcr do
      result = client.download_junit_artifacts(5431, cache_dir: cache_dir)

      expect(result).to be_a(Hash)
      expect(result[:artifact_dirs]).to be_an(Array)
      expect(result[:errors]).to be_an(Array)

      result[:artifact_dirs].compact.each do |dir|
        expect(Dir.exist?(dir)).to be true
        xml_files = Dir.glob(File.join(dir, "**/*.xml"))
        expect(xml_files).not_to be_empty
      end
    end
  end
end
