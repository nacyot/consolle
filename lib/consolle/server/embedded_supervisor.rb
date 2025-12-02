# frozen_string_literal: true

require 'timeout'
require 'stringio'
require_relative 'base_supervisor'
require_relative '../errors'

module Consolle
  module Server
    # IRB embedding mode supervisor (Ruby 3.3+)
    # Runs IRB directly in-process without PTY
    # Supports two modes:
    # - :embed_irb   - Pure IRB without Rails
    # - :embed_rails - Rails console with IRB
    class EmbeddedSupervisor < BaseSupervisor
      MINIMUM_RUBY_VERSION = Gem::Version.new('3.3.0')
      VALID_MODES = %i[embed_irb embed_rails].freeze

      class << self
        def supported?
          Gem::Version.new(RUBY_VERSION) >= MINIMUM_RUBY_VERSION
        end

        def check_support!
          return if supported?

          raise Consolle::Errors::UnsupportedRubyVersion.new(
            "Embedded mode requires Ruby #{MINIMUM_RUBY_VERSION}+, " \
            "current version: #{RUBY_VERSION}"
          )
        end
      end

      # @param rails_root [String] Project root directory
      # @param rails_env [String] Rails environment (only for embed_rails mode)
      # @param logger [Logger] Logger instance
      # @param embed_mode [Symbol] :embed_irb or :embed_rails
      def initialize(rails_root:, rails_env: 'development', logger: nil, embed_mode: :embed_rails)
        super(rails_root: rails_root, rails_env: rails_env, logger: logger)
        @embed_mode = validate_embed_mode(embed_mode)
        @running = false
        @workspace = nil
        @mutex = Mutex.new

        boot_environment
        setup_irb
        @running = true

        mode_name = @embed_mode == :embed_rails ? 'Rails console' : 'IRB'
        logger.info "[EmbeddedSupervisor] #{mode_name} embedded mode initialized (Ruby #{RUBY_VERSION})"
      end

      def eval(code, timeout: nil, pre_sigint: nil)
        # pre_sigint is ignored in embedded mode (no PTY)

        env_timeout = ENV['CONSOLLE_TIMEOUT']&.to_i
        timeout = if env_timeout && env_timeout.positive?
                    env_timeout
                  else
                    timeout || 60
                  end

        @mutex.synchronize do
          raise 'Console is not running' unless running?

          start_time = Time.now
          execute_code(code, timeout, start_time)
        end
      end

      def running?
        @running && @workspace
      end

      def stop
        @running = false
        @workspace = nil
        logger.info '[EmbeddedSupervisor] Stopped'
      end

      def restart
        logger.info '[EmbeddedSupervisor] Restarting IRB workspace...'
        @mutex.synchronize do
          setup_irb
        end
        logger.info '[EmbeddedSupervisor] IRB workspace restarted'
      end

      def mode
        @embed_mode
      end

      # Returns the current process PID (embedded mode runs in-process)
      # @return [Integer]
      def pid
        Process.pid
      end

      # Returns the prompt pattern (for compatibility with PTY mode)
      def prompt_pattern
        @config&.prompt_pattern || Consolle::Config::DEFAULT_PROMPT_PATTERN
      end

      private

      def validate_embed_mode(mode)
        mode_sym = mode.to_sym
        return mode_sym if VALID_MODES.include?(mode_sym)

        raise ArgumentError, "Invalid embed_mode: #{mode}. Must be one of: #{VALID_MODES.join(', ')}"
      end

      def boot_environment
        return boot_rails if @embed_mode == :embed_rails

        # For embed_irb mode, no Rails loading needed
        logger.info '[EmbeddedSupervisor] Pure IRB mode - skipping Rails environment'
      end

      def boot_rails
        return if defined?(Rails) && Rails.application

        ENV['RAILS_ENV'] = @rails_env

        environment_file = File.join(@rails_root, 'config', 'environment.rb')
        unless File.exist?(environment_file)
          raise Consolle::Errors::ConfigurationError.new(
            "Rails environment file not found: #{environment_file}"
          )
        end

        logger.info "[EmbeddedSupervisor] Loading Rails environment from #{environment_file}"
        require environment_file
        logger.info "[EmbeddedSupervisor] Rails #{Rails.version} loaded (#{Rails.env})"
      end

      def setup_irb
        require 'irb'

        # Initialize IRB if not already done
        IRB.setup(nil, argv: []) unless IRB.conf[:PROMPT]

        # Configure IRB for automation
        IRB.conf[:USE_COLORIZE] = false
        IRB.conf[:USE_AUTOCOMPLETE] = false
        IRB.conf[:USE_PAGER] = false
        IRB.conf[:VERBOSE] = false
        IRB.conf[:USE_MULTILINE] = false

        # Create workspace with top-level binding for Rails Console-like behavior
        @workspace = IRB::WorkSpace.new(TOPLEVEL_BINDING)

        # Inject Rails console helpers if available
        inject_rails_console_methods

        logger.debug '[EmbeddedSupervisor] IRB workspace configured'
      end

      def inject_rails_console_methods
        # Only inject for embed_rails mode
        return unless @embed_mode == :embed_rails

        begin
          # Rails 7.1 and earlier: use Rails::ConsoleMethods
          if defined?(Rails::ConsoleMethods)
            @workspace.binding.eval('extend Rails::ConsoleMethods')
            logger.debug '[EmbeddedSupervisor] Rails::ConsoleMethods injected'
          else
            # Rails 7.2+: ConsoleMethods moved, define reload! directly
            inject_reload_method
            logger.debug '[EmbeddedSupervisor] reload! method injected directly'
          end
        rescue StandardError => e
          logger.warn "[EmbeddedSupervisor] Failed to inject console methods: #{e.message}"
        end
      end

      def inject_reload_method
        # Define reload! method that calls Rails reloader
        @workspace.binding.eval(<<~RUBY)
          def reload!(print = true)
            puts "Reloading..." if print
            Rails.application.reloader.reload!
            true
          end
        RUBY
      end

      def execute_code(code, timeout, start_time)
        stdout_capture = StringIO.new
        stderr_capture = StringIO.new
        result = nil
        error = nil

        # Capture stdout/stderr
        original_stdout = $stdout
        original_stderr = $stderr
        $stdout = stdout_capture
        $stderr = stderr_capture

        begin
          Timeout.timeout(timeout) do
            # Use workspace.binding.eval for full IRB context
            result = @workspace.binding.eval(code, '(consolle)', 1)
          end
        rescue Timeout::Error
          $stdout = original_stdout
          $stderr = original_stderr
          return build_timeout_response(timeout)
        rescue SyntaxError => e
          error = e
        rescue StandardError => e
          error = e
        ensure
          $stdout = original_stdout
          $stderr = original_stderr
        end

        execution_time = Time.now - start_time
        captured_output = stdout_capture.string + stderr_capture.string

        if error
          build_error_response_with_output(error, captured_output, execution_time)
        else
          build_success_response_with_result(result, captured_output, execution_time)
        end
      end

      def build_error_response_with_output(error, captured_output, execution_time)
        output = captured_output.empty? ? "#{error.class}: #{error.message}" : captured_output

        {
          success: false,
          error_class: error.class.name,
          error_code: Consolle::Errors::ErrorClassifier.to_code(error),
          output: output,
          execution_time: execution_time
        }
      end

      def build_success_response_with_result(result, captured_output, execution_time)
        # Format output like Rails console
        # If there's captured stdout, include it
        # Always include the return value with => prefix
        output_parts = []
        output_parts << captured_output unless captured_output.empty?
        output_parts << "=> #{result.inspect}"

        {
          success: true,
          output: output_parts.join("\n"),
          result: result,
          execution_time: execution_time
        }
      end
    end
  end
end
