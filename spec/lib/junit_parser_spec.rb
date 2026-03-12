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

    it "extracts failures from junit xml" do
      failures = parser.parse_string(junit_xml)

      expect(failures.size).to eq(2)
    end

    it "parses failure details" do
      failures = parser.parse_string(junit_xml)
      failure = failures.find { |f| f.test_name == "test_valid_email" }

      expect(failure.test_class).to eq("UserTest")
      expect(failure.failure_message).to eq("Expected true but got false")
      expect(failure.stack_trace).to include("test/user_test.rb:10")
      expect(failure.execution_time).to eq(0.123)
    end

    it "parses errors as failures" do
      failures = parser.parse_string(junit_xml)
      error = failures.find { |f| f.test_name == "test_password" }

      expect(error.test_class).to eq("UserTest")
      expect(error.failure_message).to eq("NoMethodError")
    end

    it "attaches build context when provided" do
      context = Bells::JunitParser::BuildContext.new(run_id: 123, job_name: "test-ruby-3.2")
      failures = parser.parse_string(junit_xml, build_context: context)

      expect(failures.first.build_context.run_id).to eq(123)
      expect(failures.first.build_context.job_name).to eq("test-ruby-3.2")
    end
  end

  describe "#parse_file" do
    let(:fixture_path) { "spec/fixtures/junit_samples/sample.xml" }

    before do
      FileUtils.mkdir_p(File.dirname(fixture_path))
      File.write(fixture_path, <<~XML)
        <?xml version="1.0"?>
        <testsuite>
          <testcase classname="SampleTest" name="test_one" time="0.1">
            <failure message="fail">stack</failure>
          </testcase>
        </testsuite>
      XML
    end

    it "parses file from path" do
      failures = parser.parse_file(fixture_path)

      expect(failures.size).to eq(1)
      expect(failures.first.test_class).to eq("SampleTest")
    end
  end
end
