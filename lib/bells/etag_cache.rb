# frozen_string_literal: true

require "monitor"

module Bells
  class ETagCache
    CachedData = Struct.new(:data, :etag, :created_at, keyword_init: true)

    def initialize
      @cache = {}
      @monitor = Monitor.new
    end

    # Fetch with conditional request support
    # The block should yield a hash with:
    #   { data: ..., etag: ..., not_modified: bool }
    def fetch(key)
      # Step 1: Read cached ETag under lock (fast - <1ms)
      cached_etag = nil
      @monitor.synchronize do
        cached_etag = @cache[key]&.etag
      end

      # Step 2: Do network I/O OUTSIDE lock (slow - 50-500ms)
      result = yield(cached_etag)

      # Step 3: Write result under lock (fast - <1ms)
      @monitor.synchronize do
        # If 304 Not Modified, return cached data
        if result[:not_modified]
          cached = @cache[key]
          return cached ? cached.data : nil
        end

        # Store new data with new ETag
        @cache[key] = CachedData.new(
          data: result[:data],
          etag: result[:etag],
          created_at: Time.now
        )

        result[:data]
      end
    end

    # Check if cache entry doesn't exist (will require fresh fetch)
    def stale?(key)
      @monitor.synchronize do
        !@cache.key?(key)
      end
    end

    # Invalidate a cache entry
    def invalidate(key)
      @monitor.synchronize do
        @cache.delete(key)
      end
    end

    # Clear all cache entries
    def clear
      @monitor.synchronize do
        @cache.clear
      end
    end
  end
end
