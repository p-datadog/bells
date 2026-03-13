# frozen_string_literal: true

require "spec_helper"
require "ostruct"

RSpec.describe Bells do
  describe ".analyze_pr" do
    let(:mock_client) { instance_double(Bells::GitHubClient) }
    let(:mock_parser) { instance_double(Bells::JunitParser) }
    let(:mock_aggregator) { instance_double(Bells::FailureAggregator) }
    let(:mock_categorizer) { instance_double(Bells::FailureCategorizer) }

    before do
      allow(Bells::GitHubClient).to receive(:new).and_return(mock_client)
      allow(Bells::JunitParser).to receive(:new).and_return(mock_parser)
      allow(Bells::FailureAggregator).to receive(:new).and_return(mock_aggregator)
      allow(Bells::FailureCategorizer).to receive(:new).and_return(mock_categorizer)

      allow(mock_client).to receive(:download_junit_artifacts).and_return({
        artifact_dirs: [],
        errors: []
      })
      allow(mock_parser).to receive(:parse_directory).and_return([])
      allow(mock_aggregator).to receive(:summary).and_return(
        total_failures: 0,
        unique_tests: 0,
        flaky_tests: 0,
        aggregated: []
      )
    end

    context "when all-jobs-are-green is the only failure" do
      let(:meta_job) do
        OpenStruct.new(
          name: Bells::META_CHECK_JOB_NAME,
          id: 12345
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
        allow(mock_client).to receive(:failed_jobs_for_pr).with(123).and_return([meta_job])
        allow(mock_categorizer).to receive(:categorize_jobs).and_return([meta_job_failure])
        allow(mock_categorizer).to receive(:group_by_category).and_return({
          meta: [meta_job_failure]
        })
        allow(mock_client).to receive(:restart_job).with(12345).and_return(true)
      end

      it "automatically restarts the job" do
        expect(mock_client).to receive(:restart_job).with(12345)

        result = described_class.analyze_pr(123)

        expect(result[:auto_restarted]).to eq(true)
        expect(result[:total_failed_jobs]).to eq(1)

        # Give the background thread time to execute
        sleep 0.1
      end

      it "keeps meta-check in categorized failures when it's the only failure" do
        result = described_class.analyze_pr(123)

        expect(result[:categorized_failures]).to have_key(:meta)
        expect(result[:categorized_failures][:meta].size).to eq(1)
        expect(result[:meta_failures]).to be_nil
      end
    end

    context "when all-jobs-are-green is not the only failure" do
      let(:meta_job) do
        OpenStruct.new(
          name: Bells::META_CHECK_JOB_NAME,
          id: 12345
        )
      end
      let(:other_job) do
        OpenStruct.new(
          name: "rubocop/lint",
          id: 67890
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
        allow(mock_client).to receive(:failed_jobs_for_pr).with(123).and_return([meta_job, other_job])
        allow(mock_categorizer).to receive(:categorize_jobs).and_return([meta_job_failure, lint_job_failure])
        allow(mock_categorizer).to receive(:group_by_category).and_return({
          meta: [meta_job_failure],
          lint: [lint_job_failure]
        })
      end

      it "does not restart the job" do
        expect(mock_client).not_to receive(:restart_job)

        result = described_class.analyze_pr(123)

        expect(result[:auto_restarted]).to eq(false)
        expect(result[:total_failed_jobs]).to eq(2)
      end

      it "moves meta-check to meta_failures when there are other failures" do
        result = described_class.analyze_pr(123)

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
          id: 67890
        )
      end

      before do
        allow(mock_client).to receive(:failed_jobs_for_pr).with(123).and_return([other_job])
        allow(mock_categorizer).to receive(:categorize_jobs).and_return([])
        allow(mock_categorizer).to receive(:group_by_category).and_return({})
      end

      it "does not restart any job" do
        expect(mock_client).not_to receive(:restart_job)

        result = described_class.analyze_pr(123)

        expect(result[:auto_restarted]).to eq(false)
        expect(result[:total_failed_jobs]).to eq(1)
      end
    end
  end
end
