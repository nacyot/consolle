# frozen_string_literal: true

require 'yaml'

module Consolle
  # Configuration loader for .consolle.yml
  class Config
    CONFIG_FILENAME = '.consolle.yml'

    # Default prompt pattern that matches various console prompts
    # - Custom sentinel: \u001E\u001F<CONSOLLE>\u001F\u001E
    # - Rails app prompts: app(env)> or app(env):001>
    # - IRB prompts: irb(main):001:0> or irb(main):001>
    # - Generic prompts: >> or >
    DEFAULT_PROMPT_PATTERN = /^[^\w]*(\u001E\u001F<CONSOLLE>\u001F\u001E|\w+[-_]?\w*\([^)]*\)(:\d+)?>|irb\([^)]+\):\d+:?\d*[>*]|>>|>)\s*$/

    attr_reader :rails_root, :prompt_pattern, :raw_prompt_pattern

    def initialize(rails_root)
      @rails_root = rails_root
      @config = load_config
      @raw_prompt_pattern = @config['prompt_pattern']
      @prompt_pattern = parse_prompt_pattern(@raw_prompt_pattern)
    end

    def self.load(rails_root)
      new(rails_root)
    end

    # Check if a custom prompt pattern is configured
    def custom_prompt_pattern?
      !@raw_prompt_pattern.nil?
    end

    # Get human-readable description of expected prompt patterns
    def prompt_pattern_description
      if custom_prompt_pattern?
        "Custom pattern: #{@raw_prompt_pattern}"
      else
        <<~DESC.strip
          Default patterns:
            - app(env)> or app(env):001>  (Rails console)
            - irb(main):001:0>            (IRB)
            - >> or >                     (Generic)
        DESC
      end
    end

    private

    def config_path
      File.join(@rails_root, CONFIG_FILENAME)
    end

    def load_config
      return {} unless File.exist?(config_path)

      begin
        YAML.safe_load(File.read(config_path)) || {}
      rescue Psych::SyntaxError => e
        warn "[Consolle] Warning: Failed to parse #{CONFIG_FILENAME}: #{e.message}"
        {}
      end
    end

    def parse_prompt_pattern(pattern_string)
      return DEFAULT_PROMPT_PATTERN if pattern_string.nil?

      begin
        Regexp.new(pattern_string)
      rescue RegexpError => e
        warn "[Consolle] Warning: Invalid prompt_pattern '#{pattern_string}': #{e.message}"
        warn "[Consolle] Using default pattern instead."
        DEFAULT_PROMPT_PATTERN
      end
    end
  end
end
