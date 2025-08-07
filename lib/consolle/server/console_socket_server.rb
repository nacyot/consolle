# frozen_string_literal: true

require 'socket'
require 'json'
require 'logger'
require 'fileutils'
require_relative 'console_supervisor'
require_relative 'request_broker'

module Consolle
  module Server
    class ConsoleSocketServer
      attr_reader :socket_path, :logger

      def initialize(socket_path:, rails_root:, rails_env: 'development', logger: nil, command: nil, wait_timeout: nil)
        @socket_path = socket_path
        @rails_root = rails_root
        @rails_env = rails_env
        @command = command || 'bin/rails console'
        @wait_timeout = wait_timeout
        @logger = logger || begin
          log = Logger.new(STDOUT)
          log.level = Logger::DEBUG
          log
        end
        @running = false
        @server = nil
        @supervisor = nil
        @broker = nil
        @accept_thread = nil
      end

      def start
        return false if @running

        setup_socket
        setup_supervisor
        setup_broker
        setup_signal_handlers

        @running = true
        @accept_thread = start_accept_loop

        logger.info "[ConsoleSocketServer] Started at #{@socket_path}"
        true
      rescue StandardError => e
        logger.error "[ConsoleSocketServer] Failed to start: #{e.message}"
        cleanup
        raise
      end

      def stop
        return false unless @running

        @running = false

        # Stop accepting new connections
        begin
          @server&.close
        rescue StandardError
          nil
        end
        @accept_thread&.join(5)

        # Stop broker
        @broker&.stop

        # Stop supervisor
        @supervisor&.stop

        # Clean up socket file
        File.unlink(@socket_path) if File.exist?(@socket_path)

        logger.info '[ConsoleSocketServer] Stopped'
        true
      end

      def running?
        @running && @supervisor&.running?
      end

      private

      def setup_socket
        # Ensure socket directory exists
        socket_dir = File.dirname(@socket_path)
        FileUtils.mkdir_p(socket_dir) unless Dir.exist?(socket_dir)

        # Remove existing socket file
        File.unlink(@socket_path) if File.exist?(@socket_path)

        # Create Unix socket
        @server = UNIXServer.new(@socket_path)

        # Set permissions (owner only)
        File.chmod(0o600, @socket_path)
      end

      def setup_supervisor
        @supervisor = ConsoleSupervisor.new(
          rails_root: @rails_root,
          rails_env: @rails_env,
          logger: @logger,
          command: @command,
          wait_timeout: @wait_timeout
        )
      end

      def setup_broker
        @broker = RequestBroker.new(
          supervisor: @supervisor,
          logger: @logger
        )
        @broker.start
      end

      def setup_signal_handlers
        %w[INT TERM].each do |signal|
          Signal.trap(signal) do
            # Don't use logger in signal handler - it's not safe
            @running = false
            exit(0)
          end
        end
      end

      def start_accept_loop
        Thread.new do
          while @running
            begin
              client = @server.accept
              handle_client(client)
            rescue IOError => e
              # Socket closed, expected during shutdown
              break unless @running

              logger.error "[ConsoleSocketServer] Accept error: #{e.message}"
            rescue StandardError => e
              logger.error "[ConsoleSocketServer] Unexpected error: #{e.message}"
              logger.error e.backtrace.join("\n")
            end
          end
        end
      end

      def handle_client(client)
        Thread.new do
          # Read request
          logger.debug "[ConsoleSocketServer] Waiting for request data..." if ENV['DEBUG']
          request_data = client.gets
          logger.debug "[ConsoleSocketServer] Received data: #{request_data&.bytesize} bytes" if ENV['DEBUG']
          return unless request_data

          request = JSON.parse(request_data)
          logger.debug "[ConsoleSocketServer] Request: #{request.inspect}"
          logger.debug "[ConsoleSocketServer] Code size: #{request['code']&.bytesize} bytes" if ENV['DEBUG'] && request['code']

          # Process through broker
          response = @broker.process_request(request)

          # Send response
          begin
            # Ensure response is properly encoded as UTF-8
            response_json = JSON.generate(response)
            response_json = response_json.force_encoding('UTF-8')
            client.write(response_json)
            client.write("\n")
            client.flush
          rescue Errno::EPIPE
            # Client disconnected before we could send response
            logger.debug '[ConsoleSocketServer] Client disconnected before response could be sent'
          end
        rescue JSON::ParserError => e
          begin
            error_response = {
              'success' => false,
              'error' => 'InvalidRequest',
              'message' => "Invalid JSON: #{e.message}"
            }
            response_json = JSON.generate(error_response).force_encoding('UTF-8')
            client.write(response_json)
            client.write("\n")
          rescue Errno::EPIPE
            logger.debug '[ConsoleSocketServer] Client disconnected while sending JSON parse error'
          end
        rescue Errno::EPIPE
          # Client disconnected, ignore
          logger.debug '[ConsoleSocketServer] Client disconnected (Broken pipe)'
        rescue StandardError => e
          logger.error "[ConsoleSocketServer] Client handler error: #{e.message}"
          begin
            error_response = {
              'success' => false,
              'error' => e.class.name,
              'message' => e.message
            }
            response_json = JSON.generate(error_response).force_encoding('UTF-8')
            client.write(response_json)
            client.write("\n")
          rescue Errno::EPIPE
            # Client disconnected while sending error response
            logger.debug '[ConsoleSocketServer] Client disconnected while sending error response'
          end
        ensure
          begin
            client.close
          rescue StandardError
            nil
          end
        end
      end

      def cleanup
        stop
      end
    end
  end
end
