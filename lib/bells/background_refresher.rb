# frozen_string_literal: true

module Bells
  class BackgroundRefresher
    SHUTDOWN_CHECK_INTERVAL = 10 # seconds

    def initialize(cache, interval: 120, default_author: nil)
      @cache = cache
      @interval = interval
      @default_author = default_author
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

        # Run first refresh immediately
        begin
          refresh_pr_cache
          @consecutive_failures = 0
        rescue => e
          warn "Background refresh error: #{e.message}"
          @consecutive_failures += 1
        end

        # Then loop: sleep → refresh
        loop do
          break unless @running

          # Calculate sleep interval (use backoff if previous refresh failed)
          sleep_interval = if @consecutive_failures > 0
            backoff = [@interval * (2 ** [@consecutive_failures - 1, 3].min), @max_backoff].min
            backoff
          else
            @interval
          end

          # Sleep in small increments to allow quick shutdown
          (sleep_interval / SHUTDOWN_CHECK_INTERVAL).times do
            break unless @running
            sleep SHUTDOWN_CHECK_INTERVAL
          end

          break unless @running

          # Refresh
          begin
            refresh_pr_cache
            @consecutive_failures = 0
          rescue => e
            warn "Background refresh error: #{e.message}"
            @consecutive_failures += 1
            backoff = [@interval * (2 ** [@consecutive_failures - 1, 3].min), @max_backoff].min
            warn "Backing off for #{backoff}s due to #{@consecutive_failures} consecutive failures"
          end
        end
      end
    end

    def stop
      return unless @running

      @running = false

      if @thread&.alive?
        @thread.kill
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

      # Pre-warm PR analysis for default author's PRs
      if @default_author
        author_prs = prs.select { |pr| pr.user.login == @default_author }

        if author_prs.any?
          puts "[#{Time.now}] Background refresh: Pre-warming #{author_prs.size} PRs for author #{@default_author}..."

          author_prs.each do |pr|
            warm_pr_analysis(pr.number, pr)
          end

          puts "[#{Time.now}] Background refresh: Pre-warming complete for #{@default_author}"
        end
      end
    end

    def warm_pr_analysis(pr_number, pr)
      # Run full analysis to pre-populate cache
      # Errors are caught and logged, but don't fail the entire refresh
      Bells.analyze_pr(pr_number, pr: pr)
      puts "[#{Time.now}]   ✓ Warmed PR ##{pr_number}"
    rescue => e
      warn "[#{Time.now}]   ✗ Failed to warm PR ##{pr_number}: #{e.message}"
      # Don't raise - continue with other PRs
    end
  end
end
