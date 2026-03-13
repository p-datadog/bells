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
      job = mock_job("steep/typecheck")
      result = categorizer.categorize_job(job)
      expect(result.category).to eq(:type_check)
    end

    it "categorizes lint jobs" do
      %w[rubocop/lint standard/lint actionlint yaml-lint lint/frozen_string_literal].each do |name|
        job = mock_job(name)
        result = categorizer.categorize_job(job)
        expect(result.category).to eq(:lint), "Expected #{name} to be :lint"
      end
    end

    it "categorizes security jobs" do
      job = mock_job("CodeQL")
      result = categorizer.categorize_job(job)
      expect(result.category).to eq(:security)
    end

    it "categorizes test jobs" do
      test_names = [
        "Ruby 3.3 / build & test (standard) [0]",
        "JRuby 9.4 / build & test (misc) [0]",
        "test / parametric / parametric (3)",
        "test / End-to-end #10 / rails42 10"
      ]

      test_names.each do |name|
        job = mock_job(name)
        result = categorizer.categorize_job(job)
        expect(result.category).to eq(:tests), "Expected #{name} to be :tests"
      end
    end

    it "categorizes build jobs" do
      job = mock_job("build")
      result = categorizer.categorize_job(job)
      expect(result.category).to eq(:build)
    end

    it "marks unknown jobs as uncategorized" do
      job = mock_job("some-random-job")
      result = categorizer.categorize_job(job)
      expect(result.category).to eq(:uncategorized)
    end

    it "includes job details in result" do
      job = mock_job("steep/typecheck")
      result = categorizer.categorize_job(job)

      expect(result.job_name).to eq("steep/typecheck")
      expect(result.job_id).to eq(123)
      expect(result.url).to eq("https://github.com/example")
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
