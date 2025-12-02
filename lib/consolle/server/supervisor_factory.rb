# frozen_string_literal: true

require_relative 'console_supervisor'
require_relative 'embedded_supervisor'

module Consolle
  module Server
    # Factory for creating the appropriate supervisor based on configuration
    #
    # Modes:
    # - :pty        - PTY-based, supports custom command (local/remote)
    # - :embed_irb  - Pure IRB embedding (Ruby 3.3+, local only)
    # - :embed_rails - Rails console embedding (Ruby 3.3+, local only)
    class SupervisorFactory
      MODES = %i[pty embed_irb embed_rails].freeze
      EMBEDDED_MODES = %i[embed_irb embed_rails].freeze

      class << self
        # Create a supervisor instance
        # @param rails_root [String] Path to project root
        # @param mode [Symbol] :pty, :embed_irb, or :embed_rails
        # @param options [Hash] Additional options passed to supervisor
        # @return [BaseSupervisor] PTY or Embedded supervisor
        def create(rails_root:, mode: :pty, **options)
          mode = normalize_mode(mode)
          validate_mode!(mode)

          case mode
          when :pty
            create_pty_supervisor(rails_root, options)
          when :embed_irb
            create_embedded_supervisor(rails_root, :embed_irb, options)
          when :embed_rails
            create_embedded_supervisor(rails_root, :embed_rails, options)
          end
        end

        # Check if embedded mode is available (Ruby 3.3+)
        # @return [Boolean]
        def embedded_available?
          EmbeddedSupervisor.supported?
        end

        private

        def normalize_mode(mode)
          mode_sym = mode.to_s.tr('-', '_').to_sym

          # Handle legacy mode names
          case mode_sym
          when :embedded then :embed_rails
          when :auto then :pty
          else mode_sym
          end
        end

        def validate_mode!(mode)
          return if MODES.include?(mode)

          raise ArgumentError, "Invalid mode: #{mode}. Must be one of: #{MODES.join(', ')}"
        end

        def create_pty_supervisor(rails_root, options)
          ConsoleSupervisor.new(
            rails_root: rails_root,
            rails_env: options[:rails_env] || 'development',
            logger: options[:logger],
            command: options[:command],
            wait_timeout: options[:wait_timeout]
          )
        end

        def create_embedded_supervisor(rails_root, embed_mode, options)
          EmbeddedSupervisor.check_support!

          EmbeddedSupervisor.new(
            rails_root: rails_root,
            rails_env: options[:rails_env] || 'development',
            logger: options[:logger],
            embed_mode: embed_mode
          )
        end
      end
    end
  end
end
