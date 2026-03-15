# frozen_string_literal: true

require "spec_helper"
require "ostruct"

RSpec.describe Bells::FailureCategorizer do
  subject(:categorizer) { described_class.new }

  describe "#categorize_job" do
    def mock_job(name)
      OpenStruct.new(name: name, id: 123, html_url: "https://github.com/example")
    end

    it "categorizes meta check job" do
      job = mock_job(Bells::META_CHECK_JOB_NAME)
      result = categorizer.categorize_job(job)
      expect(result.category).to eq(:meta)
    end

    it "categorizes GitLab default-pipeline as meta check" do
      job = mock_job("dd-gitlab/default-pipeline")
      result = categorizer.categorize_job(job)
      expect(result.category).to eq(:meta)
    end

    it "categorizes type check jobs" do
      type_check_names = [
        "steep/typecheck",
        "steep",
        "type-check",
        "rbs-validation"
      ]

      type_check_names.each do |name|
        job = mock_job(name)
        result = categorizer.categorize_job(job)
        expect(result.category).to eq(:type_check), "Expected #{name} to be :type_check"
      end
    end

    it "categorizes lint jobs" do
      %w[rubocop/lint standard/lint actionlint yaml-lint lint/frozen_string_literal].each do |name|
        job = mock_job(name)
        result = categorizer.categorize_job(job)
        expect(result.category).to eq(:lint), "Expected #{name} to be :lint"
      end
    end

    it "categorizes security jobs" do
      security_names = [
        "CodeQL",
        "security-scan"
      ]

      security_names.each do |name|
        job = mock_job(name)
        result = categorizer.categorize_job(job)
        expect(result.category).to eq(:security), "Expected #{name} to be :security"
      end
    end

    it "categorizes test jobs" do
      test_names = [
        "Ruby 3.3 / build & test (standard) [0]",
        "JRuby 9.4 / build & test (misc) [0]",
        "test / parametric / parametric (3)",
        "test / End-to-end #10 / rails42 10",
        "Ruby 2.6 / batch",
        "Ruby 3.2 / batch",
        "JRuby 9.4 / batch",
        "unit-test-batch",
        "rspec-batch-runner"
      ]

      test_names.each do |name|
        job = mock_job(name)
        result = categorizer.categorize_job(job)
        expect(result.category).to eq(:tests), "Expected #{name} to be :tests"
      end
    end

    it "categorizes build jobs" do
      build_names = [
        "build",
        "Build Docker Image",
        "compile-native-extensions",
        "bundle install"
      ]

      build_names.each do |name|
        job = mock_job(name)
        result = categorizer.categorize_job(job)
        expect(result.category).to eq(:build), "Expected #{name} to be :build"
      end
    end

    it "marks unknown jobs as uncategorized" do
      uncategorized_names = [
        "some-random-job",
        "deploy-staging",
        "notify-slack",
        "generate-docs"
      ]

      uncategorized_names.each do |name|
        job = mock_job(name)
        result = categorizer.categorize_job(job)
        expect(result.category).to eq(:uncategorized), "Expected #{name} to be :uncategorized"
      end
    end

    it "includes job details in result" do
      job = mock_job("steep/typecheck")
      result = categorizer.categorize_job(job)

      expect(result.job_name).to eq("steep/typecheck")
      expect(result.job_id).to eq(123)
      expect(result.url).to eq("https://github.com/example")
    end

    context "pattern precedence" do
      it "categorizes meta check with exact match before other patterns" do
        # Meta should match exactly, not be categorized as anything else
        job = mock_job("all-jobs-are-green")
        result = categorizer.categorize_job(job)
        expect(result.category).to eq(:meta)
      end

      it "categorizes semgrep as lint (earlier in list) not security" do
        # semgrep appears in both lint and security patterns
        # lint pattern comes before security, so it should win
        job = mock_job("semgrep")
        result = categorizer.categorize_job(job)
        expect(result.category).to eq(:lint)
      end

      it "categorizes 'build & test' as tests not build" do
        # Contains both "build" and "test", but "build & test" pattern
        # in tests category should match before generic build pattern
        job = mock_job("Ruby 3.3 / build & test (standard) [0]")
        result = categorizer.categorize_job(job)
        expect(result.category).to eq(:tests)
      end
    end

    context "edge cases" do
      it "handles job names with special characters" do
        special_names = [
          "test/integration/redis-5.0",
          "Ruby 3.3 / spec:foo:bar",
          "JRuby 9.4 / test (standard) [10]"
        ]

        special_names.each do |name|
          job = mock_job(name)
          result = categorizer.categorize_job(job)
          expect(result.category).to eq(:tests), "Expected #{name} to be :tests"
        end
      end

      it "handles case-insensitive matching" do
        case_variants = [
          "TEST",
          "Test",
          "BATCH",
          "Batch"
        ]

        case_variants.each do |name|
          job = mock_job(name)
          result = categorizer.categorize_job(job)
          expect(result.category).to eq(:tests), "Expected #{name} to be :tests (case-insensitive)"
        end
      end
    end
  end

  describe "#categorize_status" do
    def mock_status(context)
      OpenStruct.new(context: context, target_url: "https://gitlab.example.com", description: "failed", state: "failure")
    end

    it "categorizes dd-gitlab/default-pipeline as meta check" do
      status = mock_status("dd-gitlab/default-pipeline")
      result = categorizer.categorize_status(status)
      expect(result.category).to eq(:meta)
    end

    it "does not categorize other dd-gitlab statuses as meta" do
      status = mock_status("dd-gitlab/compute_pipeline")
      result = categorizer.categorize_status(status)
      expect(result.category).not_to eq(:meta)
    end
  end

  describe "#categorize_jobs" do
    it "categorizes multiple jobs" do
      jobs = [
        OpenStruct.new(name: "steep/typecheck", id: 1, html_url: "url1"),
        OpenStruct.new(name: "rubocop/lint", id: 2, html_url: "url2")
      ]

      results = categorizer.categorize_jobs(jobs)

      expect(results.size).to eq(2)
      expect(results.map(&:category)).to contain_exactly(:type_check, :lint)
    end
  end

  describe "#group_by_category" do
    it "groups failures by category in order" do
      failures = [
        Bells::FailureCategorizer::JobFailure.new(job_name: "a", category: :tests, job_id: 1, url: "u"),
        Bells::FailureCategorizer::JobFailure.new(job_name: "b", category: :lint, job_id: 2, url: "u"),
        Bells::FailureCategorizer::JobFailure.new(job_name: "c", category: :type_check, job_id: 3, url: "u"),
        Bells::FailureCategorizer::JobFailure.new(job_name: "d", category: :tests, job_id: 4, url: "u")
      ]

      grouped = categorizer.group_by_category(failures)

      expect(grouped.keys).to eq([:tests, :type_check, :lint])
      expect(grouped[:tests].size).to eq(2)
      expect(grouped[:lint].size).to eq(1)
      expect(grouped[:type_check].size).to eq(1)
    end

    it "excludes empty categories" do
      failures = [
        Bells::FailureCategorizer::JobFailure.new(job_name: "a", category: :tests, job_id: 1, url: "u")
      ]

      grouped = categorizer.group_by_category(failures)

      expect(grouped.keys).to eq([:tests])
    end
  end

  describe ".category_label" do
    it "returns human-readable labels" do
      expect(described_class.category_label(:type_check)).to eq("Type Check")
      expect(described_class.category_label(:lint)).to eq("Lint")
      expect(described_class.category_label(:tests)).to eq("Tests")
      expect(described_class.category_label(:uncategorized)).to eq("Uncategorized")
      expect(described_class.category_label(:infrastructure)).to eq("Infrastructure")
    end
  end

  describe "infrastructure failure detection" do
    let(:job) { OpenStruct.new(name: "Ruby 3.4 / build & test", id: 123, html_url: "https://github.com/example") }
    let(:mock_github_client) { double("GitHubClient") }

    context "when logs contain git authentication failures" do
      it "detects 'fatal: could not read Username' as infrastructure failure" do
        logs = <<~LOGS
          2026-03-12T03:07:12.0067589Z ##[group]Run actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
          2026-03-12T03:07:12.7226789Z ##[error]fatal: could not read Username for 'https://github.com': terminal prompts disabled
          2026-03-12T03:07:44.1033938Z ##[error]The process '/usr/bin/git' failed with exit code 128
        LOGS

        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
        expect(result.details).to include("fatal: could not read Username")
      end

      it "detects 'terminal prompts disabled' as infrastructure failure" do
        logs = "fatal: could not read Username for 'https://github.com': terminal prompts disabled"
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
        expect(result.details).to include("terminal prompts disabled")
      end

      it "detects 'Authentication failed' as infrastructure failure" do
        logs = "fatal: Authentication failed for 'https://github.com/DataDog/dd-trace-rb.git/'"
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
      end

      it "detects git exit code 128 as infrastructure failure" do
        logs = "##[error]The process '/usr/bin/git' failed with exit code 128"
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
      end
    end

    context "when logs contain GitHub Actions API failures" do
      it "detects 'Failed to download action' as infrastructure failure" do
        logs = "##[error]Failed to download action 'https://api.github.com/repos/actions/checkout'"
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
      end

      it "detects 401 Unauthorized as infrastructure failure" do
        logs = "Response status code does not indicate success: 401 (Unauthorized)"
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
      end

      it "detects 429 rate limit as infrastructure failure" do
        logs = "Response status code does not indicate success: 429 (Too Many Requests)"
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
      end

      it "detects 5xx server errors as infrastructure failure" do
        logs = "Response status code does not indicate success: 503 (Service Unavailable)"
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
      end
    end

    context "when logs contain runner failures" do
      it "detects runner communication loss as infrastructure failure" do
        logs = "The self-hosted runner: test-runner lost communication with the server"
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
      end

      it "detects unexpected runner termination as infrastructure failure" do
        logs = "runner process unexpectedly terminated"
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
      end
    end

    context "when logs contain network issues" do
      it "detects connection timeouts as infrastructure failure" do
        logs = "Connection timed out after 30 seconds"
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
      end

      it "detects network unreachable as infrastructure failure" do
        logs = "Network is unreachable"
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
      end
    end

    context "when logs contain resource issues" do
      it "detects out of disk space as infrastructure failure" do
        logs = "Error: No space left on device"
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
      end

      it "detects out of memory as infrastructure failure" do
        logs = "Out of memory: Kill process 1234"
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
      end
    end

    context "when logs contain MongoDB/database service failures" do
      it "detects MongoDB NoServerAvailable with dead monitor threads as infrastructure failure" do
        logs = <<~LOGS
          Failures:

            1) Mongo::Client instrumentation with json_command configured to false behaves like with json_command configured to a failed query behaves like a MongoDB trace behaves like analytics for integration when configured by environment variable and explicitly disabled and global flag is explicitly enabled behaves like sample rate value isn't set
               Got 0 failures and 2 other errors:

               1.1) Failure/Error: before { client[collection].drop }
                    Mongo::Error::NoServerAvailable:
                      No primary_preferred server is available in cluster: #<Cluster topology=Unknown[mongodb:27017] servers=[#<Server address=mongodb:27017 UNKNOWN NO-MONITORING>]> with timeout=30, LT=0.015. The following servers have dead monitor threads: #<Server address=mongodb:27017 UNKNOWN NO-MONITORING>

               1.2) Failure/Error: client.database.drop if drop_database?
                    Mongo::Error::NoServerAvailable:
                      No primary_preferred server is available in cluster: #<Cluster topology=Unknown[mongodb:27017] servers=[#<Server address=mongodb:27017 UNKNOWN NO-MONITORING>]> with timeout=30, LT=0.015. The following servers have dead monitor threads: #<Server address=mongodb:27017 UNKNOWN NO-MONITORING>

          911 examples, 1 failure, 1 pending
        LOGS

        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
        expect(result.details).to include("dead monitor threads")
      end

      it "detects MongoDB cluster topology unknown with dead monitoring as infrastructure failure" do
        logs = <<~LOGS
          No primary server is available in cluster: #<Cluster topology=Unknown[mongodb:27017]>
          The following servers have dead monitor threads: #<Server address=mongodb:27017 UNKNOWN NO-MONITORING>
        LOGS

        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
      end

      it "does NOT categorize plain MongoDB connection errors as infrastructure" do
        # Without "dead monitor threads", this is a code issue (connection config, etc.)
        logs = <<~LOGS
          Mongo::Error::NoServerAvailable:
            No server is available matching preference: #<Mongo::ServerSelector::Primary>
        LOGS

        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        # Should fall back to name-based categorization (tests)
        expect(result.category).to eq(:tests)
        expect(result.details).to be_nil
      end
    end

    context "when logs contain code failures" do
      it "does not categorize test failures as infrastructure" do
        logs = <<~LOGS
          Running tests...
          1) Test::MyTest failed
          Expected: true
          Got: false
        LOGS
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:tests)
        expect(result.details).to be_nil
      end

      it "does not categorize build failures as infrastructure" do
        logs = <<~LOGS
          Building project...
          error: undefined method `foo' for nil:NilClass
        LOGS
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:tests)
        expect(result.details).to be_nil
      end
    end

    context "when github_client is not provided" do
      it "categorizes by job name only" do
        result = categorizer.categorize_job(job)

        expect(result.category).to eq(:tests)
        expect(result.details).to be_nil
      end
    end

    context "when log fetching fails" do
      it "falls back to job name categorization" do
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(nil)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:tests)
        expect(result.details).to be_nil
      end
    end

    context "error snippet extraction" do
      it "extracts context around the error" do
        logs = <<~LOGS
          Line 1: Setting up job
          Line 2: Initializing containers
          Line 3: ##[error]fatal: could not read Username for 'https://github.com': terminal prompts disabled
          Line 4: Cleaning up
          Line 5: Complete job
        LOGS
        allow(mock_github_client).to receive(:job_logs).with(123).and_return(logs)

        result = categorizer.categorize_job(job, github_client: mock_github_client)

        expect(result.category).to eq(:infrastructure)
        expect(result.details).to include("Line 1")
        expect(result.details).to include("Line 3")
        expect(result.details).to include("Line 5")
      end
    end
  end
end
