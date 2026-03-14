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
      @monitor.synchronize do
        cached = @cache[key]

        # Yield block with cached ETag if available
        result = yield(cached&.etag)

        # If 304 Not Modified, return cached data
        if result[:not_modified]
          return cached.data
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
