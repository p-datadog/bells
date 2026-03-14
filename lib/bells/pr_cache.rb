# frozen_string_literal: true

require "monitor"

module Bells
  class PrCache
    CACHE_TTL = 120 # 2 minutes
    MAX_CACHE_SIZE = 1000

    CachedData = Struct.new(:data, :expires_at, keyword_init: true) do
      def expired?
        Time.now > expires_at
      end
    end

    def initialize
      @cache = {}
      @monitor = Monitor.new
      @access_order = []
      @computing = {}  # Track which keys are being computed
      @key_locks = Hash.new { |h, k| h[k] = Mutex.new }
    end

    def fetch(key, ttl: CACHE_TTL)
      # Quick check without key-specific lock
      @monitor.synchronize do
        cleanup_expired if rand < 0.01 # 1% chance to cleanup

        cached = @cache[key]

        if cached && !cached.expired?
          # Cache hit - update LRU order and return
          @access_order.delete(key)
          @access_order.push(key)
          return cached.data
        end
      end

      # Cache miss - use per-key lock to ensure only one thread computes
      @key_locks[key].synchronize do
        # Double-check cache after acquiring key lock (another thread may have computed it)
        @monitor.synchronize do
          cached = @cache[key]
          if cached && !cached.expired?
            @access_order.delete(key)
            @access_order.push(key)
            return cached.data
          end
        end

        # Compute new value outside cache lock
        data = yield

        # Store result
        @monitor.synchronize do
          set_internal(key, data, ttl)
        end

        data
      end
    end

    def set(key, data, ttl: CACHE_TTL)
      @monitor.synchronize do
        set_internal(key, data, ttl)
      end
    end

    def clear
      @monitor.synchronize do
        @cache.clear
        @access_order.clear
      end
    end

    def invalidate(key)
      @monitor.synchronize do
        @cache.delete(key)
        @access_order.delete(key)
      end
    end

    private

    def set_internal(key, data, ttl)
      @cache[key] = CachedData.new(
        data: data,
        expires_at: Time.now + ttl
      )

      # Update LRU order
      @access_order.delete(key)
      @access_order.push(key)

      # Evict if too large
      evict_lru if @cache.size > MAX_CACHE_SIZE
    end

    def evict_lru
      # Remove oldest 10% of entries
      to_remove = (@cache.size * 0.1).to_i
      to_remove.times do
        oldest_key = @access_order.shift
        @cache.delete(oldest_key) if oldest_key
      end
    end

    def cleanup_expired
      @cache.reject! { |key, cached|
        if cached.expired?
          @access_order.delete(key)
          true
        else
          false
        end
      }
    end
  end
end
