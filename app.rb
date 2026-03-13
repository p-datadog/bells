# frozen_string_literal: true

require "sinatra"
require "json"
require_relative "lib/bells"

set :public_folder, File.join(__dir__, "public")
set :views, File.join(__dir__, "views")

configure :test do
  set :permitted_hosts, []
end

get "/" do
  client = Bells::GitHubClient.new
  all_prs = client.pull_requests

  default_author = ENV["BELLS_DEFAULT_AUTHOR"]
  show_all = params[:show_all] == "true"

  @authors = all_prs.map { |pr| pr.user.login }.uniq.sort
  @default_author = default_author
  @author_filter = params[:author] || (default_author unless show_all)

  @pull_requests = @author_filter ? all_prs.select { |pr| pr.user.login == @author_filter } : all_prs
  @ci_status = @pull_requests.to_h { |pr| [pr.number, client.ci_status(pr.head.sha)] }
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
