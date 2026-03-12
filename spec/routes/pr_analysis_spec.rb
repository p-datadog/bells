# frozen_string_literal: true

require "spec_helper"
require_relative "../../app"

RSpec.describe "PR Analysis Routes" do
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  describe "GET /" do
    it "renders the index page" do
      get "/"

      expect(last_response).to be_ok
      expect(last_response.body).to include("bells")
      expect(last_response.body).to include("Analyze Pull Request")
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
