# frozen_string_literal: true

require "faraday"
require "json"
require "open3"

module Bells
  class GitLabClient
    # Parse GitLab build/pipeline URLs posted as GitHub commit statuses
    # Build URL:    https://gitlab.ddbuild.io/datadog/apm-reliability/dd-trace-rb/builds/1519662090
    # Pipeline URL: https://gitlab.ddbuild.io/datadog/apm-reliability/dd-trace-rb/-/pipelines/103388579
    BUILD_URL_PATTERN = %r{\Ahttps://([^/]+)/(.+)/builds/(\d+)\z}
    PIPELINE_URL_PATTERN = %r{\Ahttps://([^/]+)/(.+?)/-/pipelines/(\d+)\z}

    def initialize(token: nil, hostname: nil)
      @token = token || ENV["GITLAB_TOKEN"] || fetch_glab_token(hostname)
      @token = nil if @token&.empty?
      @hostname = hostname || "gitlab.ddbuild.io"
      @base_url = "https://#{@hostname}/api/v4"
    end

    def available?
      !@token.nil?
    end

    # Fetch job log (trace) by job ID and project path
    def job_log(project_path, job_id, cache_dir: ".cache")
      cache_path = File.join(cache_dir, "gitlab_logs", "#{job_id}.log")
      return File.read(cache_path) if File.exist?(cache_path)

      encoded_project = URI.encode_www_form_component(project_path)
      response = get("/projects/#{encoded_project}/jobs/#{job_id}/trace")

      if response.success? && response.body && !response.body.empty?
        Bells.atomic_write(cache_path, response.body)
        response.body
      end
    rescue => e
      warn "Failed to fetch GitLab job log #{job_id}: #{e.class}: #{e}"
      warn e.backtrace.first(5).map { |l| "  #{l}" }.join("\n")
      nil
    end

    # Fetch job details by job ID and project path
    def job_details(project_path, job_id)
      encoded_project = URI.encode_www_form_component(project_path)
      response = get("/projects/#{encoded_project}/jobs/#{job_id}")

      if response.success?
        JSON.parse(response.body, symbolize_names: true)
      end
    rescue => e
      warn "Failed to fetch GitLab job details #{job_id}: #{e.class}: #{e}"
      nil
    end

    # Fetch all jobs for a pipeline, with pagination
    def pipeline_jobs(project_path, pipeline_id)
      encoded_project = URI.encode_www_form_component(project_path)
      all_jobs = []
      page = 1

      loop do
        response = get("/projects/#{encoded_project}/pipelines/#{pipeline_id}/jobs",
                       per_page: 100, page: page)
        break unless response.success?

        jobs = JSON.parse(response.body, symbolize_names: true)
        break if jobs.empty?

        all_jobs.concat(jobs)
        break if jobs.size < 100

        page += 1
      end

      all_jobs
    rescue => e
      warn "Failed to fetch GitLab pipeline jobs #{pipeline_id}: #{e.class}: #{e}"
      warn e.backtrace.first(5).map { |l| "  #{l}" }.join("\n")
      []
    end

    # Parse a GitLab target_url from a GitHub commit status into project_path and ID
    # Returns { type: :build, project_path: "...", id: 123 } or nil
    def self.parse_target_url(url)
      return nil unless url

      if (match = url.match(BUILD_URL_PATTERN))
        { type: :build, hostname: match[1], project_path: match[2], id: match[3].to_i }
      elsif (match = url.match(PIPELINE_URL_PATTERN))
        { type: :pipeline, hostname: match[1], project_path: match[2], id: match[3].to_i }
      end
    end

    private

    def get(path, **params)
      conn.get("#{@base_url}#{path}") do |req|
        req.headers["PRIVATE-TOKEN"] = @token if @token
        params.each { |k, v| req.params[k.to_s] = v }
      end
    end

    def conn
      @conn ||= Faraday.new do |f|
        f.response :follow_redirects
      end
    end

    def fetch_glab_token(hostname)
      host = hostname || "gitlab.ddbuild.io"
      stdout, status = Open3.capture2("glab", "auth", "token", "--hostname", host, err: File::NULL)
      status.success? ? stdout.strip : nil
    rescue Errno::ENOENT
      nil
    end
  end
end
