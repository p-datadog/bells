# frozen_string_literal: true

module Bells
  class BackgroundRefresher
    SHUTDOWN_CHECK_INTERVAL = 10 # seconds

    def initialize(cache, interval: 120)
      @cache = cache
      @interval = interval
      @running = false
      @thread = nil
      @consecutive_failures = 0
      @max_backoff = interval * 5
    end

    def start
      if @running
        warn "Background refresher already running"
        return
      end

      @running = true
      @thread = Thread.new do
        Thread.current.name = "pr-cache-refresher"

        loop do
          break unless @running

          sleep_interval = begin
            refresh_pr_cache
            @consecutive_failures = 0
            @interval
          rescue => e
            warn "Background refresh error: #{e.message}"
            @consecutive_failures += 1
            backoff = [@interval * (2 ** [@consecutive_failures - 1, 3].min), @max_backoff].min
            warn "Backing off for #{backoff}s due to #{@consecutive_failures} consecutive failures"
            backoff
          end

          # Sleep in small increments to allow quick shutdown
          (sleep_interval / SHUTDOWN_CHECK_INTERVAL).times do
            break unless @running
            sleep SHUTDOWN_CHECK_INTERVAL
          end
        end
      end
    end

    def stop
      return unless @running

      @running = false

      if @thread&.alive?
        puts "Waiting for background refresher to finish..."
        joined = @thread.join(10)

        unless joined
          warn "Background refresher did not stop gracefully, forcing shutdown"
          @thread.kill if @thread&.alive?
        end
      end

      @thread = nil
    end

    private

    def refresh_pr_cache
      puts "[#{Time.now}] Background refresh: Fetching PR list and CI statuses..."

      begin
        client = GitHubClient.new
      rescue => e
        warn "[#{Time.now}] Background refresh: Failed to initialize GitHub client: #{e.message}"
        raise
      end

      begin
        prs = client.pull_requests
        ci_statuses = prs.to_h { |pr| [pr.number, client.ci_status(pr.head.sha)] }
      rescue => e
        warn "[#{Time.now}] Background refresh: GitHub API error: #{e.message}"
        raise
      end

      # Use set instead of fetch to avoid race condition
      @cache.set("pr_list", { prs: prs, ci_statuses: ci_statuses }, ttl: @interval * 2)

      puts "[#{Time.now}] Background refresh: Complete (#{prs.size} PRs, #{ci_statuses.size} statuses)"
    end
  end
end
