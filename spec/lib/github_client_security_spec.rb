# frozen_string_literal: true

require "spec_helper"
require "zip"

RSpec.describe Bells::GitHubClient, "security" do
  subject(:client) { described_class.new }

  describe "#extract_zip - Zip Slip protection" do
    let(:cache_dir) { "tmp/security_test_cache" }
    let(:malicious_zip) { "tmp/malicious.zip" }

    before do
      FileUtils.mkdir_p(cache_dir)
      FileUtils.mkdir_p("tmp")
    end

    after do
      FileUtils.rm_rf(cache_dir)
      FileUtils.rm_f(malicious_zip)
      FileUtils.rm_f("tmp/escaped.txt")
    end

    it "prevents path traversal attacks in zip files" do
      # Create a malicious zip with path traversal
      Zip::OutputStream.open(malicious_zip) do |zos|
        zos.put_next_entry("../escaped.txt")
        zos.write("pwned")
        zos.put_next_entry("normal.txt")
        zos.write("safe")
      end

      # Suppress warnings during test
      allow(client).to receive(:warn)

      # Extract the zip
      client.send(:extract_zip, malicious_zip, cache_dir)

      # Verify traversal was blocked
      expect(File.exist?("tmp/escaped.txt")).to be false

      # Verify normal file was extracted
      expect(File.exist?(File.join(cache_dir, "normal.txt"))).to be true
    end

    it "handles deeply nested traversal attempts" do
      Zip::OutputStream.open(malicious_zip) do |zos|
        zos.put_next_entry("../../../../../../../../tmp/evil.txt")
        zos.write("evil")
      end

      allow(client).to receive(:warn)
      client.send(:extract_zip, malicious_zip, cache_dir)

      expect(File.exist?("/tmp/evil.txt")).to be false
    end

    it "logs Zip Slip attempts" do
      Zip::OutputStream.open(malicious_zip) do |zos|
        zos.put_next_entry("../escaped.txt")
        zos.write("test")
      end

      expect(client).to receive(:warn).with(/Zip Slip attempt detected/)
      client.send(:extract_zip, malicious_zip, cache_dir)
    end
  end
end
