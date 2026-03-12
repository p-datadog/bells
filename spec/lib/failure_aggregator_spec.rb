# frozen_string_literal: true

require "spec_helper"

RSpec.describe Bells::FailureAggregator do
  subject(:aggregator) { described_class.new }

  let(:failure_1) do
    Bells::JunitParser::TestFailure.new(
      test_class: "UserTest",
      test_name: "test_email",
      failure_message: "Expected true",
      build_context: Bells::JunitParser::BuildContext.new(run_id: 100)
    )
  end

  let(:failure_2) do
    Bells::JunitParser::TestFailure.new(
      test_class: "UserTest",
      test_name: "test_email",
      failure_message: "Expected true",
      build_context: Bells::JunitParser::BuildContext.new(run_id: 101)
    )
  end

  let(:failure_3) do
    Bells::JunitParser::TestFailure.new(
      test_class: "OrderTest",
      test_name: "test_total",
      failure_message: "Wrong total",
      build_context: Bells::JunitParser::BuildContext.new(run_id: 100)
    )
  end

  describe "#aggregate" do
    it "groups failures by test identity" do
      aggregated = aggregator.aggregate([failure_1, failure_2, failure_3])

      expect(aggregated.size).to eq(2)
    end

    it "counts failures per test" do
      aggregated = aggregator.aggregate([failure_1, failure_2, failure_3])
      user_test = aggregated.find { |a| a.test_class == "UserTest" }

      expect(user_test.failure_count).to eq(2)
    end

    it "preserves all instances" do
      aggregated = aggregator.aggregate([failure_1, failure_2])
      user_test = aggregated.first

      expect(user_test.instances.map { |i| i.build_context.run_id }).to eq([100, 101])
    end

    it "sorts by failure count descending" do
      aggregated = aggregator.aggregate([failure_1, failure_2, failure_3])

      expect(aggregated.first.test_class).to eq("UserTest")
      expect(aggregated.first.failure_count).to eq(2)
    end

    it "marks flaky tests" do
      aggregated = aggregator.aggregate([failure_1, failure_2, failure_3])
      user_test = aggregated.find { |a| a.test_class == "UserTest" }
      order_test = aggregated.find { |a| a.test_class == "OrderTest" }

      expect(user_test).to be_flaky
      expect(order_test).not_to be_flaky
    end
  end

  describe "#summary" do
    it "returns summary statistics" do
      summary = aggregator.summary([failure_1, failure_2, failure_3])

      expect(summary[:total_failures]).to eq(3)
      expect(summary[:unique_tests]).to eq(2)
      expect(summary[:flaky_tests]).to eq(1)
      expect(summary[:aggregated]).to be_an(Array)
    end
  end
end
