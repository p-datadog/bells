# frozen_string_literal: true

require "spec_helper"

RSpec.describe Bells::GitLabClient do
  describe ".parse_target_url" do
    it "parses a build URL" do
      url = "https://gitlab.ddbuild.io/datadog/apm-reliability/dd-trace-rb/builds/1519662090"
      result = described_class.parse_target_url(url)

      expect(result).to eq(
        type: :build,
        hostname: "gitlab.ddbuild.io",
        project_path: "datadog/apm-reliability/dd-trace-rb",
        id: 1519662090
      )
    end

    it "parses a pipeline URL" do
      url = "https://gitlab.ddbuild.io/datadog/apm-reliability/dd-trace-rb/-/pipelines/103388579"
      result = described_class.parse_target_url(url)

      expect(result).to eq(
        type: :pipeline,
        hostname: "gitlab.ddbuild.io",
        project_path: "datadog/apm-reliability/dd-trace-rb",
        id: 103388579
      )
    end

    it "returns nil for non-GitLab URLs" do
      expect(described_class.parse_target_url("https://github.com/foo/bar")).to be_nil
    end

    it "returns nil for nil" do
      expect(described_class.parse_target_url(nil)).to be_nil
    end

    it "handles different hostnames" do
      url = "https://gitlab.example.com/group/project/builds/123"
      result = described_class.parse_target_url(url)

      expect(result[:hostname]).to eq("gitlab.example.com")
      expect(result[:project_path]).to eq("group/project")
    end
  end

  describe "#available?" do
    it "returns true when token is set" do
      client = described_class.new(token: "test-token")
      expect(client).to be_available
    end

    it "returns false when no token is available" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("GITLAB_TOKEN").and_return(nil)
      allow(Open3).to receive(:capture2).and_return(["", double(success?: false)])

      client = described_class.new
      expect(client).not_to be_available
    end
  end

  describe "#job_log" do
    let(:client) { described_class.new(token: "test-token", hostname: "gitlab.ddbuild.io") }
    let(:project_path) { "datadog/apm-reliability/dd-trace-rb" }
    let(:job_id) { 1519662090 }
    let(:encoded_project) { "datadog%2Fapm-reliability%2Fdd-trace-rb" }

    it "fetches and caches job log" do
      stub_request(:get, "https://gitlab.ddbuild.io/api/v4/projects/#{encoded_project}/jobs/#{job_id}/trace")
        .with(headers: { "PRIVATE-TOKEN" => "test-token" })
        .to_return(status: 200, body: "Job log output\nline 2\n")

      Dir.mktmpdir do |tmpdir|
        log = client.job_log(project_path, job_id, cache_dir: tmpdir)
        expect(log).to eq("Job log output\nline 2\n")

        # Second call should hit cache
        log2 = client.job_log(project_path, job_id, cache_dir: tmpdir)
        expect(log2).to eq("Job log output\nline 2\n")
      end

      # Only one HTTP request should have been made
      expect(WebMock).to have_requested(:get,
        "https://gitlab.ddbuild.io/api/v4/projects/#{encoded_project}/jobs/#{job_id}/trace").once
    end

    it "returns nil on HTTP failure" do
      stub_request(:get, "https://gitlab.ddbuild.io/api/v4/projects/#{encoded_project}/jobs/#{job_id}/trace")
        .to_return(status: 404, body: "Not Found")

      Dir.mktmpdir do |tmpdir|
        log = client.job_log(project_path, job_id, cache_dir: tmpdir)
        expect(log).to be_nil
      end
    end
  end

  describe "#job_details" do
    let(:client) { described_class.new(token: "test-token", hostname: "gitlab.ddbuild.io") }
    let(:project_path) { "datadog/apm-reliability/dd-trace-rb" }
    let(:encoded_project) { "datadog%2Fapm-reliability%2Fdd-trace-rb" }

    it "fetches job details" do
      job_data = { id: 123, name: "test-job", status: "failed", failure_reason: "script_failure" }
      stub_request(:get, "https://gitlab.ddbuild.io/api/v4/projects/#{encoded_project}/jobs/123")
        .to_return(status: 200, body: job_data.to_json)

      details = client.job_details(project_path, 123)
      expect(details[:name]).to eq("test-job")
      expect(details[:failure_reason]).to eq("script_failure")
    end
  end

  describe "#pipeline_jobs" do
    let(:client) { described_class.new(token: "test-token", hostname: "gitlab.ddbuild.io") }
    let(:project_path) { "datadog/apm-reliability/dd-trace-rb" }
    let(:encoded_project) { "datadog%2Fapm-reliability%2Fdd-trace-rb" }

    it "paginates through all jobs" do
      page1 = Array.new(100) { |i| { id: i, name: "job-#{i}" } }
      page2 = [{ id: 100, name: "job-100" }, { id: 101, name: "job-101" }]

      stub_request(:get, "https://gitlab.ddbuild.io/api/v4/projects/#{encoded_project}/pipelines/999/jobs")
        .with(query: { "per_page" => "100", "page" => "1" })
        .to_return(status: 200, body: page1.to_json)
      stub_request(:get, "https://gitlab.ddbuild.io/api/v4/projects/#{encoded_project}/pipelines/999/jobs")
        .with(query: { "per_page" => "100", "page" => "2" })
        .to_return(status: 200, body: page2.to_json)

      jobs = client.pipeline_jobs(project_path, 999)
      expect(jobs.size).to eq(102)
    end

    it "handles empty pipeline" do
      stub_request(:get, "https://gitlab.ddbuild.io/api/v4/projects/#{encoded_project}/pipelines/999/jobs")
        .with(query: { "per_page" => "100", "page" => "1" })
        .to_return(status: 200, body: "[]")

      jobs = client.pipeline_jobs(project_path, 999)
      expect(jobs).to be_empty
    end
  end
end
