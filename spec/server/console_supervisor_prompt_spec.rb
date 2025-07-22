# frozen_string_literal: true

require "spec_helper"
require "consolle/server/console_supervisor"

RSpec.describe "ConsoleSupervisor prompt pattern matching" do
  let(:prompt_pattern) { Consolle::Server::ConsoleSupervisor::PROMPT_PATTERN }

  describe "PROMPT_PATTERN" do
    context "standard prompts" do
      it "matches basic irb prompt" do
        expect("irb(main):001:0> ").to match(prompt_pattern)
      end

      it "matches Rails console prompt" do
        expect("rails(development)> ").to match(prompt_pattern)
      end

      it "matches app-specific prompts" do
        expect("myapp(production)> ").to match(prompt_pattern)
        expect("lua-home(prod)> ").to match(prompt_pattern)
        expect("app_name(staging)> ").to match(prompt_pattern)
      end

      it "matches simple prompts" do
        expect(">> ").to match(prompt_pattern)
        expect("> ").to match(prompt_pattern)
      end

      it "matches the custom CONSOLLE prompt" do
        expect("\u001E\u001F<CONSOLLE>\u001F\u001E ").to match(prompt_pattern)
      end
    end

    context "prompts with special characters" do
      it "matches prompt with Unicode triangle prefix" do
        # ▽ character before prompt (UTF-8: \xE2\x96\xBD)
        expect("▽lua-home(prod)> ").to match(prompt_pattern)
      end

      it "matches prompt with other Unicode symbols" do
        expect("→rails(dev)> ").to match(prompt_pattern)
        expect("❯app(test)> ").to match(prompt_pattern)
        expect("➜myapp(staging)> ").to match(prompt_pattern)
      end

      it "matches prompt with whitespace prefix" do
        expect("  rails(dev)> ").to match(prompt_pattern)
        expect("\tlua-home(prod)> ").to match(prompt_pattern)
      end
    end

    context "prompts with ANSI codes" do
      it "matches prompt with color codes" do
        # lua-home(prod)> where "prod" is red
        ansi_prompt = "\e[0mlua-home(\e[31mprod\e[0m)> \e[0m"
        stripped = ansi_prompt.gsub(/\e\[[\d;]*[a-zA-Z]/, "")
        expect(stripped).to match(prompt_pattern)
      end

      it "matches prompt with bold formatting" do
        ansi_prompt = "\e[1mirb(main):001:0>\e[0m "
        stripped = ansi_prompt.gsub(/\e\[[\d;]*[a-zA-Z]/, "")
        expect(stripped).to match(prompt_pattern)
      end
    end

    context "non-matching strings" do
      it "does not match regular output" do
        expect("Loading production environment").not_to match(prompt_pattern)
        expect("[OpenAI] Client initialized").not_to match(prompt_pattern)
        expect("User.count").not_to match(prompt_pattern)
      end

      it "does not match incomplete prompts" do
        expect("irb(main)").not_to match(prompt_pattern)
        expect("rails(dev)").not_to match(prompt_pattern)
      end
    end
  end

  describe "wait_for_prompt integration" do
    let(:logger) { Logger.new(nil) }
    let(:rails_root) { "/fake/rails/root" }
    
    # Test that wait_for_prompt works with various prompt formats
    context "with kamal-style SSH output" do
      it "recognizes prompt after SSH connection messages" do
        output = <<~OUTPUT
          Get current version of running container...
          INFO [5e384254] Running /usr/bin/env sh -c 'docker ps...'
          INFO [5e384254] Finished in 2.312 seconds with exit status 0 (successful).
          Launching interactive command with version 769cd5478364841d504f92a4c77849d3b689194d via SSH from existing container on 100.86.208.35...
          [OpenAI] Client initialized
          [Slack] Web client initialized
          Loading production environment (Rails 8.0.2)
          ▽lua-home(prod)> 
        OUTPUT

        # Simulate what wait_for_prompt does
        clean = output.gsub(/\e\[[\d;]*[a-zA-Z]/, "").gsub(/\e\[\?[\d]+[hl]/, "").gsub(/\e[<>=]/, "")
        found_prompt = false
        
        clean.lines.each do |line|
          if line.match?(prompt_pattern)
            found_prompt = true
            break
          end
        end
        
        expect(found_prompt).to be true
      end
    end
  end
end