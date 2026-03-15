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
    allow(mock_client).to receive(:pull_requests_with_status).and_return({
      prs: [mock_pr], ci_statuses: { 999 => :green }
    })
  end

  describe "GET /" do
    it "caches PR list and CI statuses" do
      # First request - cache miss
      get "/"
      expect(last_response).to be_ok
      expect(last_response.body).to include("Test PR")

      # Second request - cache hit
      expect(mock_client).not_to receive(:pull_requests_with_status)

      get "/"
      expect(last_response).to be_ok
      expect(last_response.body).to include("Test PR")
    end

    it "re-fetches after cache expires" do
      # First request
      get "/"

      # Clear mock expectations
      allow(mock_client).to receive(:pull_requests_with_status).and_return({
        prs: [mock_pr], ci_statuses: { 999 => :failed }
      })

      # Wait for cache to expire
      PR_CACHE.invalidate("pr_list")

      # Should fetch fresh data
      get "/"
      expect(last_response).to be_ok
      expect(last_response.body).to include("Failed")
    end
  end

end
