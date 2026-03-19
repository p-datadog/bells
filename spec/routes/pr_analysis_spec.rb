# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require_relative "../../app"

RSpec.describe "PR Analysis Routes" do
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  before(:each) do
    PR_CACHE.clear
  end

  describe "GET /" do
    let(:mock_client) { instance_double(Bells::GitHubClient) }
    let(:mock_pr) do
      OpenStruct.new(
        number: 999,
        title: "Test PR",
        html_url: "https://github.com/DataDog/dd-trace-rb/pull/999",
        user: OpenStruct.new(login: "testuser"),
        head: OpenStruct.new(sha: "abc123"),
        updated_at: Time.now
      )
    end

    before do
      allow(Bells::GitHubClient).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:pull_requests_with_status).and_return({
        prs: [mock_pr], ci_statuses: { 999 => :green }
      })
    end

    it "renders the index page with PR list and CI status" do
      get "/"

      expect(last_response).to be_ok
      expect(last_response.body).to include("bells")
      expect(last_response.body).to include("Analyze Pull Request")
      expect(last_response.body).to include("Open Pull Requests")
      expect(last_response.body).to include("Test PR")
      expect(last_response.body).to include("testuser")
      expect(last_response.body).to include("Green")
    end

    it "filters PRs by author" do
      get "/?author=testuser"

      expect(last_response).to be_ok
      expect(last_response.body).to include("Test PR")
    end

    it "shows no PRs when filtering by unknown author" do
      get "/?author=unknownuser"

      expect(last_response).to be_ok
      expect(last_response.body).not_to include("Test PR")
    end

    context "with BELLS_DEFAULT_AUTHOR set" do
      let(:default_pr) do
        OpenStruct.new(
          number: 100,
          title: "Default User PR",
          html_url: "https://github.com/DataDog/dd-trace-rb/pull/100",
          user: OpenStruct.new(login: "defaultuser"),
          head: OpenStruct.new(sha: "def456"),
          updated_at: Time.now
        )
      end

      before do
        ENV["BELLS_DEFAULT_AUTHOR"] = "defaultuser"
        allow(mock_client).to receive(:pull_requests_with_status).and_return({
          prs: [mock_pr, default_pr], ci_statuses: { 999 => :green, 100 => :green }
        })
      end

      after do
        ENV.delete("BELLS_DEFAULT_AUTHOR")
      end

      it "shows only default author's PRs by default" do
        get "/"

        expect(last_response).to be_ok
        expect(last_response.body).to include("Default User PR")
        expect(last_response.body).not_to include("Test PR")
        expect(last_response.body).to include("(default)")
      end

      it "shows all PRs when show_all=true" do
        get "/?show_all=true"

        expect(last_response).to be_ok
        expect(last_response.body).to include("Default User PR")
        expect(last_response.body).to include("Test PR")
      end

      it "allows filtering by different author" do
        get "/?author=testuser"

        expect(last_response).to be_ok
        expect(last_response.body).to include("Test PR")
        expect(last_response.body).not_to include("Default User PR")
      end
    end
  end

  describe "GET /pr/:number" do
    let(:mock_client) { instance_double(Bells::GitHubClient) }
    let(:mock_pr) { OpenStruct.new(
      title: "Test PR Title",
      user: OpenStruct.new(login: "testuser"),
      head: OpenStruct.new(sha: "abc123")
    ) }
    let(:mock_job_failure) do
      Bells::FailureCategorizer::JobFailure.new(
        job_name: "steep/typecheck",
        job_id: 123,
        category: :type_check,
        url: "https://github.com/example",
        details: nil
      )
    end

    before do
      allow(Bells::GitHubClient).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:pull_request_with_status).and_return({
        pr: mock_pr, ci_status: :failed
      })
      allow(Bells).to receive(:analyze_pr).with(123, anything).and_return(
        categorized_failures: { type_check: [mock_job_failure] },
        meta_failures: nil,
        test_details: { total_failures: 0, unique_tests: 0, flaky_tests: 0, aggregated: [] },
        total_failed_jobs: 1,
        in_progress_jobs: 0,
        passed_jobs: 5,
        auto_restarted: false,
        download_errors: []
      )
    end

    it "analyzes the PR and renders results" do
      get "/pr/123"

      expect(last_response).to be_ok
      expect(last_response.body).to include("PR #123")
      expect(last_response.body).to include("Test PR Title")
      expect(last_response.body).to include("Failed")
      expect(last_response.body).to include("passed")
      expect(last_response.body).to include("failed")
      expect(last_response.body).to include("Type Check")
      expect(last_response.body).to include("steep/typecheck")
    end

    it "shows auto-restart notice when job was restarted" do
      allow(Bells).to receive(:analyze_pr).with(456, anything).and_return(
        categorized_failures: {},
        meta_failures: nil,
        test_details: { total_failures: 0, unique_tests: 0, flaky_tests: 0, aggregated: [] },
        total_failed_jobs: 1,
        in_progress_jobs: 0,
        auto_restarted: true,
        download_errors: []
      )
      allow(mock_client).to receive(:pull_request_with_status).with(456).and_return({
        pr: mock_pr, ci_status: :failed
      })

      get "/pr/456"

      expect(last_response).to be_ok
      expect(last_response.body).to include("Automatically restarted")
      expect(last_response.body).to include(Bells::META_CHECK_JOB_NAME)
    end

    it "displays artifact download errors" do
      allow(Bells).to receive(:analyze_pr).with(789, anything).and_return(
        categorized_failures: {},
        meta_failures: nil,
        test_details: { total_failures: 0, unique_tests: 0, flaky_tests: 0, aggregated: [] },
        total_failed_jobs: 0,
        in_progress_jobs: 0,
        passed_jobs: 5,
        auto_restarted: false,
        download_errors: ["Failed to download artifact junit-test: HTTP 404", "Failed to download artifact results: empty response"]
      )
      allow(mock_client).to receive(:pull_request_with_status).with(789).and_return({
        pr: mock_pr, ci_status: :green
      })

      get "/pr/789"

      expect(last_response).to be_ok
      expect(last_response.body).to include("Artifact Download Errors")
      expect(last_response.body).to include("HTTP 404")
      expect(last_response.body).to include("empty response")
    end
  end

  describe "GET /pr/:number with GitLab failures" do
    let(:mock_client) { instance_double(Bells::GitHubClient) }
    let(:mock_pr) { OpenStruct.new(
      title: "Test PR",
      user: OpenStruct.new(login: "testuser"),
      head: OpenStruct.new(sha: "abc123")
    ) }
    let(:gitlab_failure) do
      Bells::FailureCategorizer::JobFailure.new(
        job_name: "dd-gitlab/validate_supported_configurations_v2_local_file",
        job_id: nil,
        category: :other,
        url: "https://gitlab.ddbuild.io/datadog/apm-reliability/dd-trace-rb/builds/1519662090",
        details: nil
      )
    end
    let(:github_failure) do
      Bells::FailureCategorizer::JobFailure.new(
        job_name: "Ruby 3.3 / build & test (standard) [0]",
        job_id: 456,
        category: :tests,
        url: "https://github.com/DataDog/dd-trace-rb/actions/runs/123/job/456",
        details: nil
      )
    end

    before do
      allow(Bells::GitHubClient).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:pull_request_with_status).and_return({
        pr: mock_pr, ci_status: :failed
      })
      allow(Bells).to receive(:analyze_pr).and_return(
        categorized_failures: { other: [gitlab_failure], tests: [github_failure] },
        meta_failures: nil,
        test_details: { total_failures: 0, unique_tests: 0, flaky_tests: 0, aggregated: [] },
        total_failed_jobs: 2,
        in_progress_jobs: 0,
        passed_jobs: 5,
        auto_restarted: false,
        download_errors: []
      )
    end

    it "renders bells log viewer link for GitLab failures" do
      get "/pr/123"

      expect(last_response).to be_ok
      expect(last_response.body).to include("/gitlab/log/1519662090")
      expect(last_response.body).to include("View @ GitLab")
    end

    it "renders direct link for GitHub failures" do
      get "/pr/123"

      expect(last_response).to be_ok
      # GitHub failure should have View Logs pointing to GitHub, no "View @ GitLab"
      expect(last_response.body).to include("actions/runs/123/job/456")
    end
  end

  describe "GET /gitlab/log/:job_id" do
    let(:mock_gitlab_client) { instance_double(Bells::GitLabClient, available?: true) }

    before do
      allow(Bells::GitLabClient).to receive(:new).and_return(mock_gitlab_client)
    end

    it "renders formatted log" do
      allow(mock_gitlab_client).to receive(:job_log)
        .with("datadog/apm-reliability/dd-trace-rb", 12345)
        .and_return("\e[32;1mGreen bold text\e[0m\nPlain line")

      get "/gitlab/log/12345?project=datadog%2Fapm-reliability%2Fdd-trace-rb"

      expect(last_response).to be_ok
      expect(last_response.body).to include("log-viewer")
      expect(last_response.body).to include("fg-green")
      expect(last_response.body).to include("Plain line")
      expect(last_response.body).to include("View @ GitLab")
    end

    it "sets cache headers for immutable logs" do
      allow(mock_gitlab_client).to receive(:job_log)
        .with("datadog/apm-reliability/dd-trace-rb", 12345)
        .and_return("log content")

      get "/gitlab/log/12345?project=datadog%2Fapm-reliability%2Fdd-trace-rb"

      expect(last_response).to be_ok
      expect(last_response.headers["Cache-Control"]).to include("max-age=604800")
    end

    it "returns 404 when log not found" do
      allow(mock_gitlab_client).to receive(:job_log)
        .with("datadog/apm-reliability/dd-trace-rb", 99999)
        .and_return(nil)

      get "/gitlab/log/99999?project=datadog%2Fapm-reliability%2Fdd-trace-rb"

      expect(last_response.status).to eq(404)
    end

    it "returns 503 when gitlab token not configured" do
      allow(mock_gitlab_client).to receive(:available?).and_return(false)

      get "/gitlab/log/12345?project=datadog%2Fapm-reliability%2Fdd-trace-rb"

      expect(last_response.status).to eq(503)
    end
  end

  describe "GET /api/pr/:number" do
    let(:mock_job_failure) do
      Bells::FailureCategorizer::JobFailure.new(
        job_name: "rubocop/lint",
        job_id: 456,
        category: :lint,
        url: "https://github.com/example",
        details: nil
      )
    end

    before do
      allow(Bells).to receive(:analyze_pr).and_return(
        categorized_failures: { lint: [mock_job_failure] },
        meta_failures: nil,
        test_details: { total_failures: 2, unique_tests: 2, flaky_tests: 0, aggregated: [] },
        total_failed_jobs: 1,
        in_progress_jobs: 0,
        passed_jobs: 5,
        auto_restarted: false,
        download_errors: []
      )
    end

    it "returns JSON response" do
      get "/api/pr/456"

      expect(last_response).to be_ok
      expect(last_response.content_type).to include("application/json")

      json = JSON.parse(last_response.body)
      expect(json["pr_number"]).to eq(456)
      expect(json["total_failed_jobs"]).to eq(1)
      expect(json["auto_restarted"]).to eq(false)
      expect(json["categorized_failures"]).to have_key("lint")
    end
  end
end
