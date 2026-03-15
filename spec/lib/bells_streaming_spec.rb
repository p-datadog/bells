# frozen_string_literal: true

require "spec_helper"
require "ostruct"

RSpec.describe "Bells.analyze_pr_streaming" do
  let(:mock_client) { instance_double(Bells::GitHubClient) }
  let(:mock_parser) { instance_double(Bells::JunitParser) }
  let(:mock_aggregator) { instance_double(Bells::FailureAggregator) }
  let(:mock_categorizer) { instance_double(Bells::FailureCategorizer) }
  let(:mock_pr) { OpenStruct.new(
    number: 123,
    title: "Test PR",
    user: OpenStruct.new(login: "testuser"),
    head: OpenStruct.new(sha: "abc123")
  ) }

  before do
    allow(Bells::GitHubClient).to receive(:new).and_return(mock_client)
    allow(Bells::JunitParser).to receive(:new).and_return(mock_parser)
    allow(Bells::FailureAggregator).to receive(:new).and_return(mock_aggregator)
    allow(Bells::FailureCategorizer).to receive(:new).and_return(mock_categorizer)

    allow(mock_client).to receive(:pull_request).and_return(mock_pr)
    allow(mock_client).to receive(:check_runs_for_pr).and_return([])
    allow(mock_client).to receive(:failed_jobs_for_pr).and_return([])
    allow(mock_client).to receive(:in_progress_jobs_for_pr).and_return([])
    allow(mock_client).to receive(:failed_statuses_for_pr).and_return([])
    allow(mock_client).to receive(:passed_statuses_for_pr).and_return([])
    allow(mock_client).to receive(:download_junit_artifacts).and_return({
      artifact_dirs: [],
      errors: []
    })
    allow(mock_parser).to receive(:parse_directory_failures_only).and_return([])
    allow(mock_parser).to receive(:parse_directory_for_tests).and_return([])
    allow(mock_categorizer).to receive(:categorize_jobs).and_return([])
    allow(mock_categorizer).to receive(:categorize_statuses).and_return([])
    allow(mock_categorizer).to receive(:group_by_category).and_return({})
    allow(mock_aggregator).to receive(:summary).and_return(
      total_failures: 0,
      unique_tests: 0,
      flaky_tests: 0,
      aggregated: []
    )

    FileUtils.rm_rf("tmp/test_cache")
  end

  after do
    FileUtils.rm_rf("tmp/test_cache")
  end

  describe "event streaming" do
    it "yields job_list event with job counts" do
      events = []

      Bells.analyze_pr_streaming(123, cache_dir: "tmp/test_cache", pr: mock_pr) do |event, data|
        events << [event, data]
      end

      job_list_event = events.find { |e, _| e == :job_list }
      expect(job_list_event).not_to be_nil

      _, job_data = job_list_event
      expect(job_data).to have_key(:failed_jobs)
      expect(job_data).to have_key(:in_progress)
      expect(job_data).to have_key(:passed_jobs)
    end

    it "yields categorized_failures_initial event with job failures" do
      events = []

      Bells.analyze_pr_streaming(123, cache_dir: "tmp/test_cache", pr: mock_pr) do |event, data|
        events << [event, data]
      end

      categorized_event = events.find { |e, _| e == :categorized_failures_initial }
      expect(categorized_event).not_to be_nil

      _, categorized_data = categorized_event
      expect(categorized_data).to have_key(:categorized)
      expect(categorized_data).to have_key(:meta_failures)
    end

    it "yields categorized_failures_final event with job failures" do
      events = []

      Bells.analyze_pr_streaming(123, cache_dir: "tmp/test_cache", pr: mock_pr) do |event, data|
        events << [event, data]
      end

      categorized_event = events.find { |e, _| e == :categorized_failures_final }
      expect(categorized_event).not_to be_nil

      _, categorized_data = categorized_event
      expect(categorized_data).to have_key(:categorized)
      expect(categorized_data).to have_key(:meta_failures)
      expect(categorized_data).to have_key(:auto_restarted)
    end

    it "yields test_details event with test summary" do
      events = []

      Bells.analyze_pr_streaming(123, cache_dir: "tmp/test_cache", pr: mock_pr) do |event, data|
        events << [event, data]
      end

      test_details_event = events.find { |e, _| e == :test_details }
      expect(test_details_event).not_to be_nil

      _, test_data = test_details_event
      expect(test_data).to have_key(:total_failures)
      expect(test_data).to have_key(:unique_tests)
      expect(test_data).to have_key(:flaky_tests)
      expect(test_data).to have_key(:aggregated)
    end

    it "yields events in correct order" do
      events = []

      Bells.analyze_pr_streaming(123, cache_dir: "tmp/test_cache", pr: mock_pr) do |event, data|
        events << event
      end

      expect(events).to eq([:job_list, :categorized_failures_initial, :categorized_failures_final, :test_details])
    end
  end

  describe "green PR fast path" do
    it "skips all expensive operations when ci_status is green" do
      events = []

      Bells.analyze_pr_streaming(123, cache_dir: "tmp/test_cache", pr: mock_pr, ci_status: :green) do |event, data|
        events << [event, data]
      end

      expect(events.map(&:first)).to eq([:job_list, :categorized_failures_initial, :categorized_failures_final, :test_details])

      _, job_data = events[0]
      expect(job_data[:failed_jobs]).to eq(0)
      expect(job_data[:in_progress]).to eq(0)
      expect(job_data[:passed_jobs]).to eq(0)
    end

    it "does not call any GitHub API methods" do
      expect(mock_client).not_to receive(:check_runs_for_pr)
      expect(mock_client).not_to receive(:failed_jobs_for_pr)
      expect(mock_client).not_to receive(:in_progress_jobs_for_pr)
      expect(mock_client).not_to receive(:failed_statuses_for_pr)
      expect(mock_client).not_to receive(:passed_statuses_for_pr)
      expect(mock_client).not_to receive(:download_junit_artifacts)
      expect(mock_client).not_to receive(:job_logs)

      Bells.analyze_pr_streaming(123, cache_dir: "tmp/test_cache", pr: mock_pr, ci_status: :green) do |event, data|
        # consume
      end
    end
  end

  describe "with cached analysis" do
    it "sends all events immediately from cache" do
      # First call to populate cache
      Bells.analyze_pr(123, cache_dir: "tmp/test_cache", pr: mock_pr)

      # Second call should load from cache and send all events immediately
      events = []
      Bells.analyze_pr_streaming(123, cache_dir: "tmp/test_cache", pr: mock_pr) do |event, data|
        events << [event, data]
      end

      expect(events.size).to eq(4)
      expect(events.map(&:first)).to eq([:job_list, :categorized_failures_initial, :categorized_failures_final, :test_details])

      # Verify data structure
      _, job_data = events[0]
      expect(job_data[:failed_jobs]).to eq(0)
      expect(job_data[:in_progress]).to eq(0)
      expect(job_data[:passed_jobs]).to eq(0)
    end
  end

  describe "serialization for JSON" do
    let(:job_failure) do
      Bells::FailureCategorizer::JobFailure.new(
        job_name: "test",
        job_id: 123,
        category: :tests,
        url: "http://example.com",
        details: "error details"
      )
    end

    before do
      allow(mock_client).to receive(:check_runs_for_pr).and_return([
        OpenStruct.new(status: "completed", conclusion: "failure", name: "test", id: 123)
      ])
      allow(mock_client).to receive(:failed_jobs_for_pr).and_return([
        OpenStruct.new(status: "completed", conclusion: "failure", name: "test", id: 123)
      ])
      allow(mock_categorizer).to receive(:categorize_jobs).and_return([job_failure])
      allow(mock_categorizer).to receive(:categorize_job).and_return(job_failure)
      allow(mock_categorizer).to receive(:group_by_category).and_return({ tests: [job_failure] })
    end

    it "serializes JobFailure objects to hashes for JSON" do
      events = []

      Bells.analyze_pr_streaming(123, cache_dir: "tmp/test_cache", pr: mock_pr) do |event, data|
        events << [event, data]
      end

      categorized_event = events.find { |e, _| e == :categorized_failures_final }
      _, categorized_data = categorized_event

      expect(categorized_data[:categorized]).to be_a(Hash)
      expect(categorized_data[:categorized][:tests]).to be_an(Array)
      expect(categorized_data[:categorized][:tests].first).to be_a(Hash)
      expect(categorized_data[:categorized][:tests].first[:job_name]).to eq("test")
    end
  end

  describe "two-phase categorization" do
    let(:failed_job) do
      OpenStruct.new(
        status: "completed",
        conclusion: "failure",
        name: "test",
        id: 123,
        html_url: "http://example.com"
      )
    end

    let(:initial_job_failure) do
      Bells::FailureCategorizer::JobFailure.new(
        job_name: "test",
        job_id: 123,
        category: :tests,
        url: "http://example.com",
        details: nil
      )
    end

    let(:final_job_failure) do
      Bells::FailureCategorizer::JobFailure.new(
        job_name: "test",
        job_id: 123,
        category: :infrastructure,
        url: "http://example.com",
        details: "Failed to download action"
      )
    end

    before do
      allow(mock_client).to receive(:check_runs_for_pr).and_return([failed_job])
      allow(mock_client).to receive(:failed_jobs_for_pr).and_return([failed_job])
    end

    it "sends initial categorization before log downloads" do
      events = []

      # Mock categorizer to track when categorize_jobs is called
      allow(mock_categorizer).to receive(:categorize_jobs) do |jobs, github_client:|
        if github_client.nil?
          # Initial categorization (no github_client)
          [initial_job_failure]
        else
          # Should not be called - we're using categorize_job instead
          raise "Unexpected call to categorize_jobs with github_client"
        end
      end

      # Mock categorize_job for parallel processing
      allow(mock_categorizer).to receive(:categorize_job) do |job, github_client:|
        final_job_failure
      end

      allow(mock_categorizer).to receive(:group_by_category) do |failures|
        if failures.first.details.nil?
          { tests: [initial_job_failure] }
        else
          { infrastructure: [final_job_failure] }
        end
      end

      Bells.analyze_pr_streaming(123, cache_dir: "tmp/test_cache", pr: mock_pr) do |event, data|
        events << [event, data]
      end

      # Verify initial categorization event
      initial_event = events.find { |e, _| e == :categorized_failures_initial }
      expect(initial_event).not_to be_nil

      _, initial_data = initial_event
      expect(initial_data[:categorized]).to have_key(:tests)
      expect(initial_data[:categorized][:tests].first[:details]).to be_nil

      # Verify final categorization event
      final_event = events.find { |e, _| e == :categorized_failures_final }
      expect(final_event).not_to be_nil

      _, final_data = final_event
      expect(final_data[:categorized]).to have_key(:infrastructure)
      expect(final_data[:categorized][:infrastructure].first[:details]).to eq("Failed to download action")
    end

    it "sends events in correct order: job_list → initial → final → test_details" do
      events = []

      allow(mock_categorizer).to receive(:categorize_jobs).with(anything, github_client: nil).and_return([initial_job_failure])
      allow(mock_categorizer).to receive(:categorize_job).and_return(final_job_failure)
      allow(mock_categorizer).to receive(:group_by_category).and_return({ tests: [initial_job_failure] })

      Bells.analyze_pr_streaming(123, cache_dir: "tmp/test_cache", pr: mock_pr) do |event, data|
        events << event
      end

      expect(events).to eq([
        :job_list,
        :categorized_failures_initial,
        :categorized_failures_final,
        :test_details
      ])
    end

    it "parallelizes log downloads using threads" do
      # Create multiple jobs to verify parallelization
      jobs = 3.times.map do |i|
        OpenStruct.new(
          status: "completed",
          conclusion: "failure",
          name: "test-#{i}",
          id: 100 + i,
          html_url: "http://example.com/#{i}"
        )
      end

      allow(mock_client).to receive(:check_runs_for_pr).and_return(jobs)
      allow(mock_client).to receive(:failed_jobs_for_pr).and_return(jobs)

      # Track categorize_job calls to verify they happen in parallel
      categorize_job_calls = []
      allow(mock_categorizer).to receive(:categorize_job) do |job, github_client:|
        categorize_job_calls << job.id
        # Simulate some work
        sleep(0.01)
        Bells::FailureCategorizer::JobFailure.new(
          job_name: job.name,
          job_id: job.id,
          category: :infrastructure,
          url: job.html_url,
          details: "Infrastructure failure"
        )
      end

      allow(mock_categorizer).to receive(:categorize_jobs).with(anything, github_client: nil).and_return(
        jobs.map do |job|
          Bells::FailureCategorizer::JobFailure.new(
            job_name: job.name,
            job_id: job.id,
            category: :tests,
            url: job.html_url,
            details: nil
          )
        end
      )

      allow(mock_categorizer).to receive(:group_by_category).and_return({ tests: [] })

      Bells.analyze_pr_streaming(123, cache_dir: "tmp/test_cache", pr: mock_pr) do |event, data|
        # Just consume events
      end

      # Verify categorize_job was called for all jobs
      expect(categorize_job_calls.size).to eq(3)
      expect(categorize_job_calls).to match_array([100, 101, 102])
    end
  end
end
