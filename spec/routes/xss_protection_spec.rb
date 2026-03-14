# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require_relative "../../app"

RSpec.describe "XSS Protection" do
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  before(:each) do
    PR_CACHE.clear
  end

  describe "GET /" do
    let(:mock_client) { instance_double(Bells::GitHubClient) }
    let(:xss_pr) do
      OpenStruct.new(
        number: 999,
        title: "<script>alert('XSS')</script>",
        html_url: "https://github.com/test",
        user: OpenStruct.new(login: "<img src=x onerror=alert('XSS')>"),
        head: OpenStruct.new(sha: "abc123"),
        updated_at: Time.now
      )
    end

    before do
      allow(Bells::GitHubClient).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:pull_requests).and_return([xss_pr])
      allow(mock_client).to receive(:ci_status).with("abc123").and_return(:green)
    end

    it "escapes XSS in PR titles" do
      get "/"

      expect(last_response).to be_ok
      expect(last_response.body).to include("&lt;script&gt;")
      expect(last_response.body).not_to include("<script>alert('XSS')</script>")
    end

    it "escapes XSS in user logins" do
      get "/"

      expect(last_response).to be_ok
      expect(last_response.body).to include("&lt;img")
      expect(last_response.body).not_to include("<img src=x onerror=")
    end
  end

  describe "GET /pr/:number" do
    let(:mock_client) { instance_double(Bells::GitHubClient) }
    let(:xss_pr) do
      OpenStruct.new(
        title: "<script>document.location='http://evil.com'</script>",
        head: OpenStruct.new(sha: "abc123")
      )
    end
    let(:mock_job) do
      Bells::FailureCategorizer::JobFailure.new(
        job_name: "<img src=x onerror=alert('XSS')>",
        job_id: 123,
        category: :tests,
        url: "https://github.com/test",
        details: "Error: <script>alert('XSS')</script>"
      )
    end

    before do
      allow(Bells::GitHubClient).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:pull_request).with(999).and_return(xss_pr)
      allow(mock_client).to receive(:ci_status).with("abc123").and_return(:failed)
      allow(Bells).to receive(:analyze_pr).with(999, anything).and_return(
        categorized_failures: { tests: [mock_job] },
        meta_failures: nil,
        test_details: { total_failures: 0, unique_tests: 0, flaky_tests: 0, aggregated: [] },
        total_failed_jobs: 1,
        in_progress_jobs: 0,
        passed_jobs: 5,
        auto_restarted: false,
        download_errors: []
      )
    end

    it "escapes XSS in PR title header" do
      get "/pr/999"

      expect(last_response).to be_ok
      expect(last_response.body).to include("&lt;script&gt;")
      expect(last_response.body).not_to include("<script>document.location=")
    end

    it "escapes XSS in job names" do
      get "/pr/999"

      expect(last_response).to be_ok
      expect(last_response.body).to include("&lt;img")
      expect(last_response.body).not_to include("<img src=x onerror=")
    end

    it "escapes XSS in job details" do
      get "/pr/999"

      expect(last_response).to be_ok
      # Job details should be escaped
      expect(last_response.body).to include("&lt;script&gt;")
    end
  end
end
