# frozen_string_literal: true

module Bells
  class FailureAggregator
    AggregatedFailure = Struct.new(
      :test_class,
      :test_name,
      :failure_count,
      :pass_count,
      :instances,
      keyword_init: true
    ) do
      def test_id
        "#{test_class}##{test_name}"
      end

      def flaky?
        # True flakiness: same test both passed and failed
        pass_count > 0 && failure_count > 0
      end
    end

    def aggregate(test_results)
      # Group by test identity
      grouped = test_results.group_by { |r| [r.test_class, r.test_name] }

      # Only include tests that have at least one failure
      grouped.select { |_, instances| instances.any? { |i| i.status == :failed } }.map do |(test_class, test_name), instances|
        failures = instances.select { |i| i.status == :failed }
        passes = instances.select { |i| i.status == :passed }

        AggregatedFailure.new(
          test_class: test_class,
          test_name: test_name,
          failure_count: failures.size,
          pass_count: passes.size,
          instances: instances
        )
      end.sort_by { |f| [-f.failure_count, f.test_id] }
    end

    def summary(test_results)
      aggregated = aggregate(test_results)
      total_failures = test_results.count { |r| r.status == :failed }

      {
        total_failures: total_failures,
        unique_tests: aggregated.size,
        flaky_tests: aggregated.count(&:flaky?),
        aggregated: aggregated
      }
    end
  end
end
