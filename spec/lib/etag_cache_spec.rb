# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/bells/etag_cache"

RSpec.describe Bells::ETagCache do
  subject(:cache) { described_class.new }

  describe "#fetch" do
    it "stores data with ETag on first fetch" do
      result = cache.fetch("test_key") do |cached_etag|
        expect(cached_etag).to be_nil
        { data: "test_data", etag: "etag123", not_modified: false }
      end

      expect(result).to eq("test_data")
    end

    it "provides cached ETag on subsequent fetches" do
      # First fetch
      cache.fetch("test_key") do |_|
        { data: "test_data", etag: "etag123", not_modified: false }
      end

      # Second fetch
      result = cache.fetch("test_key") do |cached_etag|
        expect(cached_etag).to eq("etag123")
        { data: "test_data", etag: "etag123", not_modified: false }
      end

      expect(result).to eq("test_data")
    end

    it "returns cached data when not_modified is true" do
      # First fetch
      cache.fetch("test_key") do |_|
        { data: "original_data", etag: "etag123", not_modified: false }
      end

      # Second fetch with 304 response
      result = cache.fetch("test_key") do |cached_etag|
        expect(cached_etag).to eq("etag123")
        { data: nil, etag: "etag123", not_modified: true }
      end

      expect(result).to eq("original_data")
    end

    it "updates data when new ETag is received" do
      # First fetch
      cache.fetch("test_key") do |_|
        { data: "original_data", etag: "etag123", not_modified: false }
      end

      # Second fetch with new data
      result = cache.fetch("test_key") do |cached_etag|
        expect(cached_etag).to eq("etag123")
        { data: "new_data", etag: "etag456", not_modified: false }
      end

      expect(result).to eq("new_data")

      # Third fetch should have new ETag
      cache.fetch("test_key") do |cached_etag|
        expect(cached_etag).to eq("etag456")
        { data: "new_data", etag: "etag456", not_modified: true }
      end
    end

    it "is thread-safe" do
      threads = 10.times.map do |i|
        Thread.new do
          cache.fetch("thread_key_#{i % 3}") do |_|
            sleep(rand * 0.01) # Small random delay
            { data: "data_#{i}", etag: "etag_#{i}", not_modified: false }
          end
        end
      end

      results = threads.map(&:value)
      expect(results.size).to eq(10)
    end
  end

  describe "#stale?" do
    it "returns true when key not in cache" do
      expect(cache.stale?("nonexistent")).to be true
    end

    it "returns false when key exists in cache" do
      cache.fetch("test_key") do |_|
        { data: "test_data", etag: "etag123", not_modified: false }
      end

      expect(cache.stale?("test_key")).to be false
    end
  end

  describe "#invalidate" do
    it "removes cache entry" do
      cache.fetch("test_key") do |_|
        { data: "test_data", etag: "etag123", not_modified: false }
      end

      cache.invalidate("test_key")

      expect(cache.stale?("test_key")).to be true
    end
  end

  describe "#clear" do
    it "removes all cache entries" do
      cache.fetch("key1") { |_| { data: "data1", etag: "etag1", not_modified: false } }
      cache.fetch("key2") { |_| { data: "data2", etag: "etag2", not_modified: false } }

      cache.clear

      expect(cache.stale?("key1")).to be true
      expect(cache.stale?("key2")).to be true
    end
  end
end
