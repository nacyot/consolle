# frozen_string_literal: true

require 'socket'
require 'json'
require 'timeout'
require 'securerandom'
require 'fileutils'

module Consolle
  module Adapters
    class RailsConsole
      attr_reader :socket_path, :process_pid, :pid_path, :log_path

      def initialize(socket_path: nil, pid_path: nil, log_path: nil, rails_root: nil, rails_env: nil, verbose: false,
                     command: nil, wait_timeout: nil)
        @socket_path = socket_path || default_socket_path
        @pid_path = pid_path || default_pid_path
        @log_path = log_path || default_log_path
        @rails_root = rails_root || Dir.pwd
        @rails_env = rails_env || 'development'
        @verbose = verbose
        @command = command || 'bin/rails console'
        @wait_timeout = wait_timeout || 15
        @server_pid = nil
      end

      def start
        return false if running?

        # Start socket server daemon
        start_server_daemon

        # Wait for server to be ready
        wait_for_server(timeout: @wait_timeout)

        # Get server status
        status = get_status
        @server_pid = status['pid'] if status && status['success']

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
        status && status['success'] && status['running']
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
        raise 'Console is not running' unless running?

        request = {
          'action' => 'eval',
          'code' => code,
          'timeout' => timeout,
          'request_id' => SecureRandom.uuid
        }

        response = send_request(request, timeout: timeout + 5)

        # Format response for compatibility
        if response['success']
          {
            'success' => true,
            'result' => response['result'],
            'execution_time' => response['execution_time'],
            'request_id' => response['request_id']
          }
        else
          {
            'success' => false,
            'error' => response['error'] || 'Unknown',
            'message' => response['message'] || 'Unknown error',
            'request_id' => response['request_id']
          }
        end
      end

      def get_status
        request = {
          'action' => 'status',
          'request_id' => SecureRandom.uuid
        }

        send_request(request, timeout: 5)
      rescue StandardError
        nil
      end

      private

      def default_socket_path
        File.join(Dir.pwd, 'tmp', 'cone', 'cone.socket')
      end

      def default_pid_path
        File.join(Dir.pwd, 'tmp', 'cone', 'cone.pid')
      end

      def default_log_path
        File.join(Dir.pwd, 'tmp', 'cone', 'cone.log')
      end

      def server_command
        consolle_lib_path = File.expand_path('../..', __dir__)

        # Build server command
        [
          'ruby',
          '-I', consolle_lib_path,
          '-e', server_script,
          '--',
          @socket_path,
          @rails_root,
          @rails_env,
          @verbose ? 'debug' : 'info',
          @pid_path,
          @log_path,
          @command,
          @wait_timeout.to_s
        ]
      end

      def server_script
        <<~RUBY
          begin
            require 'consolle/server/console_socket_server'
            require 'logger'
          #{'  '}
            socket_path, rails_root, rails_env, log_level, pid_path, log_path, command, wait_timeout_str = ARGV
            wait_timeout = wait_timeout_str ? wait_timeout_str.to_i : nil
          #{'  '}
            # Write initial log
            log_file = log_path || socket_path.sub(/\\.socket$/, '.log')
            File.open(log_file, 'a') { |f| f.puts "[Server] Starting... PID: \#{Process.pid}" }
          #{'  '}
            # Daemonize
            Process.daemon(true, false)
          #{'  '}
            # Redirect output
            $stdout.reopen(log_file, 'a')
            $stderr.reopen(log_file, 'a')
            $stdout.sync = $stderr.sync = true
          #{'  '}
            # Write PID file
            pid_file = pid_path || socket_path.sub(/\\.socket$/, '.pid')
            File.write(pid_file, Process.pid.to_s)
          #{'  '}
            puts "[Server] Daemon started, PID: \#{Process.pid}"
          #{'  '}
            # Create logger with appropriate level
            logger = Logger.new(log_file)
            logger.level = (log_level == 'debug') ? Logger::DEBUG : Logger::INFO
          #{'  '}
            # Start server
            server = Consolle::Server::ConsoleSocketServer.new(
              socket_path: socket_path,
              rails_root: rails_root,
              rails_env: rails_env,
              logger: logger,
              command: command,
              wait_timeout: wait_timeout
            )
          #{'  '}
            puts "[Server] Starting server with log level: \#{log_level}..."
            server.start
          #{'  '}
            puts "[Server] Server started, entering sleep..."
          #{'  '}
            # Keep running
            sleep
          rescue => e
            puts "[Server] Error: \#{e.class}: \#{e.message}"
            puts e.backtrace.join("\\n")
            
            # Clean up socket file if it exists
            if defined?(socket_path) && socket_path && File.exist?(socket_path)
              File.unlink(socket_path) rescue nil
            end
            
            # Clean up PID file if it exists
            if defined?(pid_file) && pid_file && File.exist?(pid_file)
              File.unlink(pid_file) rescue nil
            end
            
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
          out: [log_file, 'a'],
          err: [log_file, 'a']
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
          Process.kill('TERM', pid)

          # Wait for socket to disappear
          10.times do
            break unless File.exist?(@socket_path)

            sleep 0.1
          end

          # Force kill if needed
          if File.exist?(@socket_path)
            begin
              Process.kill('KILL', pid)
            rescue StandardError
              nil
            end
          end
        rescue Errno::ESRCH
          # Process already dead
        end

        # Clean up files
        File.unlink(@socket_path) if File.exist?(@socket_path)
        File.unlink(pid_file) if File.exist?(pid_file)
      end

      def wait_for_server(timeout: 15)
        deadline = Time.now + timeout
        server_pid = nil
        error_found = false
        error_message = nil
        last_log_check = Time.now
        ssh_auth_detected = false

        puts "Waiting for console to start (timeout: #{timeout}s)..." if @verbose

        while Time.now < deadline
          # Check if server process is still alive by checking pid file
          if File.exist?(@pid_path)
            server_pid ||= File.read(@pid_path).to_i
            begin
              Process.kill(0, server_pid)
              # Process is alive
            rescue Errno::ESRCH
              # Process died - check log for error
              if File.exist?(@log_path)
                log_content = File.read(@log_path)
                if log_content.include?('[Server] Error:')
                  error_lines = log_content.lines.grep(/\[Server\] Error:/)
                  error_message = error_lines.last.strip if error_lines.any?
                else
                  error_message = "Server process died unexpectedly"
                end
              else
                error_message = "Server process died unexpectedly"
              end
              error_found = true
              break
            end
          end

          # Check log file periodically for errors or SSH auth messages
          if Time.now - last_log_check > 0.5
            last_log_check = Time.now
            if File.exist?(@log_path)
              log_content = File.read(@log_path)
              
              # Check for explicit errors
              if log_content.include?('[Server] Error:')
                error_lines = log_content.lines.grep(/\[Server\] Error:/)
                error_message = error_lines.last.strip if error_lines.any?
                error_found = true
                break
              end
              
              # Check for SSH authentication messages
              if !ssh_auth_detected && (log_content.include?('SSH') || 
                                       log_content.include?('ssh') || 
                                       log_content.include?('Authenticating') ||
                                       log_content.include?('authentication') ||
                                       log_content.include?('1Password') ||
                                       @command.include?('kamal') ||
                                       @command.include?('ssh'))
                ssh_auth_detected = true
                puts "SSH authentication detected, extending timeout..." if @verbose
                # Extend deadline for SSH auth
                deadline = Time.now + [timeout, 60].max
              end
            end
          end

          # Check if socket exists and server is responsive
          if File.exist?(@socket_path)
            begin
              status = get_status
              if status && status['success'] && status['running']
                return true
              end
            rescue StandardError
              # Socket exists but not ready yet, continue waiting
            end
          end

          sleep 0.1
        end

        if error_found
          raise "Server failed to start: #{error_message || 'Unknown error'}"
        else
          timeout_msg = "Server failed to start within #{timeout} seconds"
          timeout_msg += " (SSH authentication may be required)" if ssh_auth_detected || @command.include?('ssh') || @command.include?('kamal')
          raise timeout_msg
        end
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
          'success' => false,
          'error' => 'Timeout',
          'message' => "Request timed out after #{timeout} seconds"
        }
      rescue StandardError => e
        {
          'success' => false,
          'error' => e.class.name,
          'message' => e.message
        }
      end
    end
  end
end
