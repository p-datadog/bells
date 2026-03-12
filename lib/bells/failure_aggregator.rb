# frozen_string_literal: true

module Bells
  class FailureAggregator
    AggregatedFailure = Struct.new(
      :test_class,
      :test_name,
      :failure_count,
      :instances,
      keyword_init: true
    ) do
      def test_id
        "#{test_class}##{test_name}"
      end

      def flaky?
        failure_count > 1
      end
    end

    def aggregate(failures)
      grouped = failures.group_by { |f| [f.test_class, f.test_name] }

      grouped.map do |(test_class, test_name), instances|
        AggregatedFailure.new(
          test_class: test_class,
          test_name: test_name,
          failure_count: instances.size,
          instances: instances
        )
      end.sort_by { |f| [-f.failure_count, f.test_id] }
    end

    def summary(failures)
      aggregated = aggregate(failures)
      {
        total_failures: failures.size,
        unique_tests: aggregated.size,
        flaky_tests: aggregated.count(&:flaky?),
        aggregated: aggregated
      }
    end
  end
end
