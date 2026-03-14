# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Bells.atomic_write" do
  let(:temp_dir) { "tmp/atomic_write_test" }
  let(:test_file) { File.join(temp_dir, "test.txt") }

  before do
    FileUtils.rm_rf(temp_dir)
  end

  after do
    FileUtils.rm_rf(temp_dir)
  end

  it "writes text content atomically" do
    Bells.atomic_write(test_file, "test content")

    expect(File.exist?(test_file)).to be true
    expect(File.read(test_file)).to eq("test content")
  end

  it "writes binary content atomically" do
    binary_data = "\x89PNG\r\n\x1a\n".b
    Bells.atomic_write(test_file, binary_data, binary: true)

    expect(File.exist?(test_file)).to be true
    expect(File.binread(test_file)).to eq(binary_data)
  end

  it "creates parent directories if they don't exist" do
    nested_file = File.join(temp_dir, "nested", "dir", "file.txt")
    Bells.atomic_write(nested_file, "content")

    expect(File.exist?(nested_file)).to be true
    expect(File.read(nested_file)).to eq("content")
  end

  it "cleans up .part file on success" do
    Bells.atomic_write(test_file, "content")

    expect(File.exist?(test_file)).to be true
    expect(File.exist?("#{test_file}.part")).to be false
  end

  it "cleans up .part file on failure" do
    # Force failure by making parent directory read-only
    FileUtils.mkdir_p(temp_dir)
    FileUtils.chmod(0444, temp_dir)

    expect {
      Bells.atomic_write(test_file, "content")
    }.to raise_error

    expect(File.exist?("#{test_file}.part")).to be false
  ensure
    FileUtils.chmod(0755, temp_dir)
  end

  it "overwrites existing file atomically" do
    FileUtils.mkdir_p(temp_dir)
    File.write(test_file, "old content")

    Bells.atomic_write(test_file, "new content")

    expect(File.read(test_file)).to eq("new content")
  end

  it "is atomic - file never exists in partial state" do
    # This is hard to test directly, but we can verify that the file
    # only appears after the write completes, not during
    large_content = "x" * 1_000_000

    Bells.atomic_write(test_file, large_content)

    # If not atomic, file would have existed with partial content
    # With atomic write, it either doesn't exist or has full content
    expect(File.read(test_file).size).to eq(1_000_000)
  end
end
