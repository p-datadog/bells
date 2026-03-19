# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/bells/ansi_to_html"

RSpec.describe Bells::AnsiToHtml do
  describe ".convert" do
    it "returns empty string for nil" do
      expect(described_class.convert(nil)).to eq("")
    end

    it "returns empty string for empty string" do
      expect(described_class.convert("")).to eq("")
    end

    it "escapes HTML in plain text" do
      expect(described_class.convert("<script>alert(1)</script>")).to eq("&lt;script&gt;alert(1)&lt;/script&gt;")
    end

    it "converts bold ANSI codes" do
      input = "\e[1mBold text\e[0m"
      result = described_class.convert(input)
      expect(result).to include('<span class="bold">Bold text</span>')
    end

    it "converts color ANSI codes" do
      input = "\e[32mGreen text\e[0m"
      result = described_class.convert(input)
      expect(result).to include('<span class="fg-green">Green text</span>')
    end

    it "converts bold+color combination" do
      input = "\e[32;1mBold green\e[0m"
      result = described_class.convert(input)
      expect(result).to include("fg-green")
      expect(result).to include("bold")
      expect(result).to include("Bold green")
    end

    it "converts bright colors" do
      input = "\e[91mBright red\e[0m"
      result = described_class.convert(input)
      expect(result).to include("fg-bright-red")
    end

    it "strips GitLab timestamp+stream prefixes" do
      input = "2026-03-18T21:10:26.489682Z 00O Running with gitlab-runner"
      result = described_class.convert(input)
      expect(result).not_to include("2026-03-18T21:10:26")
      expect(result).not_to include("00O")
      expect(result).to include("Running with gitlab-runner")
    end

    it "strips GitLab section markers" do
      input = "section_start:1773868226:prepare_executor\nActual content\nsection_end:1773868226:prepare_executor\n"
      result = described_class.convert(input)
      expect(result).not_to include("section_start")
      expect(result).not_to include("section_end")
      expect(result).to include("Actual content")
    end

    it "strips collapsed section markers" do
      input = "section_start:1773868226:prepare_executor[collapsed=true]\nContent"
      result = described_class.convert(input)
      expect(result).not_to include("section_start")
      expect(result).to include("Content")
    end

    it "strips [0K clear sequences" do
      input = "[0KSome text[0;m"
      result = described_class.convert(input)
      expect(result).not_to include("[0K")
      expect(result).to include("Some text")
    end

    it "handles real GitLab log line" do
      input = "2026-03-18T21:10:26.489682Z 00O [0K[0K[36;1mPreparing the \"kubernetes\" executor[0;m[0;m"
      result = described_class.convert(input)
      expect(result).to include("fg-cyan")
      expect(result).to include("bold")
      expect(result).to include("Preparing the")
      expect(result).not_to include("2026-03-18")
    end

    it "closes unclosed spans" do
      input = "\e[31mRed text without reset"
      result = described_class.convert(input)
      expect(result).to include("</span>")
      expect(result.scan("<span").length).to eq(result.scan("</span>").length)
    end

    it "handles stream prefix with + suffix" do
      input = "2026-03-18T21:10:26.489711Z 00O+[0K[36;1mContent[0;m"
      result = described_class.convert(input)
      expect(result).not_to include("00O+")
      expect(result).to include("Content")
    end

    it "strips prefixes from all lines, not just the first" do
      input = "2026-03-18T21:10:26.489682Z 00O First line\n" \
              "2026-03-18T21:10:26.489687Z 00O Second line\n" \
              "2026-03-18T21:10:26.489692Z 00O Third line\n"
      result = described_class.convert(input)
      expect(result).not_to include("2026-03-18")
      expect(result).not_to include("00O")
      expect(result).to include("First line")
      expect(result).to include("Second line")
      expect(result).to include("Third line")
    end

    it "strips stream 01 (script output) prefixes" do
      input = "2026-03-18T21:11:10.633033Z 01O $ git fetch\n" \
              "2026-03-18T21:11:10.633041Z 01O Fetching changes...\n"
      result = described_class.convert(input)
      expect(result).not_to include("01O")
      expect(result).not_to include("2026-03-18")
      expect(result).to include("$ git fetch")
      expect(result).to include("Fetching changes...")
    end

    it "strips stderr (00E) prefixes" do
      input = "2026-03-18T21:10:26.833750Z 00E Waiting for pod to be running\n"
      result = described_class.convert(input)
      expect(result).not_to include("00E")
      expect(result).to include("Waiting for pod to be running")
    end

    it "strips multiple embedded prefixes on the same display line" do
      # Happens when a section marker consumes the newline: the next prefix
      # appears immediately after the previous line's content with no separator.
      input = "2026-03-18T21:10:26.489709Z 00O 2026-03-18T21:10:26.489711Z 00O+Content here"
      result = described_class.convert(input)
      expect(result).not_to include("2026-03-18")
      expect(result).not_to include("00O")
      expect(result).to include("Content here")
    end

    it "simulates carriage-return overwrite for progress bar lines" do
      # curl and other tools use \r to overwrite progress on the same line.
      # We should keep only the final visible state.
      input = "2026-03-18T21:11:13.000000Z 01O   0     0    0     0\r100  1368  100  1368\r\n"
      result = described_class.convert(input)
      expect(result).not_to include("  0     0")
      expect(result).to include("100  1368")
    end

    it "autolinks http URLs" do
      input = "See https://example.com/path for details"
      result = described_class.convert(input)
      expect(result).to include('<a href="https://example.com/path">https://example.com/path</a>')
    end

    it "autolinks URLs with query strings" do
      input = "https://feature-parity.us1.prod.dog/#/configurations?viewType=configurations"
      result = described_class.convert(input)
      expect(result).to include('<a href="https://feature-parity.us1.prod.dog/#/configurations?viewType=configurations">')
    end

    it "does not autolink non-URL text that starts with http" do
      input = "status: ok"
      result = described_class.convert(input)
      expect(result).not_to include("<a href")
    end
  end

  describe ".css" do
    it "returns CSS string with color classes" do
      css = described_class.css
      expect(css).to include(".log-viewer")
      expect(css).to include(".fg-red")
      expect(css).to include(".fg-green")
      expect(css).to include(".bold")
    end
  end
end
