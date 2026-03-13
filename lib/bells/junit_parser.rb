# frozen_string_literal: true

require "nokogiri"

module Bells
  class JunitParser
    TestResult = Struct.new(
      :test_class,
      :test_name,
      :status,          # :passed or :failed
      :failure_message,
      :stack_trace,
      :execution_time,
      :build_context,
      keyword_init: true
    )

    # Alias for backwards compatibility
    TestFailure = TestResult

    BuildContext = Struct.new(
      :workflow_name,
      :job_name,
      :run_id,
      :attempt,
      :file_path,
      keyword_init: true
    )

    def parse_file(path, build_context: nil)
      doc = Nokogiri::XML(File.read(path))
      parse_document(doc, build_context: build_context)
    end

    def parse_string(xml, build_context: nil)
      doc = Nokogiri::XML(xml)
      parse_document(doc, build_context: build_context)
    end

    def parse_directory(dir_path, build_context: nil)
      Dir.glob(File.join(dir_path, "**/*.xml")).flat_map do |file|
        parse_file(file, build_context: build_context || context_from_path(file))
      end
    end

    private

    def parse_document(doc, build_context:)
      results = []

      doc.xpath("//testcase").each do |testcase|
        failure_node = testcase.at_xpath("failure") || testcase.at_xpath("error")
        status = failure_node ? :failed : :passed

        results << TestResult.new(
          test_class: testcase["classname"],
          test_name: testcase["name"],
          status: status,
          failure_message: failure_node&.[]("message"),
          stack_trace: failure_node&.text&.strip,
          execution_time: testcase["time"]&.to_f,
          build_context: build_context
        )
      end

      results
    end

    def context_from_path(path)
      BuildContext.new(file_path: path)
    end
  end
end
