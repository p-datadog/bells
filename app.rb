# frozen_string_literal: true

require "sinatra"
require "json"
require_relative "lib/bells"
require_relative "lib/bells/pr_cache"
require_relative "lib/bells/etag_cache"
require_relative "lib/bells/background_refresher"

set :public_folder, File.join(__dir__, "public")
set :views, File.join(__dir__, "views")

# Enable HTML auto-escaping for XSS protection
set :erb, escape_html: true

# In-memory cache for PR data
PR_CACHE = Bells::PrCache.new

# ETag cache for staleness detection (accessed via GitHubClient::ETAG_CACHE)
# No need to create a separate constant here since GitHubClient has ETAG_CACHE

# Background refresher to keep cache warm
DEFAULT_AUTHOR = ENV["BELLS_DEFAULT_AUTHOR"]
BACKGROUND_REFRESH_ENABLED = ENV["BELLS_BACKGROUND_REFRESH"] != "false"

if BACKGROUND_REFRESH_ENABLED
  BACKGROUND_REFRESHER = Bells::BackgroundRefresher.new(
    PR_CACHE,
    interval: 120,
    default_author: DEFAULT_AUTHOR
  )

  configure :development, :production do
    # Start background refresh on server start
    BACKGROUND_REFRESHER.start
    if DEFAULT_AUTHOR
      puts "Started background PR cache refresher (interval: 2 minutes, pre-warming PRs for #{DEFAULT_AUTHOR})"
    else
      puts "Started background PR cache refresher (interval: 2 minutes)"
    end
  end
else
  puts "Background PR cache refresher disabled (BELLS_BACKGROUND_REFRESH=false)"
  BACKGROUND_REFRESHER = nil
end

configure :test do
  set :permitted_hosts, []
  # Don't start background refresher in tests
end

# Graceful shutdown
at_exit do
  BACKGROUND_REFRESHER&.stop
end

get "/" do
  # Use cached PR data (kept warm by background refresher)
  pr_data = PR_CACHE.fetch("pr_list") do
    Bells::GitHubClient.new.pull_requests_with_status
  end

  all_prs = pr_data[:prs]
  default_author = ENV["BELLS_DEFAULT_AUTHOR"]
  show_all = params[:show_all] == "true"

  @authors = all_prs.map { |pr| pr.user.login }.uniq.sort
  @default_author = default_author
  @author_filter = params[:author] || (default_author unless show_all)
  @pull_requests = @author_filter ? all_prs.select { |pr| pr.user.login == @author_filter } : all_prs
  @ci_status = pr_data[:ci_statuses]

  erb :index
end

get "/pr/:number" do
  start_time = Time.now
  @pr_number = params[:number].to_i

  client = Bells::GitHubClient.new
  puts "[MAIN ROUTE TIMING] #{((Time.now - start_time) * 1000).to_i}ms - GitHubClient initialized"

  # Try cache first (background refresh populates this)
  pr = PR_CACHE.fetch("pr:#{@pr_number}") do
    client.pull_request(@pr_number)
  end
  cache_source = PR_CACHE.fetch("pr:#{@pr_number}") { nil } ? "cache" : "API"
  puts "[MAIN ROUTE TIMING] #{((Time.now - start_time) * 1000).to_i}ms - PR fetched (from #{cache_source})"

  @pr_title = pr.title
  @pr_author = pr.user.login
  @pr_head_sha = pr.head.sha

  # Try to use cached CI status from homepage (background refresh)
  pr_data = PR_CACHE.fetch("pr_list") { nil }
  @ci_status = if pr_data && pr_data[:ci_statuses] && pr_data[:ci_statuses][@pr_number]
    pr_data[:ci_statuses][@pr_number]
  else
    # Fallback: compute CI status (limited to 100 check runs)
    client.ci_status(@pr_head_sha)
  end
  puts "[MAIN ROUTE TIMING] #{((Time.now - start_time) * 1000).to_i}ms - CI status retrieved (#{@ci_status}, from #{pr_data ? 'cache' : 'API'})"

  # Use streaming in development/production, not in tests
  @use_streaming = settings.environment != :test

  # In test mode or if streaming disabled, run full analysis
  unless @use_streaming
    @results = Bells.analyze_pr(@pr_number, pr: pr)
  end

  result = erb :pr_analysis
  puts "[MAIN ROUTE TIMING] #{((Time.now - start_time) * 1000).to_i}ms - Skeleton rendered and sent"
  result
end

get "/pr/:number/stream" do
  pr_number = params[:number].to_i
  ci_status = params[:ci_status]&.to_sym

  # Set SSE headers
  content_type "text/event-stream"
  headers "Cache-Control" => "no-cache",
          "X-Accel-Buffering" => "no" # Disable nginx buffering

  stream(:keep_open) do |out|
    begin
      # Run analysis with progress callbacks
      # Pass ci_status to potentially skip expensive operations
      Bells.analyze_pr_streaming(pr_number, ci_status: ci_status) do |event, data|
        out << "event: #{event}\n"
        out << "data: #{data.to_json}\n\n"
      end

      # Send completion event
      out << "event: complete\n"
      out << "data: {\"status\":\"done\"}\n\n"
    rescue => e
      out << "event: error\n"
      out << "data: #{json(message: e.message)}\n\n"
    ensure
      out.close
    end
  end
end

get "/api/pr/:number" do
  content_type :json
  pr_number = params[:number].to_i
  results = Bells.analyze_pr(pr_number)

  {
    pr_number: pr_number,
    passed_jobs: results[:passed_jobs],
    total_failed_jobs: results[:total_failed_jobs],
    in_progress_jobs: results[:in_progress_jobs],
    auto_restarted: results[:auto_restarted],
    categorized_failures: results[:categorized_failures].transform_values do |failures|
      failures.map { |f| { job_name: f.job_name, job_id: f.job_id, url: f.url } }
    end,
    test_details: {
      total_failures: results[:test_details][:total_failures],
      unique_tests: results[:test_details][:unique_tests],
      flaky_tests: results[:test_details][:flaky_tests],
      failures: results[:test_details][:aggregated].map do |f|
        {
          test_class: f.test_class,
          test_name: f.test_name,
          failure_count: f.failure_count,
          instances: f.instances.map do |i|
            {
              failure_message: i.failure_message,
              stack_trace: i.stack_trace,
              execution_time: i.execution_time,
              build_context: i.build_context&.to_h
            }
          end
        }
      end
    }
  }.to_json
end

post "/pr/:number/restart_category" do
  pr_number = params[:number].to_i
  category = params[:category]&.to_sym

  # Validate
  halt 400, "Invalid category" unless [:infrastructure].include?(category)

  # Get current data
  client = Bells::GitHubClient.new
  results = Bells.analyze_pr(pr_number)

  # Collect jobs to restart
  jobs_to_restart = results[:categorized_failures][category] || []
  jobs_to_restart += (results[:meta_failures] || [])

  # Restart each job
  success_count = 0
  failure_count = 0

  jobs_to_restart.each do |failure|
    if client.restart_job(failure.job_id)
      success_count += 1
    else
      failure_count += 1
    end
  end

  # Redirect with feedback
  redirect "/pr/#{pr_number}?restarted=#{success_count}&failed=#{failure_count}"
end

helpers do
  def json(obj)
    obj.to_json
  end
end
