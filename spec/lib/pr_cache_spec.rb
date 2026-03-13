# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/bells/pr_cache"

RSpec.describe Bells::PrCache do
  let(:cache) { described_class.new }

  describe "#fetch" do
    it "executes block on cache miss" do
      expect { |b| cache.fetch("key", &b) }.to yield_control
    end

    it "returns cached value on cache hit" do
      cache.fetch("key") { "value" }
      expect { |b| cache.fetch("key", &b) }.not_to yield_control
      expect(cache.fetch("key") { "new" }).to eq("value")
    end

    it "respects TTL and re-executes after expiration" do
      cache.fetch("key", ttl: 0.1) { "value1" }
      sleep 0.15
      result = cache.fetch("key") { "value2" }
      expect(result).to eq("value2")
    end

    it "is thread-safe" do
      call_count = 0
      mutex = Mutex.new

      threads = 10.times.map do
        Thread.new do
          cache.fetch("key") do
            mutex.synchronize { call_count += 1 }
            sleep 0.01
            "value"
          end
        end
      end

      threads.each(&:join)
      expect(call_count).to eq(1)
    end

    it "handles exceptions in block" do
      expect {
        cache.fetch("key") { raise "error" }
      }.to raise_error("error")

      # Cache should not store failed result
      expect { |b| cache.fetch("key", &b) }.to yield_control
    end
  end

  describe "#set" do
    it "stores value in cache" do
      cache.set("key", "value")
      expect { |b| cache.fetch("key", &b) }.not_to yield_control
      expect(cache.fetch("key") { "new" }).to eq("value")
    end

    it "respects TTL" do
      cache.set("key", "value", ttl: 0.1)
      sleep 0.15
      expect { |b| cache.fetch("key", &b) }.to yield_control
    end
  end

  describe "#clear" do
    it "removes all cached entries" do
      cache.fetch("key1") { "value1" }
      cache.fetch("key2") { "value2" }
      cache.clear

      expect { |b| cache.fetch("key1", &b) }.to yield_control
      expect { |b| cache.fetch("key2", &b) }.to yield_control
    end
  end

  describe "#invalidate" do
    it "removes specific cache entry" do
      cache.fetch("key1") { "value1" }
      cache.fetch("key2") { "value2" }
      cache.invalidate("key1")

      expect { |b| cache.fetch("key1", &b) }.to yield_control
      expect { |b| cache.fetch("key2", &b) }.not_to yield_control
    end
  end

  describe "memory management" do
    it "evicts old entries when cache grows too large" do
      # Fill cache beyond MAX_CACHE_SIZE
      1100.times { |i| cache.fetch("key#{i}") { "value#{i}" } }

      # Cache should have evicted entries to stay under limit
      cache_size = cache.instance_variable_get(:@cache).size
      expect(cache_size).to be <= described_class::MAX_CACHE_SIZE
    end

    it "uses LRU eviction strategy" do
      # Fill cache to capacity
      1000.times { |i| cache.fetch("key#{i}") { "value#{i}" } }

      # Access first key to make it recently used
      cache.fetch("key0") { "value0" }

      # Add one more to trigger eviction
      cache.fetch("new_key") { "new_value" }

      # key0 should still be cached (recently used)
      expect { |b| cache.fetch("key0", &b) }.not_to yield_control

      # One of the early unused keys should be evicted
      evicted_count = (1..100).count do |i|
        executed = false
        cache.fetch("key#{i}") { executed = true; "value#{i}" }
        executed
      end

      expect(evicted_count).to be > 0
    end

    it "periodically cleans up expired entries" do
      # Create entries that will expire
      50.times { |i| cache.fetch("key#{i}", ttl: 0.01) { "value#{i}" } }

      sleep 0.05

      # Trigger cleanup by accessing cache multiple times
      # (1% chance per access, so ~100 accesses should trigger it)
      allow(cache).to receive(:rand).and_return(0.005) # Force cleanup

      cache.fetch("trigger") { "value" }

      # Expired entries should be cleaned up
      cache_size = cache.instance_variable_get(:@cache).size
      expect(cache_size).to be < 51
    end
  end
end
