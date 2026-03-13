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
    end
  end
end
