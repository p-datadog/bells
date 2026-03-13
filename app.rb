# frozen_string_literal: true

require "sinatra"
require "json"
require_relative "lib/bells"
require_relative "lib/bells/pr_cache"
require_relative "lib/bells/background_refresher"

set :public_folder, File.join(__dir__, "public")
set :views, File.join(__dir__, "views")

# Enable HTML auto-escaping for XSS protection
set :erb, escape_html: true

# Initialize PR cache (Solution #1: In-memory caching)
PR_CACHE = Bells::PrCache.new

# Solution #3: Background job to pre-fetch PR data
BACKGROUND_REFRESHER = Bells::BackgroundRefresher.new(PR_CACHE, interval: 120)

configure :development, :production do
  # Start background refresh on server start
  BACKGROUND_REFRESHER.start
  puts "Started background PR cache refresher (interval: 2 minutes)"
end

configure :test do
  set :permitted_hosts, []
  # Don't start background refresher in tests
end

# Graceful shutdown
at_exit do
  BACKGROUND_REFRESHER.stop
end

get "/" do
  # Solution #1: Cache PR list and CI statuses for 2 minutes
  pr_data = PR_CACHE.fetch("pr_list") do
    client = Bells::GitHubClient.new
    prs = client.pull_requests

    # Fetch CI status for all PRs
    ci_statuses = prs.to_h { |pr| [pr.number, client.ci_status(pr.head.sha)] }

    { prs: prs, ci_statuses: ci_statuses }
  end

  all_prs = pr_data[:prs]

  default_author = ENV["BELLS_DEFAULT_AUTHOR"]
  show_all = params[:show_all] == "true"

  @authors = all_prs.map { |pr| pr.user.login }.uniq.sort
  @default_author = default_author
  @author_filter = params[:author] || (default_author unless show_all)

  @pull_requests = @author_filter ? all_prs.select { |pr| pr.user.login == @author_filter } : all_prs
  @ci_status = pr_data[:ci_statuses]
  @use_lazy_load = params[:lazy] == "true"

  erb :index
end

get "/pr/:number" do
  @pr_number = params[:number].to_i
  client = Bells::GitHubClient.new
  pr = client.pull_request(@pr_number)
  @pr_title = pr.title
  @ci_status = client.ci_status(pr.head.sha)
  @results = Bells.analyze_pr(@pr_number)
  erb :pr_analysis
end

# Solution #2: API endpoint for lazy-loading CI statuses
get "/api/ci-status" do
  content_type :json

  pr_numbers = params[:pr_numbers]&.split(",")&.map(&:to_i)

  if pr_numbers.nil? || pr_numbers.empty?
    return halt 400, { error: "Missing pr_numbers parameter" }.to_json
  end

  if pr_numbers.size > 50
    return halt 400, { error: "Too many PR numbers (max 50)" }.to_json
  end

  client = Bells::GitHubClient.new

  # Fetch CI status for requested PRs
  statuses = pr_numbers.each_with_object({}) do |pr_number, hash|
    # Use cache to avoid re-fetching
    hash[pr_number] = PR_CACHE.fetch("ci_status:#{pr_number}", ttl: 60) do
      begin
        pr = client.pull_request(pr_number)
        client.ci_status(pr.head.sha).to_s
      rescue Octokit::NotFound
        "unknown"
      rescue => e
        warn "Failed to fetch CI status for PR #{pr_number}: #{e.message}"
        "unknown"
      end
    end
  end

  statuses.to_json
end

get "/api/pr/:number" do
  content_type :json
  pr_number = params[:number].to_i
  results = Bells.analyze_pr(pr_number)

  {
    pr_number: pr_number,
    total_failed_jobs: results[:total_failed_jobs],
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
