# frozen_string_literal: true

require 'thor'
require 'fileutils'
require 'json'
require 'socket'
require 'timeout'
require 'securerandom'
require 'date'
require_relative 'constants'
require_relative 'adapters/rails_console'

module Consolle
  class CLI < Thor
    package_name 'Consolle'

    class << self
      def start(given_args = ARGV, config = {})
        # Intercept --help at the top level
        if given_args == ['--help'] || given_args == ['-h'] || given_args.empty?
          shell = Thor::Base.shell.new
          help(shell)
          return
        end
        super
      end

      def help(shell, subcommand = false)
        if subcommand == false
          shell.say 'Consolle - Rails console management tool', :cyan
          shell.say
          shell.say 'USAGE:', :yellow
          shell.say '  cone [COMMAND] [OPTIONS]'
          shell.say
          shell.say 'COMMANDS:', :yellow
          shell.say '  cone start              # Start Rails console in background'
          shell.say '  cone stop               # Stop Rails console'
          shell.say '  cone restart            # Restart Rails console'
          shell.say '  cone status             # Show Rails console status'
          shell.say '  cone exec CODE          # Execute Ruby code in Rails console'
          shell.say '  cone ls                 # List active Rails console sessions'
          shell.say '  cone stop_all           # Stop all Rails console sessions'
          shell.say '  cone rule FILE          # Write cone command guide to FILE'
          shell.say '  cone version            # Show version'
          shell.say
          shell.say 'GLOBAL OPTIONS:', :yellow
          shell.say '  -v, --verbose           # Enable verbose output'
          shell.say '  -t, --target NAME       # Target session name (default: cone)'
          shell.say '  -h, --help              # Show this help message'
          shell.say
          shell.say 'EXAMPLES:', :yellow
          shell.say "  cone exec 'User.count'                    # Execute code in default session"
          shell.say "  RAILS_ENV=production cone start           # Start console in production"
          shell.say "  cone exec -t api 'Rails.env'              # Execute code in 'api' session"
          shell.say '  cone exec -f script.rb                    # Execute code from file'
          shell.say
          shell.say 'For more information on a specific command:'
          shell.say '  cone COMMAND --help'
          shell.say
        else
          super
        end
      end
    end

    class_option :verbose, type: :boolean, aliases: '-v', desc: 'Verbose output'
    class_option :target, type: :string, aliases: '-t', desc: 'Target session name', default: 'cone'

    def self.exit_on_failure?
      true
    end

    # Override invoke_command to handle --help flag for subcommands
    no_commands do
      def invoke_command(command, *args)
        # Check if --help or -h is in the original arguments
        if ARGV.include?('--help') || ARGV.include?('-h')
          # Show help for the command
          self.class.command_help(shell, command.name)
          return
        end

        # Call original invoke_command
        super
      end
    end

    # Remove default_task since we handle it in self.start

    desc 'version', 'Show consolle version'
    def version
      puts "Consolle version #{Consolle::VERSION}"
    end

    # Override help to use our custom help
    desc 'help [COMMAND]', 'Show help'
    def help(command = nil)
      if command
        self.class.command_help(shell, command)
      else
        self.class.help(shell)
      end
    end

    desc 'rule FILE', 'Write cone command guide to FILE'
    def rule(file_path)
      # Read the embedded rule content
      rule_content = File.read(File.expand_path('../../rule.md', __dir__))

      # Write to the specified file
      File.write(file_path, rule_content)
      puts "✓ Cone command guide written to #{file_path}"
    rescue StandardError => e
      puts "✗ Failed to write rule file: #{e.message}"
      exit 1
    end

    desc 'start', 'Start Rails console in background'
    long_desc <<-LONGDESC
      Starts a Rails console process in the background for the current Rails project.
      The console runs as a daemon and can be accessed through the exec command.

      You can specify a custom session name with --target to run multiple consoles:
        RAILS_ENV=production cone start --target api
        RAILS_ENV=development cone start --target worker

      Custom console commands are supported for special environments:
        cone start --command "kamal app exec -i 'bin/rails console'"
        cone start --command "docker exec -it myapp bin/rails console"
      
      For SSH-based commands that require authentication (e.g., 1Password SSH agent):
        cone start --command "kamal console" --wait-timeout 60
    LONGDESC
    # Rails environment is now controlled via RAILS_ENV, not a CLI option
    method_option :command, type: :string, aliases: '-c', desc: 'Custom console command', default: 'bin/rails console'
    method_option :wait_timeout, type: :numeric, aliases: '-w', desc: 'Timeout for console startup (seconds)', default: Consolle::DEFAULT_WAIT_TIMEOUT
    def start
      ensure_rails_project!
      ensure_project_directories
      validate_session_name!(options[:target])

      # Check if already running using session info
      session_info = load_session_info
      if session_info && session_info[:process_pid]
        # Check if process is still running
        begin
          Process.kill(0, session_info[:process_pid])
          # Check if socket is ready
          if File.exist?(session_info[:socket_path])
            puts "Rails console is already running (PID: #{session_info[:process_pid]})"
            puts "Socket: #{session_info[:socket_path]}"
            return
          end
        rescue Errno::ESRCH
          # Process not found, clean up session
          clear_session_info
        end
      elsif session_info
        # Session file exists but no valid PID, clean up
        clear_session_info
      end

      adapter = create_rails_adapter(current_rails_env, options[:target], options[:command], options[:wait_timeout])

      puts 'Starting Rails console...'

      begin
        adapter.start
        puts '✓ Rails console started successfully'
        puts "  PID: #{adapter.process_pid}"
        puts "  Socket: #{adapter.socket_path}"

        # Save session info
        save_session_info(adapter)

        # Log session start
        log_session_event(adapter.process_pid, 'session_start', {
                            rails_env: current_rails_env,
                            socket_path: adapter.socket_path
                          })
      rescue StandardError => e
        puts "✗ Failed to start Rails console: #{e.message}"
        exit 1
      end
    end

    desc 'status', 'Show Rails console status'
    def status
      ensure_rails_project!
      validate_session_name!(options[:target])

      session_info = load_session_info

      if session_info.nil?
        puts 'No active Rails console session found'
        return
      end

      # Check if server is actually responsive
      adapter = create_rails_adapter(current_rails_env, options[:target])
      server_status = begin
        adapter.get_status
      rescue StandardError
        nil
      end
      process_running = server_status && server_status['success'] && server_status['running']

      if process_running
        rails_env = server_status['rails_env'] || 'unknown'
        console_pid = server_status['pid'] || 'unknown'

        puts '✓ Rails console is running'
        puts "  PID: #{console_pid}"
        puts "  Environment: #{rails_env}"
        puts "  Session: #{session_info[:socket_path]}"
        puts '  Ready for input: Yes'
      else
        puts '✗ Rails console is not running'
        clear_session_info
      end
    end

    desc 'ls', 'List active Rails console sessions'
    long_desc <<-LONGDESC
      Lists all active Rails console sessions in the current project.

      Shows information about each session including:
      - Session name (target)
      - Process ID (PID)
      - Rails environment
      - Status (running/stopped)

      Example output:
        Active sessions:
        - cone (default)  [PID: 12345, ENV: development, STATUS: running]
        - api             [PID: 12346, ENV: production, STATUS: running]
        - worker          [PID: 12347, ENV: development, STATUS: stopped]
    LONGDESC
    def ls
      ensure_rails_project!

      sessions = load_sessions

      if sessions.empty? || sessions.size == 1 && sessions.key?('_schema')
        puts 'No active sessions'
        return
      end

      active_sessions = []
      stale_sessions = []

      sessions.each do |name, info|
        next if name == '_schema' # Skip schema field

        # Check if process is alive
        if info['process_pid'] && process_alive?(info['process_pid'])
          # Try to get server status
      adapter = create_rails_adapter(current_rails_env, name)
          server_status = begin
            adapter.get_status
          rescue StandardError
            nil
          end

          if server_status && server_status['success'] && server_status['running']
            rails_env = server_status['rails_env'] || 'development'
            console_pid = server_status['pid'] || info['process_pid']
            active_sessions << "#{name} (#{rails_env}) - PID: #{console_pid}"
          else
            stale_sessions << name
          end
        else
          stale_sessions << name
        end
      end

      # Clean up stale sessions
      if stale_sessions.any?
        with_sessions_lock do
          sessions = load_sessions
          stale_sessions.each { |name| sessions.delete(name) }
          save_sessions(sessions)
        end
      end

      if active_sessions.empty?
        puts 'No active sessions'
      else
        active_sessions.each { |session| puts session }
      end
    end

    desc 'stop', 'Stop Rails console'
    def stop
      ensure_rails_project!
      validate_session_name!(options[:target])

      adapter = create_rails_adapter('development', options[:target])

      if adapter.running?
        puts 'Stopping Rails console...'

        if adapter.stop
          puts '✓ Rails console stopped'

          # Log session stop
          session_info = load_session_info
          if session_info && session_info[:process_pid]
            log_session_event(session_info[:process_pid], 'session_stop', {
                                reason: 'user_requested'
                              })
          end
        else
          puts '✗ Failed to stop Rails console'
        end
      else
        puts 'Rails console is not running'
      end

      clear_session_info
    end

    desc 'stop_all', 'Stop all Rails console sessions'
    map ['stop-all'] => :stop_all
    def stop_all
      ensure_rails_project!

      sessions = load_sessions
      active_sessions = []

      # Filter active sessions (excluding schema)
      sessions.each do |name, info|
        next if name == '_schema'

        active_sessions << { name: name, info: info } if info['process_pid'] && process_alive?(info['process_pid'])
      end

      if active_sessions.empty?
        puts 'No active sessions to stop'
        return
      end

      puts "Found #{active_sessions.size} active session(s)"

      # Stop each active session
      active_sessions.each do |session|
        name = session[:name]
        info = session[:info]

        puts "\nStopping session '#{name}'..."

        adapter = create_rails_adapter('development', name)

        if adapter.stop
          puts "✓ Session '#{name}' stopped"

          # Log session stop
          if info['process_pid']
            log_session_event(info['process_pid'], 'session_stop', {
                                reason: 'stop_all_requested'
                              })
          end

          # Clear session info
          with_sessions_lock do
            sessions = load_sessions
            sessions.delete(name)
            save_sessions(sessions)
          end
        else
          puts "✗ Failed to stop session '#{name}'"
        end
      end

      puts "\n✓ All sessions stopped"
    end

    desc 'restart', 'Restart Rails console'
    long_desc <<-LONGDESC
      Restarts the Rails console process.

      By default, only restarts the Rails console subprocess while keeping the#{' '}
      socket server running. This is faster and maintains socket connections.

      Use --force to restart the entire server including the socket server:
        cone restart           # Quick restart (subprocess only)
        cone restart --force   # Full restart (entire server)
      #{'  '}
      Target specific sessions:
        cone restart -t api
        cone restart --target worker --force
    LONGDESC
    method_option :force, type: :boolean, aliases: '-f', desc: 'Force restart the entire server'
    def restart
      ensure_rails_project!
      validate_session_name!(options[:target])

      adapter = create_rails_adapter(current_rails_env, options[:target])

      if adapter.running?
        # Check if environment needs to be changed
        current_status = begin
          adapter.get_status
        rescue StandardError
          nil
        end
        current_env = current_status&.dig('rails_env') || 'development'
        desired_env = current_rails_env
        needs_full_restart = options[:force] || (current_env != desired_env)

        if needs_full_restart
          if current_env != desired_env
            puts "Environment change detected (#{current_env} -> #{desired_env})"
            puts 'Performing full server restart...'
          else
            puts 'Force restarting Rails console server...'
          end

          stop
          sleep 1
          invoke(:start)
        else
          puts 'Restarting Rails console subprocess...'

          # Send restart request to the socket server
          request = {
            'action' => 'restart',
            'request_id' => SecureRandom.uuid
          }

          begin
            # Use direct socket connection for restart request
            socket = UNIXSocket.new(adapter.socket_path)
            socket.write(JSON.generate(request))
            socket.write("\n")
            socket.flush
            response_data = socket.gets
            socket.close

            response = JSON.parse(response_data)

            if response['success']
              puts '✓ Rails console subprocess restarted'
              puts "  New PID: #{response['pid']}" if response['pid']
            else
              puts "✗ Failed to restart: #{response['message']}"
              puts "You can try 'cone restart --force' to restart the entire server"
            end
          rescue StandardError => e
            puts "✗ Error restarting: #{e.message}"
            puts "You can try 'cone restart --force' to restart the entire server"
          end
        end
      else
        puts 'Rails console is not running. Starting it...'
        invoke(:start)
      end
    end

    desc 'exec CODE', 'Execute Ruby code in Rails console'
    long_desc <<-LONGDESC
      Executes Ruby code in the running Rails console and returns the result.

      Basic usage:
        cone exec 'User.count'
        cone exec 'Rails.env'
      #{'  '}
      Execute code from a file:
        cone exec -f script.rb
        cone exec --file complex_query.rb
      #{'  '}
      Set custom timeout for long-running operations:
        cone exec 'User.where(active: true).update_all(status: "verified")' --timeout 60
      #{'  '}
      Target specific console sessions:
        cone exec -t api 'Order.pending.count'
        cone exec --target worker 'Job.failed.destroy_all'
      #{'  '}
      The console must be started first with 'cone start'.
    LONGDESC
    method_option :timeout, type: :numeric, desc: 'Timeout in seconds', default: 60
    method_option :pre_sigint, type: :boolean, desc: 'Send Ctrl-C before executing code (experimental)'
    method_option :file, type: :string, aliases: '-f', desc: 'Read Ruby code from FILE'
    method_option :raw, type: :boolean, desc: 'Do not apply escape fixes for Claude Code (keep \\! as is)'
    def exec(*code_parts)
      ensure_rails_project!
      ensure_project_directories
      validate_session_name!(options[:target])

      # Handle code input from file or arguments first
      code = if options[:file]
               path = File.expand_path(options[:file])
               unless File.file?(path)
                 puts "Error: File not found: #{path}"
                 exit 1
               end
               File.read(path, mode: 'r:UTF-8')
             else
               code_parts.join(' ')
             end

      if code.strip.empty?
        puts 'Error: No code provided (pass CODE or use -f FILE)'
        exit 1
      end

      session_info = load_session_info
      server_running = false

      # Check if server is running
      if session_info
        begin
          # Try to connect to socket and get status
          socket = UNIXSocket.new(session_info[:socket_path])
          request = {
            'action' => 'status',
            'request_id' => SecureRandom.uuid
          }
          socket.write(JSON.generate(request))
          socket.write("\n")
          socket.flush
          response_data = socket.gets
          socket.close

          response = JSON.parse(response_data)
          server_running = response['success'] && response['running']
        rescue StandardError
          # Server not responsive
          server_running = false
        end
      end

      # Check if server is running
      unless server_running
        puts '✗ Rails console is not running'
        puts 'Please start it first with: cone start'
        exit 1
      end

      # Apply Claude Code escape fix unless --raw option is specified
      code = code.gsub('\\!', '!') unless options[:raw]

      puts "Executing: #{code}" if options[:verbose]

      # Send code to socket
      send_opts = { timeout: options[:timeout] }
      send_opts[:pre_sigint] = options[:pre_sigint] unless options[:pre_sigint].nil?
      result = send_code_to_socket(
        session_info[:socket_path],
        code,
        **send_opts
      )

      # Log the request and response
      log_session_activity(session_info[:process_pid], code, result)

      if result['success']
        # Always print result, even if empty (multiline code often returns empty string)
        puts result['result'] unless result['result'].nil?
        # Always show execution time when available
        puts "Execution time: #{result['execution_time'].round(3)}s" if result['execution_time']
      else
        # Display error information
        if result['error_code']
          puts "Error: #{result['error_code']}"
        else
          puts "Error: #{result['error']}"
        end
        
        # Show error class in verbose mode
        if options[:verbose] && result['error_class']
          puts "Error Class: #{result['error_class']}"
        end
        
        puts result['message']
        puts result['backtrace']&.join("\n") if options[:verbose] && result['backtrace']
        
        # Show execution time for errors too
        puts "Execution time: #{result['execution_time'].round(3)}s" if result['execution_time']
        
        exit 1
      end
    end

    private

    def ensure_rails_project!
      return if File.exist?('config/environment.rb') || File.exist?('config/application.rb')

      puts 'Error: This command must be run from a Rails project root directory'
      exit 1
    end

    def ensure_project_directories
      # Create tmp/cone directory for socket
      socket_dir = File.join(Dir.pwd, 'tmp', 'cone')
      FileUtils.mkdir_p(socket_dir) unless Dir.exist?(socket_dir)

      # Create session directory based on PWD
      session_dir = project_session_dir
      FileUtils.mkdir_p(session_dir) unless Dir.exist?(session_dir)
    end

    def project_session_dir
      # Convert PWD to directory name (Claude Code style)
      pwd_as_dirname = Dir.pwd.gsub('/', '-')
      File.expand_path("~/.cone/sessions/#{pwd_as_dirname}")
    end

    def project_socket_path(target = nil)
      target ||= options[:target]
      File.join(Dir.pwd, 'tmp', 'cone', "#{target}.socket")
    end

    def project_pid_path(target = nil)
      target ||= options[:target]
      File.join(Dir.pwd, 'tmp', 'cone', "#{target}.pid")
    end

    def project_log_path(target = nil)
      target ||= options[:target]
      File.join(Dir.pwd, 'tmp', 'cone', "#{target}.log")
    end

    def send_code_to_socket(socket_path, code, timeout: 60, pre_sigint: nil)
      request_id = SecureRandom.uuid
      # Ensure code is UTF-8 encoded
      code = code.force_encoding('UTF-8') if code.respond_to?(:force_encoding)
      
      # CONSOLLE_TIMEOUT takes highest priority on client side if present and > 0
      env_timeout = ENV['CONSOLLE_TIMEOUT']&.to_i
      effective_timeout = (env_timeout && env_timeout > 0) ? env_timeout : timeout

      request = {
        'action' => 'eval',
        'code' => code,
        'timeout' => effective_timeout,
        'request_id' => request_id
      }
      # Include pre_sigint flag only when explicitly provided (true/false)
      request['pre_sigint'] = pre_sigint unless pre_sigint.nil?

      STDERR.puts "[DEBUG] Creating socket connection to: #{socket_path}" if ENV['DEBUG']
      
      Timeout.timeout(effective_timeout + 5) do
        socket = UNIXSocket.new(socket_path)
        STDERR.puts "[DEBUG] Socket connected" if ENV['DEBUG']

        # Send request as single line JSON with UTF-8 encoding
        json_data = JSON.generate(request)
        STDERR.puts "[DEBUG] JSON data size: #{json_data.bytesize} bytes" if ENV['DEBUG']
        
        # Debug: Check for newlines in JSON
        if ENV['DEBUG'] && json_data.include?("\n")
          STDERR.puts "[DEBUG] WARNING: JSON contains literal newline!"
          File.write("/tmp/cone_debug.json", json_data) if ENV['DEBUG_SAVE']
        end
        
        STDERR.puts "[DEBUG] Sending request..." if ENV['DEBUG']
        
        socket.write(json_data)
        socket.write("\n")
        socket.flush
        
        STDERR.puts "[DEBUG] Request sent, waiting for response..." if ENV['DEBUG']

        # Read response - handle large responses by reading all available data
        response_data = +''
        begin
          # Read until we get a newline (end of JSON response)
          while (chunk = socket.read_nonblock(65536)) # Read in 64KB chunks
            response_data << chunk
            break if response_data.include?("\n")
          end
        rescue IO::WaitReadable
          IO.select([socket], nil, nil, 1)
          retry if response_data.empty? || !response_data.include?("\n")
        rescue EOFError
          # Server closed connection
        end
        
        STDERR.puts "[DEBUG] Response received: #{response_data&.bytesize} bytes" if ENV['DEBUG']
        socket.close

        # Extract just the first line (the JSON response)
        json_line = response_data.split("\n").first
        JSON.parse(json_line) if json_line
      end
    rescue Timeout::Error
      STDERR.puts "[DEBUG] Timeout occurred after #{effective_timeout} seconds" if ENV['DEBUG']
      { 'success' => false, 'error' => 'Timeout', 'message' => "Request timed out after #{effective_timeout} seconds" }
    rescue StandardError => e
      STDERR.puts "[DEBUG] Error: #{e.class}: #{e.message}" if ENV['DEBUG']
      { 'success' => false, 'error' => e.class.name, 'message' => e.message }
    end

    def sessions_file_path
      File.join(Dir.pwd, 'tmp', 'cone', 'sessions.json')
    end

    def create_rails_adapter(rails_env = 'development', target = nil, command = nil, wait_timeout = nil)
      target ||= options[:target]

      Consolle::Adapters::RailsConsole.new(
        socket_path: project_socket_path(target),
        pid_path: project_pid_path(target),
        log_path: project_log_path(target),
        rails_root: Dir.pwd,
        rails_env: rails_env,
        verbose: options[:verbose],
        command: command,
        wait_timeout: wait_timeout
      )
    end

    def save_session_info(adapter)
      target = options[:target]

      with_sessions_lock do
        sessions = load_sessions

        sessions[target] = {
          'socket_path' => adapter.socket_path,
          'process_pid' => adapter.process_pid,
          'pid_path' => project_pid_path(target),
          'log_path' => project_log_path(target),
          'started_at' => Time.now.to_f,
          'rails_root' => Dir.pwd
        }

        save_sessions(sessions)
      end
    end

    def load_session_info
      target = options[:target]
      sessions = load_sessions

      return nil if sessions.empty?

      session = sessions[target]
      return nil unless session

      # Convert to symbolized keys for backward compatibility
      {
        socket_path: session['socket_path'],
        process_pid: session['process_pid'],
        started_at: session['started_at'],
        rails_root: session['rails_root']
      }
    end

    def clear_session_info
      target = options[:target]

      with_sessions_lock do
        sessions = load_sessions
        sessions.delete(target)
        save_sessions(sessions)
      end
    end

    def log_session_activity(process_pid, code, result)
      # Create log filename based on date and PID
      log_file = File.join(project_session_dir, "session_#{Date.today.strftime('%Y%m%d')}_pid#{process_pid}.log")

      # Create log entry
      log_entry = {
        timestamp: Time.now.iso8601,
        request_id: result['request_id'],
        code: code,
        success: result['success'],
        result: result['result'],
        error: result['error'],
        message: result['message'],
        execution_time: result['execution_time']
      }

      # Append to log file
      File.open(log_file, 'a') do |f|
        f.puts JSON.generate(log_entry)
      end
    rescue StandardError => e
      # Log errors should not crash the command
      puts "Warning: Failed to log session activity: #{e.message}" if options[:verbose]
    end

    def log_session_event(process_pid, event_type, details = {})
      # Create log filename based on date and PID
      log_file = File.join(project_session_dir, "session_#{Date.today.strftime('%Y%m%d')}_pid#{process_pid}.log")

      # Create log entry
      log_entry = {
        timestamp: Time.now.iso8601,
        event: event_type
      }.merge(details)

      # Append to log file
      File.open(log_file, 'a') do |f|
        f.puts JSON.generate(log_entry)
      end
    rescue StandardError => e
      # Log errors should not crash the command
      puts "Warning: Failed to log session event: #{e.message}" if options[:verbose]
    end

    def load_sessions
      # Check for legacy session.json file first
      legacy_file = File.join(Dir.pwd, 'tmp', 'cone', 'session.json')
      if File.exist?(legacy_file) && !File.exist?(sessions_file_path)
        # Migrate from old format
        migrate_legacy_session(legacy_file)
      end

      return {} unless File.exist?(sessions_file_path)

      json = JSON.parse(File.read(sessions_file_path))

      # Handle backward compatibility with old single-session format
      if json.key?('socket_path')
        # Legacy single session format - convert to new format
        { 'cone' => json }
      else
        # New multi-session format
        json
      end
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end

    def migrate_legacy_session(legacy_file)
      legacy_data = JSON.parse(File.read(legacy_file))

      # Convert to new format
      new_sessions = {
        '_schema' => 1,
        'cone' => legacy_data
      }

      # Write new format
      File.write(sessions_file_path, JSON.pretty_generate(new_sessions))

      # Remove old file
      File.delete(legacy_file)

      puts 'Migrated session data to new multi-session format' if options[:verbose]
    rescue StandardError => e
      puts "Warning: Failed to migrate legacy session: #{e.message}" if options[:verbose]
    end

    def save_sessions(sessions)
      # Add schema version for future migrations
      sessions_with_schema = { '_schema' => 1 }.merge(sessions)

      # Write to temp file first for atomicity - use PID to avoid conflicts
      temp_path = "#{sessions_file_path}.tmp.#{Process.pid}"
      File.write(temp_path, JSON.pretty_generate(sessions_with_schema))

      # Atomic rename - will overwrite existing file
      File.rename(temp_path, sessions_file_path)
    rescue StandardError => e
      # Clean up temp file if rename fails
      File.unlink(temp_path) if File.exist?(temp_path)
      raise e
    end

    def with_sessions_lock
      # Ensure directory exists
      FileUtils.mkdir_p(File.dirname(sessions_file_path))

      # Create lock file separate from sessions file to avoid issues
      lock_file_path = "#{sessions_file_path}.lock"

      # Use file locking to prevent concurrent access
      File.open(lock_file_path, File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)

        # Execute the block
        yield
      ensure
        f.flock(File::LOCK_UN)
      end
    end

    def process_alive?(pid)
      return false unless pid

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def validate_session_name!(name)
      # Allow alphanumeric, hyphen, and underscore only
      unless name.match?(/\A[a-zA-Z0-9_-]+\z/)
        puts "Error: Invalid session name '#{name}'"
        puts 'Session names can only contain letters, numbers, hyphens (-), and underscores (_)'
        exit 1
      end

      # Check length (reasonable limit)
      return unless name.length > 50

      puts 'Error: Session name is too long (maximum 50 characters)'
      exit 1
    end
  end
end
