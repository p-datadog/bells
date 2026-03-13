# frozen_string_literal: true

require "spec_helper"

RSpec.describe Bells::FailureAggregator do
  subject(:aggregator) { described_class.new }

  let(:failed_result_1) do
    Bells::JunitParser::TestResult.new(
      test_class: "UserTest",
      test_name: "test_email",
      status: :failed,
      failure_message: "Expected true",
      build_context: Bells::JunitParser::BuildContext.new(run_id: 100)
    )
  end

  let(:failed_result_2) do
    Bells::JunitParser::TestResult.new(
      test_class: "UserTest",
      test_name: "test_email",
      status: :failed,
      failure_message: "Expected true",
      build_context: Bells::JunitParser::BuildContext.new(run_id: 101)
    )
  end

  let(:passed_result_1) do
    Bells::JunitParser::TestResult.new(
      test_class: "UserTest",
      test_name: "test_email",
      status: :passed,
      build_context: Bells::JunitParser::BuildContext.new(run_id: 102)
    )
  end

  let(:failed_result_3) do
    Bells::JunitParser::TestResult.new(
      test_class: "OrderTest",
      test_name: "test_total",
      status: :failed,
      failure_message: "Wrong total",
      build_context: Bells::JunitParser::BuildContext.new(run_id: 100)
    )
  end

  let(:passed_result_2) do
    Bells::JunitParser::TestResult.new(
      test_class: "ProductTest",
      test_name: "test_price",
      status: :passed,
      build_context: Bells::JunitParser::BuildContext.new(run_id: 100)
    )
  end

  describe "#aggregate" do
    it "groups test results by test identity" do
      aggregated = aggregator.aggregate([failed_result_1, failed_result_2, failed_result_3, passed_result_2])

      expect(aggregated.size).to eq(2) # UserTest and OrderTest (ProductTest had no failures)
    end

    it "only includes tests that have at least one failure" do
      aggregated = aggregator.aggregate([failed_result_1, passed_result_2])

      expect(aggregated.size).to eq(1)
      expect(aggregated.first.test_class).to eq("UserTest")
    end

    it "counts failures and passes separately" do
      aggregated = aggregator.aggregate([failed_result_1, failed_result_2, passed_result_1])
      user_test = aggregated.find { |a| a.test_class == "UserTest" }

      expect(user_test.failure_count).to eq(2)
      expect(user_test.pass_count).to eq(1)
    end

    it "preserves all instances (both passes and failures)" do
      aggregated = aggregator.aggregate([failed_result_1, passed_result_1, failed_result_2])
      user_test = aggregated.first

      expect(user_test.instances.size).to eq(3)
      expect(user_test.instances.map { |i| i.build_context.run_id }).to eq([100, 102, 101])
    end

    it "sorts by failure count descending" do
      aggregated = aggregator.aggregate([failed_result_1, failed_result_2, failed_result_3])

      expect(aggregated.first.test_class).to eq("UserTest")
      expect(aggregated.first.failure_count).to eq(2)
    end

    it "marks truly flaky tests (both passed and failed)" do
      aggregated = aggregator.aggregate([failed_result_1, passed_result_1, failed_result_3])
      user_test = aggregated.find { |a| a.test_class == "UserTest" }
      order_test = aggregated.find { |a| a.test_class == "OrderTest" }

      expect(user_test).to be_flaky  # Has both pass and fail
      expect(order_test).not_to be_flaky  # Only has failures
    end

    it "does not mark consistently failing tests as flaky" do
      aggregated = aggregator.aggregate([failed_result_1, failed_result_2, failed_result_3])
      user_test = aggregated.find { |a| a.test_class == "UserTest" }

      expect(user_test).not_to be_flaky  # Failed twice, never passed
      expect(user_test.failure_count).to eq(2)
      expect(user_test.pass_count).to eq(0)
    end
  end

  describe "#summary" do
    it "returns summary statistics" do
      summary = aggregator.summary([failed_result_1, failed_result_2, failed_result_3, passed_result_2])

      expect(summary[:total_failures]).to eq(3)
      expect(summary[:unique_tests]).to eq(2)
      expect(summary[:flaky_tests]).to eq(0) # None are truly flaky (no mixed pass/fail)
      expect(summary[:aggregated]).to be_an(Array)
    end

    it "correctly counts flaky tests" do
      summary = aggregator.summary([failed_result_1, passed_result_1, failed_result_3])

      expect(summary[:total_failures]).to eq(2)
      expect(summary[:unique_tests]).to eq(2)
      expect(summary[:flaky_tests]).to eq(1) # UserTest has both pass and fail
    end
  end
end
