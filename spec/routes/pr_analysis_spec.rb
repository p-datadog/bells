# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require_relative "../../app"

RSpec.describe "PR Analysis Routes" do
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  describe "GET /" do
    let(:mock_client) { instance_double(Bells::GitHubClient) }
    let(:mock_pr) do
      OpenStruct.new(
        number: 999,
        title: "Test PR",
        html_url: "https://github.com/DataDog/dd-trace-rb/pull/999",
        user: OpenStruct.new(login: "testuser"),
        updated_at: Time.now
      )
    end

    before do
      allow(Bells::GitHubClient).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:pull_requests).and_return([mock_pr])
    end

    it "renders the index page with PR list" do
      get "/"

      expect(last_response).to be_ok
      expect(last_response.body).to include("bells")
      expect(last_response.body).to include("Analyze Pull Request")
      expect(last_response.body).to include("Open Pull Requests")
      expect(last_response.body).to include("Test PR")
      expect(last_response.body).to include("testuser")
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
  end

  describe "GET /pr/:number" do
    before do
      allow(Bells).to receive(:analyze_pr).with(123).and_return(
        total_failures: 5,
        unique_tests: 3,
        flaky_tests: 1,
        aggregated: []
      )
    end

    it "analyzes the PR and renders results" do
      get "/pr/123"

      expect(last_response).to be_ok
      expect(last_response.body).to include("PR #123")
      expect(last_response.body).to include("5")
      expect(last_response.body).to include("Total Failures")
    end
  end

  describe "GET /api/pr/:number" do
    before do
      allow(Bells).to receive(:analyze_pr).with(456).and_return(
        total_failures: 2,
        unique_tests: 2,
        flaky_tests: 0,
        aggregated: []
      )
    end

    it "returns JSON response" do
      get "/api/pr/456"

      expect(last_response).to be_ok
      expect(last_response.content_type).to include("application/json")

      json = JSON.parse(last_response.body)
      expect(json["pr_number"]).to eq(456)
      expect(json["total_failures"]).to eq(2)
    end
  end
end
