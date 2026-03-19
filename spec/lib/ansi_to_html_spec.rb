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
