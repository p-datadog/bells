# frozen_string_literal: true

require "spec_helper"

RSpec.describe Bells::JunitParser do
  subject(:parser) { described_class.new }

  describe "#parse_string" do
    let(:junit_xml) do
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuite name="TestSuite" tests="3" failures="1" errors="1">
          <testcase classname="UserTest" name="test_valid_email" time="0.123">
            <failure message="Expected true but got false">
              test/user_test.rb:10:in `test_valid_email'
              Expected: true
              Actual: false
            </failure>
          </testcase>
          <testcase classname="UserTest" name="test_password" time="0.456">
            <error message="NoMethodError">
              undefined method `foo' for nil:NilClass
            </error>
          </testcase>
          <testcase classname="UserTest" name="test_passing" time="0.001"/>
        </testsuite>
      XML
    end

    it "parses all test results from junit xml" do
      results = parser.parse_string(junit_xml)

      expect(results.size).to eq(3)
      expect(results.count { |r| r.status == :failed }).to eq(2)
      expect(results.count { |r| r.status == :passed }).to eq(1)
    end

    it "parses failure details" do
      results = parser.parse_string(junit_xml)
      failure = results.find { |f| f.test_name == "test_valid_email" }

      expect(failure.test_class).to eq("UserTest")
      expect(failure.status).to eq(:failed)
      expect(failure.failure_message).to eq("Expected true but got false")
      expect(failure.stack_trace).to include("test/user_test.rb:10")
      expect(failure.execution_time).to eq(0.123)
    end

    it "parses passing tests" do
      results = parser.parse_string(junit_xml)
      passing = results.find { |r| r.test_name == "test_passing" }

      expect(passing.test_class).to eq("UserTest")
      expect(passing.status).to eq(:passed)
      expect(passing.failure_message).to be_nil
      expect(passing.stack_trace).to be_nil
      expect(passing.execution_time).to eq(0.001)
    end

    it "parses errors as failures" do
      results = parser.parse_string(junit_xml)
      error = results.find { |f| f.test_name == "test_password" }

      expect(error.test_class).to eq("UserTest")
      expect(error.status).to eq(:failed)
      expect(error.failure_message).to eq("NoMethodError")
    end

    it "attaches build context when provided" do
      context = Bells::JunitParser::BuildContext.new(run_id: 123, job_name: "test-ruby-3.2")
      results = parser.parse_string(junit_xml, build_context: context)

      expect(results.first.build_context.run_id).to eq(123)
      expect(results.first.build_context.job_name).to eq("test-ruby-3.2")
    end
  end

  describe "#parse_file" do
    let(:fixture_path) { "spec/fixtures/junit_samples/sample.xml" }

    before do
      FileUtils.mkdir_p(File.dirname(fixture_path))
      File.write(fixture_path, <<~XML)
        <?xml version="1.0"?>
        <testsuite tests="2" failures="1">
          <testcase classname="SampleTest" name="test_one" time="0.1">
            <failure message="fail">stack</failure>
          </testcase>
          <testcase classname="SampleTest" name="test_two" time="0.05"/>
        </testsuite>
      XML
    end

    it "parses file from path" do
      results = parser.parse_file(fixture_path)

      expect(results.size).to eq(2)
      expect(results.count { |r| r.status == :failed }).to eq(1)
      expect(results.count { |r| r.status == :passed }).to eq(1)
      expect(results.first.test_class).to eq("SampleTest")
    end
  end

  describe "two-pass parsing" do
    let(:xml_with_many_tests) do
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuite name="TestSuite" tests="5" failures="2">
          <testcase classname="UserTest" name="test_valid_email" time="0.1">
            <failure message="Expected true">error details</failure>
          </testcase>
          <testcase classname="UserTest" name="test_password" time="0.2"/>
          <testcase classname="UserTest" name="test_username" time="0.1"/>
          <testcase classname="OrderTest" name="test_total" time="0.3">
            <failure message="Wrong total">stack trace</failure>
          </testcase>
          <testcase classname="OrderTest" name="test_items" time="0.1"/>
        </testsuite>
      XML
    end

    describe "#parse_string (failures only)" do
      it "parses only failures" do
        doc = Nokogiri::XML(xml_with_many_tests)
        failures = parser.send(:parse_document_failures_only, doc, build_context: nil)

        expect(failures.size).to eq(2)
        expect(failures.all? { |f| f.status == :failed }).to be true
        expect(failures.map(&:test_name)).to contain_exactly("test_valid_email", "test_total")
      end
    end

    describe "#parse_string (for specific tests)" do
      it "parses all results for specified test IDs only" do
        test_ids = ["UserTest#test_valid_email", "OrderTest#test_total"]
        doc = Nokogiri::XML(xml_with_many_tests)
        results = parser.send(:parse_document_for_tests, doc, test_ids, build_context: nil)

        expect(results.size).to eq(2)
        expect(results.map { |r| "#{r.test_class}##{r.test_name}" }).to contain_exactly(*test_ids)
        expect(results.count { |r| r.status == :failed }).to eq(2)
      end

      it "includes both passes and failures for the same test across files" do
        # This simulates the same test in different jobs
        xml_job1 = <<~XML
          <testsuite>
            <testcase classname="UserTest" name="test_flaky" time="0.1">
              <failure message="Failed">error</failure>
            </testcase>
          </testsuite>
        XML

        xml_job2 = <<~XML
          <testsuite>
            <testcase classname="UserTest" name="test_flaky" time="0.1"/>
          </testsuite>
        XML

        doc1 = Nokogiri::XML(xml_job1)
        doc2 = Nokogiri::XML(xml_job2)
        test_ids = ["UserTest#test_flaky"]

        results1 = parser.send(:parse_document_for_tests, doc1, test_ids, build_context: nil)
        results2 = parser.send(:parse_document_for_tests, doc2, test_ids, build_context: nil)
        all_results = results1 + results2

        expect(all_results.size).to eq(2)
        expect(all_results.count { |r| r.status == :failed }).to eq(1)
        expect(all_results.count { |r| r.status == :passed }).to eq(1)
      end
    end
  end
end
