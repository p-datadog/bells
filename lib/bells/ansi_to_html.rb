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

    # GitLab CI log prefix: timestamp + stream id (e.g. "2026-03-18T21:10:26.489682Z 00O ")
    GITLAB_PREFIX = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z \d{2}[OE]\+? ?/

    # GitLab CI section markers
    SECTION_MARKER = /section_(?:start|end):\d+:\w+(?:\[.*?\])?\r?\n?/

    # ANSI escape sequence — with or without ESC byte
    # GitLab logs use both \e[32;1m (with ESC) and bare [32;1m (without ESC, after [0K])
    ANSI_ESCAPE = /(?:\e)?\[([0-9;]*)m/

    # GitLab uses [0K for line clearing (with optional ESC prefix)
    CLEAR_SEQUENCE = /(?:\e)?\[0K/

    def self.convert(text)
      return "" if text.nil? || text.empty?

      # Strip GitLab-specific noise
      text = text.gsub(GITLAB_PREFIX, "")
      text = text.gsub(SECTION_MARKER, "")
      text = text.gsub(CLEAR_SEQUENCE, "")
      text = text.gsub("\r", "")

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
        else
          # Consume one character of plain text
          char = scanner.getch
          result << escape_html(char)
        end
      end

      open_spans.times { result << "</span>" }
      result
    end

    def self.css
      <<~CSS
        .log-viewer { background: #1e1e1e; color: #d4d4d4; padding: 16px; border-radius: 8px; overflow-x: auto; font-family: 'SF Mono', 'Menlo', 'Monaco', 'Courier New', monospace; font-size: 13px; line-height: 1.5; white-space: pre-wrap; word-wrap: break-word; }
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
