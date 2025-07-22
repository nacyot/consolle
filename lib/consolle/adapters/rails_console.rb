# frozen_string_literal: true

require "socket"
require "json"
require "timeout"
require "securerandom"
require "fileutils"

module Consolle
  module Adapters
    class RailsConsole
      attr_reader :socket_path, :process_pid, :pid_path, :log_path

      def initialize(socket_path: nil, pid_path: nil, log_path: nil, rails_root: nil, rails_env: nil, verbose: false)
        @socket_path = socket_path || default_socket_path
        @pid_path = pid_path || default_pid_path
        @log_path = log_path || default_log_path
        @rails_root = rails_root || Dir.pwd
        @rails_env = rails_env || "development"
        @verbose = verbose
        @server_pid = nil
      end

      def start
        return false if running?

        # Start socket server daemon
        start_server_daemon
        
        # Wait for server to be ready
        wait_for_server(timeout: 10)
        
        # Get server status
        status = get_status
        @server_pid = status["pid"] if status && status["success"]
        
        true
      rescue StandardError => e
        stop_server_daemon
        raise e
      end

      def stop
        return false unless running?

        stop_server_daemon
        @server_pid = nil
        true
      end

      def restart
        stop
        sleep 1
        start
      end

      def running?
        return false unless File.exist?(@socket_path)
        
        # Check if socket is responsive
        status = get_status
        status && status["success"] && status["running"]
      rescue StandardError
        false
      end

      def process_pid
        # Return the server daemon PID from pid file
        pid_file = @pid_path
        return nil unless File.exist?(pid_file)
        
        File.read(pid_file).strip.to_i
      rescue StandardError
        nil
      end

      def send_code(code, timeout: 15)
        unless running?
          raise RuntimeError, "Console is not running"
        end

        request = {
          "action" => "eval",
          "code" => code,
          "timeout" => timeout,
          "request_id" => SecureRandom.uuid
        }

        response = send_request(request, timeout: timeout + 5)
        
        # Format response for compatibility
        if response["success"]
          {
            "success" => true,
            "result" => response["result"],
            "execution_time" => response["execution_time"],
            "request_id" => response["request_id"]
          }
        else
          {
            "success" => false,
            "error" => response["error"] || "Unknown",
            "message" => response["message"] || "Unknown error",
            "request_id" => response["request_id"]
          }
        end
      end

      def get_status
        request = {
          "action" => "status",
          "request_id" => SecureRandom.uuid
        }
        
        send_request(request, timeout: 5)
      rescue StandardError
        nil
      end

      private

      def default_socket_path
        File.join(Dir.pwd, "tmp", "cone", "cone.socket")
      end

      def default_pid_path
        File.join(Dir.pwd, "tmp", "cone", "cone.pid")
      end

      def default_log_path
        File.join(Dir.pwd, "tmp", "cone", "cone.log")
      end

      def server_command
        consolle_lib_path = File.expand_path("../..", __dir__)
        
        # Build server command
        [
          "ruby",
          "-I", consolle_lib_path,
          "-e", server_script,
          "--",
          @socket_path,
          @rails_root,
          @rails_env,
          @verbose ? "debug" : "info",
          @pid_path,
          @log_path
        ]
      end

      def server_script
        <<~RUBY
          begin
            require 'consolle/server/console_socket_server'
            require 'logger'
            
            socket_path, rails_root, rails_env, log_level, pid_path, log_path = ARGV
            
            # Write initial log
            log_file = log_path || socket_path.sub(/\\.socket$/, '.log')
            File.open(log_file, 'a') { |f| f.puts "[Server] Starting... PID: \#{Process.pid}" }
            
            # Daemonize
            Process.daemon(true, false)
            
            # Redirect output
            $stdout.reopen(log_file, 'a')
            $stderr.reopen(log_file, 'a')
            $stdout.sync = $stderr.sync = true
            
            # Write PID file
            pid_file = pid_path || socket_path.sub(/\\.socket$/, '.pid')
            File.write(pid_file, Process.pid.to_s)
            
            puts "[Server] Daemon started, PID: \#{Process.pid}"
            
            # Create logger with appropriate level
            logger = Logger.new(log_file)
            logger.level = (log_level == 'debug') ? Logger::DEBUG : Logger::INFO
            
            # Start server
            server = Consolle::Server::ConsoleSocketServer.new(
              socket_path: socket_path,
              rails_root: rails_root,
              rails_env: rails_env,
              logger: logger
            )
            
            puts "[Server] Starting server with log level: \#{log_level}..."
            server.start
            
            puts "[Server] Server started, entering sleep..."
            
            # Keep running
            sleep
          rescue => e
            puts "[Server] Error: \#{e.class}: \#{e.message}"
            puts e.backtrace.join("\\n")
            exit 1
          end
        RUBY
      end

      def start_server_daemon
        # Ensure directory exists
        socket_dir = File.dirname(@socket_path)
        FileUtils.mkdir_p(socket_dir) unless Dir.exist?(socket_dir)
        
        # Start server process
        log_file = @log_path
        pid = Process.spawn(
          *server_command,
          out: log_file,
          err: log_file
        )
        
        Process.detach(pid)
      end

      def stop_server_daemon
        # Read PID file
        pid_file = @pid_path
        return unless File.exist?(pid_file)
        
        pid = File.read(pid_file).to_i
        
        # Kill process
        begin
          Process.kill("TERM", pid)
          
          # Wait for socket to disappear
          10.times do
            break unless File.exist?(@socket_path)
            sleep 0.1
          end
          
          # Force kill if needed
          if File.exist?(@socket_path)
            Process.kill("KILL", pid) rescue nil
          end
        rescue Errno::ESRCH
          # Process already dead
        end
        
        # Clean up files
        File.unlink(@socket_path) if File.exist?(@socket_path)
        File.unlink(pid_file) if File.exist?(pid_file)
      end

      def wait_for_server(timeout: 10)
        deadline = Time.now + timeout
        
        while Time.now < deadline
          return true if File.exist?(@socket_path) && get_status
          sleep 0.1
        end
        
        raise "Server failed to start within #{timeout} seconds"
      end

      def send_request(request, timeout: 30)
        Timeout.timeout(timeout) do
          socket = UNIXSocket.new(@socket_path)
          
          # Send request
          socket.write(JSON.generate(request))
          socket.write("\n")
          socket.flush
          
          # Read response
          response_data = socket.gets
          socket.close
          
          JSON.parse(response_data)
        end
      rescue Timeout::Error
        {
          "success" => false,
          "error" => "Timeout",
          "message" => "Request timed out after #{timeout} seconds"
        }
      rescue StandardError => e
        {
          "success" => false,
          "error" => e.class.name,
          "message" => e.message
        }
      end
    end
  end
end