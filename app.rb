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
  erb :index
end

get "/pr/:number" do
  @pr_number = params[:number].to_i
  @results = Bells.analyze_pr(@pr_number)
  erb :pr_analysis
end

get "/api/pr/:number" do
  content_type :json
  pr_number = params[:number].to_i
  results = Bells.analyze_pr(pr_number)

  {
    pr_number: pr_number,
    total_failures: results[:total_failures],
    unique_tests: results[:unique_tests],
    flaky_tests: results[:flaky_tests],
    failures: results[:aggregated].map do |f|
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
  }.to_json
end
