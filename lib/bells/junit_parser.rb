# frozen_string_literal: true

require "nokogiri"
require "set"
require "find"

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
      doc = Nokogiri::XML(File.read(path)) do |config|
        config.nonet.noent.noblanks
      end
      parse_document(doc, build_context: build_context)
    end

    def parse_string(xml, build_context: nil)
      doc = Nokogiri::XML(xml) do |config|
        config.nonet.noent.noblanks
      end
      parse_document(doc, build_context: build_context)
    end

    def parse_directory(dir_path, build_context: nil)
      find_xml_files(dir_path).flat_map do |file|
        parse_file(file, build_context: build_context || context_from_path(file))
      end
    end

    def parse_directory_failures_only(dir_path, build_context: nil)
      find_xml_files(dir_path).flat_map do |file|
        parse_file_failures_only(file, build_context: build_context || context_from_path(file))
      end
    end

    def parse_directory_for_tests(dir_path, test_ids, build_context: nil)
      find_xml_files(dir_path).flat_map do |file|
        parse_file_for_tests(file, test_ids, build_context: build_context || context_from_path(file))
      end
    end

    private

    # Find XML files without using glob (safer - no metacharacter expansion)
    def find_xml_files(dir_path)
      xml_files = []
      Find.find(dir_path) do |path|
        xml_files << path if File.file?(path) && path.end_with?(".xml")
      end
      xml_files
    rescue Errno::ENOENT
      # Directory doesn't exist
      []
    end

    def parse_file_failures_only(path, build_context: nil)
      doc = Nokogiri::XML(File.read(path)) do |config|
        config.nonet.noent.noblanks
      end
      parse_document_failures_only(doc, build_context: build_context)
    end

    def parse_file_for_tests(path, test_ids, build_context: nil)
      doc = Nokogiri::XML(File.read(path)) do |config|
        config.nonet.noent.noblanks
      end
      parse_document_for_tests(doc, test_ids, build_context: build_context)
    end

    def parse_document(doc, build_context:)
      results = []

      doc.xpath("//testcase").each do |testcase|
        results << build_test_result(testcase, build_context)
      end

      results
    end

    def parse_document_failures_only(doc, build_context:)
      results = []

      doc.xpath("//testcase[failure or error]").each do |testcase|
        results << build_test_result(testcase, build_context)
      end

      results
    end

    def parse_document_for_tests(doc, test_ids, build_context:)
      results = []
      test_id_set = test_ids.to_set

      doc.xpath("//testcase").each do |testcase|
        test_id = "#{testcase['classname']}##{testcase['name']}"
        next unless test_id_set.include?(test_id)

        results << build_test_result(testcase, build_context)
      end

      results
    end

    def build_test_result(testcase, build_context)
      failure_node = testcase.at_xpath("failure") || testcase.at_xpath("error")
      status = failure_node ? :failed : :passed

      TestResult.new(
        test_class: testcase["classname"],
        test_name: testcase["name"],
        status: status,
        failure_message: failure_node&.[]("message"),
        stack_trace: failure_node&.text&.strip,
        execution_time: testcase["time"]&.to_f,
        build_context: build_context
      )
    end

    def context_from_path(path)
      BuildContext.new(file_path: path)
    end
  end
end
