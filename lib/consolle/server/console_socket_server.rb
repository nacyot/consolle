# frozen_string_literal: true

require "socket"
require "json"
require "logger"
require "fileutils"
require_relative "console_supervisor"
require_relative "request_broker"

module Consolle
  module Server
    class ConsoleSocketServer
      attr_reader :socket_path, :logger

      def initialize(socket_path:, rails_root:, rails_env: "development", logger: nil, command: nil)
        @socket_path = socket_path
        @rails_root = rails_root
        @rails_env = rails_env
        @command = command || "bin/rails console"
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
        @server&.close rescue nil
        @accept_thread&.join(5)
        
        # Stop broker
        @broker&.stop
        
        # Stop supervisor
        @supervisor&.stop
        
        # Clean up socket file
        File.unlink(@socket_path) if File.exist?(@socket_path)
        
        logger.info "[ConsoleSocketServer] Stopped"
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
        File.chmod(0600, @socket_path)
      end

      def setup_supervisor
        @supervisor = ConsoleSupervisor.new(
          rails_root: @rails_root,
          rails_env: @rails_env,
          logger: @logger,
          command: @command
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
          begin
            # Read request
            request_data = client.gets
            return unless request_data
            
            request = JSON.parse(request_data)
            logger.debug "[ConsoleSocketServer] Request: #{request.inspect}"
            
            # Process through broker
            response = @broker.process_request(request)
            
            # Send response
            client.write(JSON.generate(response))
            client.write("\n")
            client.flush
          rescue JSON::ParserError => e
            error_response = {
              "success" => false,
              "error" => "InvalidRequest",
              "message" => "Invalid JSON: #{e.message}"
            }
            client.write(JSON.generate(error_response))
            client.write("\n")
          rescue StandardError => e
            logger.error "[ConsoleSocketServer] Client handler error: #{e.message}"
            error_response = {
              "success" => false,
              "error" => e.class.name,
              "message" => e.message
            }
            client.write(JSON.generate(error_response))
            client.write("\n")
          ensure
            client.close rescue nil
          end
        end
      end

      def cleanup
        stop
      end
    end
  end
end