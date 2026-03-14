# frozen_string_literal: true

require "spec_helper"
require_relative "../../app"

RSpec.describe "PR Streaming Routes" do
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  describe "GET /pr/:number/stream" do
    let(:mock_client) { instance_double(Bells::GitHubClient) }
    let(:mock_pr) { OpenStruct.new(
      number: 123,
      title: "Test PR",
      user: OpenStruct.new(login: "testuser"),
      head: OpenStruct.new(sha: "abc123")
    ) }

    before do
      allow(Bells::GitHubClient).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:pull_request).with(123).and_return(mock_pr)
      allow(mock_client).to receive(:ci_status).with("abc123").and_return(:green)
    end

    it "streams events for PR analysis" do
      # Mock analyze_pr_streaming to yield test events
      allow(Bells).to receive(:analyze_pr_streaming).and_yield(
        :job_list,
        { failed_jobs: 2, in_progress: 0, passed_jobs: 10 }
      ).and_yield(
        :categorized_failures,
        { categorized: { tests: [] }, meta_failures: nil }
      ).and_yield(
        :test_details,
        { total_failures: 5, unique_tests: 3, flaky_tests: 1, aggregated: [] }
      )

      get "/pr/123/stream"

      expect(last_response).to be_ok
      expect(last_response.headers["Content-Type"]).to include("text/event-stream")
      expect(last_response.headers["Cache-Control"]).to eq("no-cache")

      body = last_response.body

      # Check for expected events
      expect(body).to include("event: pr_basic")
      expect(body).to include("event: ci_status")
      expect(body).to include("event: job_list")
      expect(body).to include("event: categorized_failures")
      expect(body).to include("event: test_details")
      expect(body).to include("event: complete")

      # Check data content
      expect(body).to include('"number":123')
      expect(body).to include('"title":"Test PR"')
      expect(body).to include('"failed_jobs":2')
    end

    it "handles errors gracefully" do
      allow(Bells).to receive(:analyze_pr_streaming).and_raise(StandardError, "Test error")

      get "/pr/123/stream"

      expect(last_response).to be_ok
      body = last_response.body

      expect(body).to include("event: error")
      expect(body).to include('"message":"Test error"')
    end
  end

  describe "GET /pr/:number with streaming" do
    it "renders skeleton page with SSE client in production" do
      # Temporarily change environment to production to enable streaming
      original_env = Sinatra::Application.environment
      Sinatra::Application.set :environment, :production

      mock_client = instance_double(Bells::GitHubClient)
      mock_pr = OpenStruct.new(
        number: 123,
        title: "Test PR",
        user: OpenStruct.new(login: "testuser"),
        head: OpenStruct.new(sha: "abc123")
      )

      allow(Bells::GitHubClient).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:pull_request).with(123).and_return(mock_pr)
      allow(mock_client).to receive(:ci_status).with("abc123").and_return(:green)

      get "/pr/123"

      expect(last_response).to be_ok
      expect(last_response.body).to include("PR #123: Test PR")
      expect(last_response.body).to include("Author: testuser")
      expect(last_response.body).to include("EventSource('/pr/' + prNumber + '/stream')")
      expect(last_response.body).to include("job-summary-loading")
      expect(last_response.body).to include("categorized-loading")
      expect(last_response.body).to include("test-details-loading")

      # Restore environment
      Sinatra::Application.set :environment, original_env
    end
  end
end
