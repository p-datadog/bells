# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "ostruct"
require_relative "../../app"

RSpec.describe "Caching integration" do
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  let(:mock_client) { instance_double(Bells::GitHubClient) }
  let(:mock_pr) do
    OpenStruct.new(
      number: 999,
      title: "Test PR",
      html_url: "https://github.com/test",
      user: OpenStruct.new(login: "testuser"),
      head: OpenStruct.new(sha: "abc123"),
      updated_at: Time.now
    )
  end

  before do
    PR_CACHE.clear
    BACKGROUND_REFRESHER.stop
    allow(Bells::GitHubClient).to receive(:new).and_return(mock_client)
    allow(mock_client).to receive(:pull_requests).and_return([mock_pr])
    allow(mock_client).to receive(:ci_status).with("abc123").and_return(:green)
  end

  describe "GET /" do
    it "caches PR list and CI statuses" do
      # First request - cache miss
      get "/"
      expect(last_response).to be_ok
      expect(last_response.body).to include("Test PR")

      # Second request - cache hit
      expect(mock_client).not_to receive(:pull_requests)
      expect(mock_client).not_to receive(:ci_status)

      get "/"
      expect(last_response).to be_ok
      expect(last_response.body).to include("Test PR")
    end

    it "re-fetches after cache expires" do
      # First request
      get "/"

      # Clear mock expectations
      allow(mock_client).to receive(:pull_requests).and_return([mock_pr])
      allow(mock_client).to receive(:ci_status).with("abc123").and_return(:failed)

      # Wait for cache to expire
      PR_CACHE.invalidate("pr_list")

      # Should fetch fresh data
      get "/"
      expect(last_response).to be_ok
      expect(last_response.body).to include("Failed")
    end
  end

  describe "GET /api/ci-status" do
    it "returns CI statuses for requested PRs" do
      allow(mock_client).to receive(:pull_request).with(999).and_return(mock_pr)

      get "/api/ci-status?pr_numbers=999"
      expect(last_response).to be_ok

      json = JSON.parse(last_response.body)
      expect(json).to have_key("999")
      expect(json["999"]).to eq("green")
    end

    it "returns 400 for missing pr_numbers" do
      get "/api/ci-status"
      expect(last_response.status).to eq(400)

      json = JSON.parse(last_response.body)
      expect(json["error"]).to include("Missing pr_numbers")
    end

    it "returns 400 for too many PR numbers" do
      pr_numbers = (1..100).to_a.join(",")
      get "/api/ci-status?pr_numbers=#{pr_numbers}"

      expect(last_response.status).to eq(400)
      json = JSON.parse(last_response.body)
      expect(json["error"]).to include("Too many")
    end

    it "caches individual PR statuses" do
      allow(mock_client).to receive(:pull_request).with(999).and_return(mock_pr)

      get "/api/ci-status?pr_numbers=999"
      expect(last_response).to be_ok

      # Second request should use cache
      expect(mock_client).not_to receive(:pull_request)

      get "/api/ci-status?pr_numbers=999"
      expect(last_response).to be_ok
    end

    it "handles API errors gracefully" do
      allow(mock_client).to receive(:pull_request).with(999).and_raise("API Error")

      get "/api/ci-status?pr_numbers=999"
      expect(last_response).to be_ok

      json = JSON.parse(last_response.body)
      expect(json["999"]).to eq("unknown")
    end

    it "handles not found errors" do
      allow(mock_client).to receive(:pull_request).with(999).and_raise(Octokit::NotFound)

      get "/api/ci-status?pr_numbers=999"
      expect(last_response).to be_ok

      json = JSON.parse(last_response.body)
      expect(json["999"]).to eq("unknown")
    end

    it "handles multiple PR numbers" do
      mock_pr2 = OpenStruct.new(
        number: 888,
        head: OpenStruct.new(sha: "def456")
      )

      allow(mock_client).to receive(:pull_request).with(999).and_return(mock_pr)
      allow(mock_client).to receive(:pull_request).with(888).and_return(mock_pr2)
      allow(mock_client).to receive(:ci_status).with("def456").and_return(:failed)

      get "/api/ci-status?pr_numbers=999,888"
      expect(last_response).to be_ok

      json = JSON.parse(last_response.body)
      expect(json["999"]).to eq("green")
      expect(json["888"]).to eq("failed")
    end
  end

  describe "lazy loading" do
    it "enables lazy load when lazy=true" do
      get "/?lazy=true"
      expect(last_response).to be_ok
      expect(last_response.body).to include("data-ci-status")
      expect(last_response.body).to include("Loading...")
      expect(last_response.body).to include("/api/ci-status")
    end

    it "uses server-side rendering by default" do
      get "/"
      expect(last_response).to be_ok
      expect(last_response.body).not_to include("data-ci-status")
      expect(last_response.body).not_to include("Loading...")
      expect(last_response.body).to include("Green")
    end
  end
end
