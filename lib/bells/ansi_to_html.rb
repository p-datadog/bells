# frozen_string_literal: true

require "strscan"

module Bells
  module AnsiToHtml
    # Standard ANSI color codes → CSS classes
    COLORS = {
      30 => "black", 31 => "red", 32 => "green", 33 => "yellow",
      34 => "blue", 35 => "magenta", 36 => "cyan", 37 => "white",
      90 => "bright-black", 91 => "bright-red", 92 => "bright-green", 93 => "bright-yellow",
      94 => "bright-blue", 95 => "bright-magenta", 96 => "bright-cyan", 97 => "bright-white"
    }.freeze

    # GitLab Runner log line header (FF_TIMESTAMPS feature flag, Runner 17.0+).
    # Format: "<RFC3339 timestamp> <stream_number><stream_type><line_type>"
    #   - stream_number: 2 hex chars identifying the stream (00 = runner control, 01 = job script)
    #   - stream_type:   O (stdout) or E (stderr)
    #   - line_type:     + if continuation of previous line, absent otherwise
    # Example: "2026-03-18T21:10:26.489682Z 00O " or "2026-03-18T21:10:26.489711Z 01E+"
    # We strip only the stream header, preserving the timestamp for readability.
    # Ref: https://gitlab.com/gitlab-org/gitlab/-/merge_requests/153516
    # Ref: https://gitlab.com/gitlab-org/gitlab-runner/-/issues/36888
    # Ref: https://docs.gitlab.com/ci/jobs/job_logs/#job-log-timestamps
    GITLAB_STREAM_ID = / \d{2}[OE]\+? ?/

    # GitLab CI collapsible section markers in job logs.
    # Format: "section_start:<unix_timestamp>:<name>[options]" / "section_end:..."
    # Ref: https://docs.gitlab.com/ci/jobs/job_logs/#expand-and-collapse-job-log-sections
    SECTION_MARKER = /section_(?:start|end):\d+:\w+(?:\[.*?\])?\r?\n?/

    # ANSI escape sequence — with or without ESC byte
    # GitLab logs use both \e[32;1m (with ESC) and bare [32;1m (without ESC, after [0K])
    ANSI_ESCAPE = /(?:\e)?\[([0-9;]*)m/

    # GitLab uses [0K for line clearing (with optional ESC prefix)
    CLEAR_SEQUENCE = /(?:\e)?\[0K/

    # URLs to autolink
    URL_PATTERN = /https?:\/\/[^\s<>"]+/

    # Patterns for detecting the first error line in log output.
    # Matched against cleaned plain text (ANSI codes stripped), one line at a time.
    # See docs/log-viewer-error-anchoring.md for details on adding patterns.
    ERROR_PATTERNS = [
      /\AError: /,         # Line starts with "Error: " (config validation scripts)
      /Failure\/Error:/,   # RSpec failure marker
    ].freeze

    def self.convert(text)
      return "" if text.nil? || text.empty?

      # Simulate terminal carriage-return overwrite: for each line, keep only the
      # last non-empty segment after all CR overwrites (e.g. curl progress bars).
      text = text.split("\n", -1).map { |line|
        line.split("\r", -1).reject(&:empty?).last || ""
      }.join("\n")

      # Strip GitLab-specific noise
      text = text.gsub(GITLAB_STREAM_ID, " ")
      text = text.gsub(SECTION_MARKER, "")
      text = text.gsub(CLEAR_SEQUENCE, "")

      # Detect first error line for anchor insertion (match against plain text)
      plain_lines = text.gsub(ANSI_ESCAPE, "").split("\n")
      first_error_line = plain_lines.index { |l| ERROR_PATTERNS.any? { |p| l.match?(p) } }

      result = +""
      open_spans = 0

      # Process text by scanning for ANSI sequences
      scanner = StringScanner.new(text)

      until scanner.eos?
        # Try to match an ANSI escape
        if scanner.scan(ANSI_ESCAPE)
          codes = scanner[1].scan(/\d+/).map(&:to_i)

          if codes.include?(0) || codes.empty?
            open_spans.times { result << "</span>" }
            open_spans = 0
          else
            classes = []
            codes.each do |code|
              case code
              when 1 then classes << "bold"
              when 2 then classes << "dim"
              when 3 then classes << "italic"
              when 4 then classes << "underline"
              when 30..37, 90..97
                classes << "fg-#{COLORS[code]}"
              end
            end

            unless classes.empty?
              result << "<span class=\"#{classes.join(' ')}\">"
              open_spans += 1
            end
          end
        elsif (url = scanner.scan(URL_PATTERN))
          escaped = escape_html(url)
          result << "<a href=\"#{escaped}\">#{escaped}</a>"
        else
          # Consume one character of plain text
          char = scanner.getch
          result << escape_html(char)
        end
      end

      open_spans.times { result << "</span>" }

      # Insert anchor at first error line
      if first_error_line
        html_lines = result.split("\n", -1)
        if first_error_line < html_lines.length
          html_lines[first_error_line] = '<a id="first-error"></a>' + html_lines[first_error_line]
        end
        result = html_lines.join("\n")
      end

      result
    end

    def self.css
      <<~CSS
        .log-viewer { background: #1e1e1e; color: #d4d4d4; padding: 16px; border-radius: 8px; overflow-x: auto; font-family: 'SF Mono', 'Menlo', 'Monaco', 'Courier New', monospace; font-size: 12px; line-height: 1.5; white-space: pre-wrap; word-wrap: break-word; }
        .log-viewer .bold { font-weight: bold; }
        .log-viewer .dim { opacity: 0.6; }
        .log-viewer .italic { font-style: italic; }
        .log-viewer .underline { text-decoration: underline; }
        .log-viewer .fg-black { color: #555; }
        .log-viewer .fg-red { color: #f44747; }
        .log-viewer .fg-green { color: #6a9955; }
        .log-viewer .fg-yellow { color: #dcdcaa; }
        .log-viewer .fg-blue { color: #569cd6; }
        .log-viewer .fg-magenta { color: #c586c0; }
        .log-viewer .fg-cyan { color: #4ec9b0; }
        .log-viewer .fg-white { color: #d4d4d4; }
        .log-viewer .fg-bright-black { color: #808080; }
        .log-viewer .fg-bright-red { color: #f14c4c; }
        .log-viewer .fg-bright-green { color: #73c991; }
        .log-viewer .fg-bright-yellow { color: #e5e510; }
        .log-viewer .fg-bright-blue { color: #6cb6ff; }
        .log-viewer .fg-bright-magenta { color: #d670d6; }
        .log-viewer .fg-bright-cyan { color: #9cdcfe; }
        .log-viewer .fg-bright-white { color: #ffffff; }
      CSS
    end

    def self.escape_html(text)
      text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
    end
  end
end
