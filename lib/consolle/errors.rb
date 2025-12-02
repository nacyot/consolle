# frozen_string_literal: true

module Consolle
  module Errors
    # Base error class for all Consolle errors
    class Error < StandardError; end

    # Timeout errors hierarchy
    class Timeout < Error; end

    # Socket communication timeout (CLI/Adapter layer)
    class SocketTimeout < Timeout
      def initialize(timeout_seconds)
        super("Socket operation timed out after #{timeout_seconds} seconds")
      end
    end

    # Request processing timeout (Broker layer)
    class RequestTimeout < Timeout
      def initialize
        super("Request processing timed out")
      end
    end

    # Code execution timeout (Supervisor layer)
    class ExecutionTimeout < Timeout
      def initialize(timeout_seconds)
        super("Code execution timed out after #{timeout_seconds} seconds")
      end
    end

    # Execution errors
    class ExecutionError < Error; end

    # Server/console health issues
    class ServerUnhealthy < Error
      def initialize(message = 'Console server is unhealthy')
        super(message)
      end
    end

    # Prompt detection failure with diagnostic information
    class PromptDetectionError < Error
      attr_reader :received_output, :expected_patterns, :config_path

      def initialize(timeout:, received_output:, expected_patterns:, config_path:)
        @received_output = received_output
        @expected_patterns = expected_patterns
        @config_path = config_path

        super(build_message(timeout))
      end

      private

      def build_message(timeout)
        # Extract last line that looks like a prompt (ends with > or similar)
        lines = @received_output.to_s.lines.map(&:strip).reject(&:empty?)
        potential_prompt = lines.reverse.find { |l| l.match?(/[>*]\s*$/) } || lines.last

        <<~MSG.strip
          Prompt not detected after #{timeout} seconds

          Received output:
            #{@received_output.to_s.lines.last(5).map { |l| l.strip }.join("\n    ")}

          Potential prompt found:
            #{potential_prompt.inspect}

          #{@expected_patterns}

          To fix this, add to #{@config_path}:
            prompt_pattern: '#{escape_for_yaml(potential_prompt)}'

          Or set environment variable:
            CONSOLLE_PROMPT_PATTERN='#{escape_for_yaml(potential_prompt)}' cone start
        MSG
      end

      def escape_for_yaml(str)
        return '' if str.nil?
        # Escape special regex characters and create a simple pattern
        str.to_s
           .gsub(/\e\[[\d;]*[a-zA-Z]/, '') # Remove ANSI codes
           .gsub(/[\x00-\x1F]/, '')        # Remove control characters
           .strip
           .gsub(/(\d+)/, '\d+')           # Replace numbers with \d+
           .gsub(/([().\[\]{}|*+?^$\\])/, '\\\\\1') # Escape regex special chars
      end
    end

    # Syntax error in executed code
    class SyntaxError < ExecutionError
      def initialize(message)
        super("Syntax error: #{message}")
      end
    end

    # Runtime error in executed code
    class RuntimeError < ExecutionError
      def initialize(message)
        super("Runtime error: #{message}")
      end
    end

    # Load error (missing gem, file, etc.)
    class LoadError < ExecutionError
      def initialize(message)
        super("Load error: #{message}")
      end
    end

    # Configuration error
    class ConfigurationError < Error
      def initialize(message)
        super("Configuration error: #{message}")
      end
    end

    # Unsupported Ruby version for embedded mode
    class UnsupportedRubyVersion < Error
      def initialize(message)
        super(message)
      end
    end

    # Error classifier to map exceptions to error codes
    class ErrorClassifier
      ERROR_CODE_MAP = {
        'Timeout::Error' => 'EXECUTION_TIMEOUT',
        'Consolle::Errors::SocketTimeout' => 'SOCKET_TIMEOUT',
        'Consolle::Errors::RequestTimeout' => 'REQUEST_TIMEOUT',
        'Consolle::Errors::ExecutionTimeout' => 'EXECUTION_TIMEOUT',
        'SyntaxError' => 'SYNTAX_ERROR',
        '::SyntaxError' => 'SYNTAX_ERROR',
        'LoadError' => 'LOAD_ERROR',
        '::LoadError' => 'LOAD_ERROR',
        'NameError' => 'NAME_ERROR',
        'NoMethodError' => 'NO_METHOD_ERROR',
        'ArgumentError' => 'ARGUMENT_ERROR',
        'TypeError' => 'TYPE_ERROR',
        'ZeroDivisionError' => 'ZERO_DIVISION_ERROR',
        'RuntimeError' => 'RUNTIME_ERROR',
        '::RuntimeError' => 'RUNTIME_ERROR',
        'StandardError' => 'STANDARD_ERROR',
        'Exception' => 'EXCEPTION',
        'Consolle::Errors::ServerUnhealthy' => 'SERVER_UNHEALTHY',
        'Consolle::Errors::PromptDetectionError' => 'PROMPT_DETECTION_ERROR'
      }.freeze

      def self.to_code(exception)
        return 'UNKNOWN_ERROR' unless exception.is_a?(Exception)

        # Try exact class match first
        error_code = ERROR_CODE_MAP[exception.class.name]
        return error_code if error_code

        # Try with leading :: for core Ruby errors
        error_code = ERROR_CODE_MAP["::#{exception.class.name}"]
        return error_code if error_code

        # Check inheritance chain
        exception.class.ancestors.each do |klass|
          error_code = ERROR_CODE_MAP[klass.name]
          return error_code if error_code
        end

        'UNKNOWN_ERROR'
      end

      def self.classify_message(error_message)
        case error_message
        when /syntax error/i
          'SYNTAX_ERROR'
        when /cannot load such file|no such file to load/i
          'LOAD_ERROR'
        when /undefined local variable or method/i, /undefined method/i
          'NAME_ERROR'
        when /wrong number of arguments/i
          'ARGUMENT_ERROR'
        when /execution timed out/i
          'EXECUTION_TIMEOUT'
        when /request timed out/i
          'REQUEST_TIMEOUT'
        else
          'EXECUTION_ERROR'
        end
      end
    end
  end
end
