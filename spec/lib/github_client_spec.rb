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
      dirs = client.download_junit_artifacts(5431, cache_dir: cache_dir)

      expect(dirs).to be_an(Array)
      dirs.compact.each do |dir|
        expect(Dir.exist?(dir)).to be true
        xml_files = Dir.glob(File.join(dir, "**/*.xml"))
        expect(xml_files).not_to be_empty
      end
    end
  end
end
