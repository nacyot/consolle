# frozen_string_literal: true

module Consolle
  module Server
    # Base interface for console supervisors
    # Both PTY-based and embedded IRB modes inherit from this class
    class BaseSupervisor
      attr_reader :rails_root, :rails_env, :logger, :config

      def initialize(rails_root:, rails_env: 'development', logger: nil)
        @rails_root = rails_root
        @rails_env = rails_env
        @logger = logger || Logger.new($stdout)
        @config = Consolle::Config.load(rails_root)
      end

      # Execute code and return result
      # @param code [String] Ruby code to evaluate
      # @param timeout [Integer] Timeout in seconds
      # @return [Hash] Result hash with :success, :output, :execution_time, etc.
      def eval(code, timeout: 60)
        raise NotImplementedError, "#{self.class} must implement #eval"
      end

      # Check if the console is running and ready
      # @return [Boolean]
      def running?
        raise NotImplementedError, "#{self.class} must implement #running?"
      end

      # Stop the console
      def stop
        raise NotImplementedError, "#{self.class} must implement #stop"
      end

      # Restart the console
      def restart
        raise NotImplementedError, "#{self.class} must implement #restart"
      end

      # Returns the mode name for logging/debugging
      # @return [Symbol] :pty or :embedded
      def mode
        raise NotImplementedError, "#{self.class} must implement #mode"
      end

      protected

      def build_success_response(output, execution_time:, result: nil)
        response = {
          success: true,
          output: output,
          execution_time: execution_time
        }
        response[:result] = result if result
        response
      end

      def build_error_response(exception, execution_time: nil)
        if exception.is_a?(String)
          error_code = Consolle::Errors::ErrorClassifier.classify_message(exception)
          return {
            success: false,
            error_class: 'RuntimeError',
            error_code: error_code,
            output: exception,
            execution_time: execution_time
          }
        end

        {
          success: false,
          error_class: exception.class.name,
          error_code: Consolle::Errors::ErrorClassifier.to_code(exception),
          output: "#{exception.class}: #{exception.message}",
          execution_time: execution_time
        }
      end

      def build_timeout_response(timeout_seconds)
        error = Consolle::Errors::ExecutionTimeout.new(timeout_seconds)
        {
          success: false,
          error_class: error.class.name,
          error_code: Consolle::Errors::ErrorClassifier.to_code(error),
          output: error.message,
          execution_time: timeout_seconds
        }
      end
    end
  end
end
