# frozen_string_literal: true

require "spec_helper"
require "ostruct"

RSpec.describe Bells do
  describe ".analyze_pr" do
    let(:mock_client) { instance_double(Bells::GitHubClient) }
    let(:mock_parser) { instance_double(Bells::JunitParser) }
    let(:mock_aggregator) { instance_double(Bells::FailureAggregator) }
    let(:mock_categorizer) { instance_double(Bells::FailureCategorizer) }
    let(:mock_pr) { OpenStruct.new(head: OpenStruct.new(sha: "abc123")) }

    before do
      allow(Bells::GitHubClient).to receive(:new).and_return(mock_client)
      allow(Bells::JunitParser).to receive(:new).and_return(mock_parser)
      allow(Bells::FailureAggregator).to receive(:new).and_return(mock_aggregator)
      allow(Bells::FailureCategorizer).to receive(:new).and_return(mock_categorizer)

      allow(mock_client).to receive(:pull_request).and_return(mock_pr)
      allow(mock_client).to receive(:check_runs_for_pr).and_return([])
      allow(mock_client).to receive(:failed_jobs_for_pr).and_return([])
      allow(mock_client).to receive(:in_progress_jobs_for_pr).and_return([])
      allow(mock_client).to receive(:commit_statuses_for_pr).and_return([])
      allow(mock_client).to receive(:download_junit_artifacts).and_return({
        artifact_dirs: [],
        errors: []
      })
      allow(mock_parser).to receive(:parse_directory).and_return([])
      allow(mock_parser).to receive(:parse_directory_failures_only).and_return([])
      allow(mock_parser).to receive(:parse_directory_for_tests).and_return([])
      allow(mock_aggregator).to receive(:summary).and_return(
        total_failures: 0,
        unique_tests: 0,
        flaky_tests: 0,
        aggregated: []
      )

      # Default mocking for categorize_statuses (returns empty array)
      allow(mock_categorizer).to receive(:categorize_statuses).and_return([])

      # Clean up cache files
      FileUtils.rm_rf("tmp/test_cache")
    end

    after do
      FileUtils.rm_rf("tmp/test_cache")
    end

    context "when all-jobs-are-green is the only failure" do
      let(:meta_job) do
        OpenStruct.new(
          name: Bells::META_CHECK_JOB_NAME,
          id: 12345,
          status: "completed",
          conclusion: "failure"
        )
      end
      let(:meta_job_failure) do
        Bells::FailureCategorizer::JobFailure.new(
          job_name: Bells::META_CHECK_JOB_NAME,
          job_id: 12345,
          category: :meta,
          url: "https://github.com/example",
          details: nil
        )
      end

      before do
        # Add completed jobs with "success" conclusion to check_runs
        completed_job = OpenStruct.new(
          name: "Other Job",
          id: 99999,
          status: "completed",
          conclusion: "success"
        )
        # Mock check_runs_for_pr to return all jobs (failed + completed)
        allow(mock_client).to receive(:check_runs_for_pr).and_return([meta_job, completed_job])
        allow(mock_client).to receive(:failed_jobs_for_pr).and_return([meta_job])
        allow(mock_categorizer).to receive(:categorize_jobs).and_return([meta_job_failure])
        allow(mock_categorizer).to receive(:group_by_category).and_return({
          meta: [meta_job_failure]
        })
        allow(mock_client).to receive(:restart_job).with(12345).and_return(true)
      end

      it "automatically restarts the job" do
        expect(mock_client).to receive(:restart_job).with(12345)

        result = described_class.analyze_pr(123, cache_dir: "tmp/test_cache")

        expect(result[:auto_restarted]).to eq(true)
        expect(result[:total_failed_jobs]).to eq(1)
        expect(result[:passed_jobs]).to eq(1)

        # Give the background thread time to execute
        sleep 0.1
      end

      it "keeps meta-check in categorized failures when it's the only failure" do
        result = described_class.analyze_pr(123, cache_dir: "tmp/test_cache")

        expect(result[:categorized_failures]).to have_key(:meta)
        expect(result[:categorized_failures][:meta].size).to eq(1)
        expect(result[:meta_failures]).to be_nil
      end
    end

    context "when all-jobs-are-green is not the only failure" do
      let(:meta_job) do
        OpenStruct.new(
          name: Bells::META_CHECK_JOB_NAME,
          id: 12345,
          status: "completed",
          conclusion: "failure"
        )
      end
      let(:other_job) do
        OpenStruct.new(
          name: "rubocop/lint",
          id: 67890,
          status: "completed",
          conclusion: "failure"
        )
      end
      let(:meta_job_failure) do
        Bells::FailureCategorizer::JobFailure.new(
          job_name: Bells::META_CHECK_JOB_NAME,
          job_id: 12345,
          category: :meta,
          url: "https://github.com/example",
          details: nil
        )
      end
      let(:lint_job_failure) do
        Bells::FailureCategorizer::JobFailure.new(
          job_name: "rubocop/lint",
          job_id: 67890,
          category: :lint,
          url: "https://github.com/example",
          details: nil
        )
      end

      before do
        allow(mock_client).to receive(:check_runs_for_pr).and_return([meta_job, other_job])
        allow(mock_client).to receive(:failed_jobs_for_pr).and_return([meta_job, other_job])
        allow(mock_categorizer).to receive(:categorize_jobs).and_return([meta_job_failure, lint_job_failure])
        allow(mock_categorizer).to receive(:group_by_category).and_return({
          meta: [meta_job_failure],
          lint: [lint_job_failure]
        })
      end

      it "does not restart the job" do
        expect(mock_client).not_to receive(:restart_job)

        result = described_class.analyze_pr(123, cache_dir: "tmp/test_cache")

        expect(result[:auto_restarted]).to eq(false)
        expect(result[:total_failed_jobs]).to eq(2)
      end

      it "moves meta-check to meta_failures when there are other failures" do
        result = described_class.analyze_pr(123, cache_dir: "tmp/test_cache")

        expect(result[:categorized_failures]).not_to have_key(:meta)
        expect(result[:categorized_failures]).to have_key(:lint)
        expect(result[:categorized_failures][:lint].size).to eq(1)
        expect(result[:meta_failures]).to eq([meta_job_failure])
      end
    end

    context "when other jobs fail" do
      let(:other_job) do
        OpenStruct.new(
          name: "rubocop/lint",
          id: 67890,
          status: "completed",
          conclusion: "failure"
        )
      end

      before do
        allow(mock_client).to receive(:check_runs_for_pr).and_return([other_job])
        allow(mock_client).to receive(:failed_jobs_for_pr).and_return([other_job])
        allow(mock_categorizer).to receive(:categorize_jobs).and_return([])
        allow(mock_categorizer).to receive(:group_by_category).and_return({})
      end

      it "does not restart any job" do
        expect(mock_client).not_to receive(:restart_job)

        result = described_class.analyze_pr(123, cache_dir: "tmp/test_cache")

        expect(result[:auto_restarted]).to eq(false)
        expect(result[:total_failed_jobs]).to eq(1)
      end
    end

    context "when loading from cache" do
      let(:test_result) do
        Bells::JunitParser::TestResult.new(
          test_class: "MyTest",
          test_name: "test_something",
          status: :failed,
          failure_message: "Expected true",
          stack_trace: "backtrace",
          execution_time: 0.1,
          build_context: Bells::JunitParser::BuildContext.new(
            workflow_name: "CI",
            job_name: "test",
            run_id: 123,
            attempt: 1,
            file_path: "/tmp/test.xml"
          )
        )
      end

      let(:aggregated_failure) do
        Bells::FailureAggregator::AggregatedFailure.new(
          test_class: "MyTest",
          test_name: "test_something",
          failure_count: 1,
          pass_count: 0,
          instances: [test_result]
        )
      end

      before do
        allow(mock_client).to receive(:check_runs_for_pr).and_return([])
        allow(mock_client).to receive(:failed_jobs_for_pr).and_return([])
        allow(mock_categorizer).to receive(:categorize_jobs).and_return([])
        allow(mock_categorizer).to receive(:group_by_category).and_return({})
        allow(mock_aggregator).to receive(:summary).and_return(
          total_failures: 1,
          unique_tests: 1,
          flaky_tests: 0,
          aggregated: [aggregated_failure]
        )

        # First call to populate cache
        described_class.analyze_pr(456, cache_dir: "tmp/test_cache")
      end

      it "deserializes AggregatedFailure structs correctly" do
        # Second call loads from cache
        result = described_class.analyze_pr(456, cache_dir: "tmp/test_cache")

        expect(result[:test_details][:aggregated]).to be_an(Array)
        expect(result[:test_details][:aggregated].size).to eq(1)

        failure = result[:test_details][:aggregated].first
        expect(failure).to be_a(Bells::FailureAggregator::AggregatedFailure)
        expect(failure.test_class).to eq("MyTest")
        expect(failure.test_name).to eq("test_something")
        expect(failure.failure_count).to eq(1)
        expect(failure.pass_count).to eq(0)
        expect(failure.flaky?).to eq(false)
      end

      it "deserializes TestResult instances correctly" do
        result = described_class.analyze_pr(456, cache_dir: "tmp/test_cache")

        failure = result[:test_details][:aggregated].first
        expect(failure.instances).to be_an(Array)
        expect(failure.instances.size).to eq(1)

        instance = failure.instances.first
        expect(instance).to be_a(Bells::JunitParser::TestResult)
        expect(instance.test_class).to eq("MyTest")
        expect(instance.test_name).to eq("test_something")
        expect(instance.status).to eq(:failed)
        expect(instance.failure_message).to eq("Expected true")
        expect(instance.stack_trace).to eq("backtrace")
        expect(instance.execution_time).to eq(0.1)
      end

      it "deserializes BuildContext correctly" do
        result = described_class.analyze_pr(456, cache_dir: "tmp/test_cache")

        instance = result[:test_details][:aggregated].first.instances.first
        expect(instance.build_context).to be_a(Bells::JunitParser::BuildContext)
        expect(instance.build_context.workflow_name).to eq("CI")
        expect(instance.build_context.job_name).to eq("test")
        expect(instance.build_context.run_id).to eq(123)
        expect(instance.build_context.attempt).to eq(1)
        expect(instance.build_context.file_path).to eq("/tmp/test.xml")
      end
    end
  end
end
