# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require_relative "../../lib/bells/pr_cache"
require_relative "../../lib/bells/background_refresher"

RSpec.describe Bells::BackgroundRefresher do
  let(:cache) { Bells::PrCache.new }
  let(:refresher) { described_class.new(cache, interval: 1) }
  let(:mock_client) { instance_double(Bells::GitHubClient) }
  let(:mock_pr) { OpenStruct.new(number: 123, head: OpenStruct.new(sha: "abc")) }

  let(:mock_pr_data) { { prs: [mock_pr], ci_statuses: { 123 => :green } } }

  before do
    allow(Bells::GitHubClient).to receive(:new).and_return(mock_client)
    allow(mock_client).to receive(:pull_requests_with_status).and_return(mock_pr_data)
  end

  after do
    refresher.stop
  end

  describe "#start" do
    it "starts background thread" do
      refresher.start
      sleep 0.1

      expect(refresher.instance_variable_get(:@running)).to be(true)
      expect(refresher.instance_variable_get(:@thread)).to be_alive
    end

    it "does not start multiple times" do
      refresher.start
      original_thread = refresher.instance_variable_get(:@thread)

      refresher.start

      expect(refresher.instance_variable_get(:@thread)).to eq(original_thread)
    end

    it "refreshes cache periodically" do
      refresher.start
      sleep 1.5

      cached_data = cache.instance_variable_get(:@cache)["pr_list"]
      expect(cached_data).not_to be_nil
      expect(cached_data.data[:prs].size).to eq(1)
    end

    it "handles refresh errors gracefully and continues running" do
      call_count = 0
      allow(mock_client).to receive(:pull_requests_with_status) do
        call_count += 1
        raise "API Error" if call_count == 1
        mock_pr_data
      end

      refresher.start
      sleep 2.5

      # Thread should still be running after error
      expect(refresher.instance_variable_get(:@thread)).to be_alive

      # Should have attempted refresh multiple times
      expect(call_count).to be >= 2
    end

    it "implements exponential backoff on consecutive failures" do
      allow(mock_client).to receive(:pull_requests_with_status).and_raise("API Error")

      refresher.start
      sleep 0.5

      # Should have set consecutive failures counter
      expect(refresher.instance_variable_get(:@consecutive_failures)).to be > 0
    end
  end

  describe "#stop" do
    it "stops background thread gracefully" do
      refresher.start
      sleep 0.2

      refresher.stop

      expect(refresher.instance_variable_get(:@running)).to be(false)
      expect(refresher.instance_variable_get(:@thread)).to be_nil
    end

    it "waits for current operation to complete" do
      slow_operation = false
      allow(mock_client).to receive(:pull_requests_with_status) do
        slow_operation = true
        sleep 0.5
        mock_pr_data
      end

      refresher.start
      sleep 0.1

      refresher.stop

      # Should have waited for slow operation
      expect(slow_operation).to be(true)
    end

    it "handles being called when not running" do
      expect {
        refresher.stop
      }.not_to raise_error
    end
  end

  describe "#warm_pr_analysis" do
    let(:refresher) { described_class.new(cache, interval: 120, default_author: "testuser") }

    it "calls Bells.analyze_pr with the pr number and pr object" do
      expect(Bells).to receive(:analyze_pr).with(123, pr: mock_pr)
      refresher.send(:warm_pr_analysis, 123, mock_pr)
    end

    it "does not raise when Bells.analyze_pr raises a plain exception" do
      allow(Bells).to receive(:analyze_pr).and_raise("something went wrong")
      expect { refresher.send(:warm_pr_analysis, 123, mock_pr) }.not_to raise_error
    end

    it "does not raise when exception message contains % characters (e.g. URL-encoded)" do
      error = RuntimeError.new("GET https://api.github.com/repos/%5Bbot%5D/status returned 404 %28Not Found%29")
      allow(Bells).to receive(:analyze_pr).and_raise(error)
      expect { refresher.send(:warm_pr_analysis, 123, mock_pr) }.not_to raise_error
    end

    it "does not raise when exception message contains %s or %d format specifiers" do
      error = RuntimeError.new("too many %s and %d in message")
      allow(Bells).to receive(:analyze_pr).and_raise(error)
      expect { refresher.send(:warm_pr_analysis, 123, mock_pr) }.not_to raise_error
    end

    it "continues warming subsequent PRs after one fails" do
      pr2 = OpenStruct.new(number: 456, head: OpenStruct.new(sha: "def"))
      analyzed = []
      allow(Bells).to receive(:analyze_pr) do |pr_number, **|
        analyzed << pr_number
        raise "fail" if pr_number == 123
      end
      refresher.send(:warm_pr_analysis, 123, mock_pr)
      refresher.send(:warm_pr_analysis, 456, pr2)
      expect(analyzed).to eq([123, 456])
    end
  end

  describe "error handling" do
    it "recovers from GitHubClient initialization failures" do
      allow(Bells::GitHubClient).to receive(:new).and_raise("Init error")

      refresher.start
      sleep 1.5

      # Should still be running (not crashed)
      expect(refresher.instance_variable_get(:@thread)).to be_alive
    end

    it "recovers from API call failures" do
      allow(mock_client).to receive(:pull_requests_with_status).and_raise("API error")

      refresher.start
      sleep 1.5

      expect(refresher.instance_variable_get(:@thread)).to be_alive
    end
  end
end
