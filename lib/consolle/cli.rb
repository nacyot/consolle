# frozen_string_literal: true

require 'thor'
require 'fileutils'
require 'json'
require 'socket'
require 'timeout'
require 'securerandom'
require 'date'
require_relative 'constants'
require_relative 'session_registry'
require_relative 'history'
require_relative 'adapters/rails_console'

module Consolle
  # Rails convenience commands subcommand
  class RailsCommands < Thor
    namespace :rails

    class_option :verbose, type: :boolean, aliases: '-v', desc: 'Verbose output'
    class_option :target, type: :string, aliases: '-t', desc: 'Target session name', default: 'cone'

    desc 'reload', 'Reload Rails application code (reload!)'
    def reload
      execute_rails_code('reload!')
    end

    desc 'env', 'Show current Rails environment'
    def env
      execute_rails_code('Rails.env')
    end

    desc 'db', 'Show database connection information'
    def db
      code = <<~RUBY
        config = ActiveRecord::Base.connection_db_config
        puts "Adapter:  \#{config.adapter}"
        puts "Database: \#{config.database}"
        puts "Host:     \#{config.host || 'localhost'}" if config.respond_to?(:host)
        puts "Pool:     \#{config.pool}" if config.respond_to?(:pool)
        puts "Connected: \#{ActiveRecord::Base.connected?}"
        nil
      RUBY
      execute_rails_code(code)
    end

    private

    def execute_rails_code(code)
      # Delegate to main CLI's exec command
      cli = Consolle::CLI.new
      cli.options = {
        target: options[:target] || 'cone',
        verbose: options[:verbose] || false,
        timeout: 60,
        raw: false
      }
      cli.exec(code)
    rescue SystemExit
      # Allow exit from exec
      raise
    end
  end

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
          shell.say '  cone rails SUBCOMMAND   # Rails convenience commands'
          shell.say '  cone ls                 # List active sessions (use -a for all)'
          shell.say '  cone history            # Show command history'
          shell.say '  cone rm SESSION         # Remove session and its history'
          shell.say '  cone prune              # Remove all stopped sessions'
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

    # Register rails subcommand
    desc 'rails SUBCOMMAND', 'Rails convenience commands (reload, env, db)'
    subcommand 'rails', RailsCommands

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

      Supervisor modes (--mode):
        pty         - Traditional PTY-based mode, supports custom commands (default)
        embed-irb   - Pure IRB embedding, Ruby 3.3+ only
        embed-rails - Rails console embedding, Ruby 3.3+ only

      Custom console commands are supported for PTY mode:
        cone start --command "kamal app exec -i 'bin/rails console'"
        cone start --command "docker exec -it myapp bin/rails console"

      For SSH-based commands that require authentication (e.g., 1Password SSH agent):
        cone start --command "kamal console" --wait-timeout 60

      Use embedded modes for faster local execution (200x faster):
        cone start --mode embed-rails
        cone start --mode embed-irb
    LONGDESC
    # Rails environment is now controlled via RAILS_ENV, not a CLI option
    method_option :mode, type: :string, aliases: '-m', desc: 'Supervisor mode: pty, embed-irb, embed-rails'
    method_option :command, type: :string, aliases: '-c', desc: 'Custom console command (PTY mode only)', default: 'bin/rails console'
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

      adapter = create_rails_adapter(
        current_rails_env,
        options[:target],
        options[:command],
        options[:wait_timeout],
        options[:mode]
      )

      puts 'Starting Rails console...'

      begin
        adapter.start

        # Register session in registry
        session = session_registry.create_session(
          target: options[:target],
          socket_path: adapter.socket_path,
          pid: adapter.process_pid,
          rails_env: current_rails_env,
          mode: options[:mode] || 'pty'
        )

        puts '✓ Rails console started'
        puts "  Session ID: #{session['id']} (#{session['short_id']})"
        puts "  Target: #{session['target']}"
        puts "  Environment: #{current_rails_env}"
        puts "  PID: #{adapter.process_pid}"
        puts "  Socket: #{adapter.socket_path}"

        # Also save to legacy sessions.json for backward compatibility
        save_session_info(adapter, session['id'])
      rescue StandardError => e
        puts "✗ Failed to start Rails console: #{e.message}"
        exit 1
      end
    end

    desc 'status', 'Show Rails console status'
    def status
      ensure_rails_project!
      validate_session_name!(options[:target])

      # Try to find session in registry first
      session = session_registry.find_running_session(target: options[:target])
      session_info = load_session_info

      if session_info.nil? && session.nil?
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
        uptime = session_info&.dig(:started_at) ? format_uptime(Time.now - Time.at(session_info[:started_at])) : 'unknown'
        command_count = session ? session['command_count'] : 0

        puts '✓ Rails console is running'
        if session
          puts "  Session ID: #{session['id']} (#{session['short_id']})"
        end
        puts "  Target: #{options[:target]}"
        puts "  Environment: #{rails_env}"
        puts "  PID: #{console_pid}"
        puts "  Uptime: #{uptime}"
        puts "  Commands: #{command_count}"
        puts "  Socket: #{session_info&.dig(:socket_path) || session&.dig('socket_path')}"
      else
        puts '✗ Rails console is not running'
        # Mark session as stopped in registry
        session_registry.stop_session(target: options[:target], reason: 'process_died') if session
        clear_session_info
      end
    end

    desc 'ls', 'List Rails console sessions'
    long_desc <<-LONGDESC
      Lists Rails console sessions in the current project.

      By default, shows only active (running) sessions.
      Use -a/--all to include stopped sessions.

      Shows information about each session including:
      - Session ID (short)
      - Target name
      - Rails environment
      - Status (running/stopped)
      - Uptime or stop time
      - Command count

      Example output:
        ID       TARGET   ENV          STATUS    UPTIME    COMMANDS
        a1b2     cone     development  running   2h 15m    42
        e5f6     api      production   running   1h 30m    15
    LONGDESC
    method_option :all, type: :boolean, aliases: '-a', desc: 'Include stopped sessions'
    def ls
      ensure_rails_project!

      include_stopped = options[:all]
      sessions = session_registry.list_sessions(include_stopped: include_stopped)

      # Also check legacy sessions.json for backward compatibility
      legacy_sessions = load_sessions
      legacy_sessions.each do |name, info|
        next if name == '_schema'
        next unless info['process_pid'] && process_alive?(info['process_pid'])

        # Check if already in registry
        existing = sessions.find { |s| s['target'] == name && s['status'] == 'running' }
        next if existing

        # Add legacy session (will be migrated on next start)
        sessions << {
          'short_id' => '----',
          'target' => name,
          'rails_env' => 'development',
          'status' => 'running',
          'pid' => info['process_pid'],
          'created_at' => info['started_at'] ? Time.at(info['started_at']).iso8601 : Time.now.iso8601,
          'command_count' => 0,
          '_legacy' => true
        }
      end

      if sessions.empty?
        if include_stopped
          puts 'No sessions found'
        else
          puts 'No active sessions'
          puts "Use 'cone ls -a' to see stopped sessions"
        end
        return
      end

      # Verify running sessions are actually running
      sessions.each do |session|
        next unless session['status'] == 'running'
        next if session['_legacy']

        unless session['pid'] && process_alive?(session['pid'])
          session_registry.stop_session(session_id: session['id'], reason: 'process_died')
          session['status'] = 'stopped'
        end
      end

      # Re-filter if needed
      sessions = sessions.select { |s| s['status'] == 'running' } unless include_stopped

      if sessions.empty?
        puts 'No active sessions'
        puts "Use 'cone ls -a' to see stopped sessions"
        return
      end

      # Display header
      if include_stopped
        puts 'ALL SESSIONS:'
      else
        puts 'ACTIVE SESSIONS:'
      end
      puts
      puts format('  %-8s %-12s %-12s %-9s %-10s %s', 'ID', 'TARGET', 'ENV', 'STATUS', 'UPTIME', 'COMMANDS')

      sessions.each do |session|
        short_id = session['short_id'] || session['id']&.[](0, 4) || '----'
        target = session['target'] || 'unknown'
        env = session['rails_env'] || 'dev'
        status = session['status'] || 'unknown'
        commands = session['command_count'] || 0

        if session['status'] == 'running'
          started = session['started_at'] || session['created_at']
          uptime = started ? format_uptime(Time.now - Time.parse(started)) : '---'
        else
          stopped = session['stopped_at']
          uptime = stopped ? format_time_ago(Time.now - Time.parse(stopped)) : '---'
        end

        puts format('  %-8s %-12s %-12s %-9s %-10s %d', short_id, target, env, status, uptime, commands)
      end

      puts
      if include_stopped
        puts "Use 'cone history --session ID' to view session history"
        puts "Use 'cone rm ID' to remove session and history"
      else
        puts 'Usage: cone exec -t TARGET CODE'
        puts '       cone exec --session ID CODE'
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

          # Mark session as stopped in registry (preserves history)
          session_registry.stop_session(target: options[:target], reason: 'user_requested')
        else
          puts '✗ Failed to stop Rails console'
        end
      else
        puts 'Rails console is not running'
        # Mark as stopped anyway in case registry is out of sync
        session_registry.stop_session(target: options[:target], reason: 'not_running')
      end

      clear_session_info
    end

    desc 'stop_all', 'Stop all Rails console sessions'
    map ['stop-all'] => :stop_all
    def stop_all
      ensure_rails_project!

      # Get running sessions from registry
      running_sessions = session_registry.list_sessions(include_stopped: false)

      # Also check legacy sessions
      legacy_sessions = load_sessions
      legacy_sessions.each do |name, info|
        next if name == '_schema'
        next unless info['process_pid'] && process_alive?(info['process_pid'])

        existing = running_sessions.find { |s| s['target'] == name }
        next if existing

        running_sessions << { 'target' => name, 'pid' => info['process_pid'], '_legacy' => true }
      end

      if running_sessions.empty?
        puts 'No active sessions to stop'
        return
      end

      puts "Found #{running_sessions.size} active session(s)"

      # Stop each active session
      running_sessions.each do |session|
        name = session['target']

        puts "\nStopping session '#{name}'..."

        adapter = create_rails_adapter('development', name)

        if adapter.stop
          puts "✓ Session '#{name}' stopped"

          # Mark session as stopped in registry
          session_registry.stop_session(target: name, reason: 'stop_all_requested') unless session['_legacy']

          # Clear from legacy sessions.json
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
          invoke(:start, [], {})
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
        # Show execution time only in verbose mode
        puts "Execution time: #{result['execution_time'].round(3)}s" if options[:verbose] && result['execution_time']
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

        # Show execution time for errors too (verbose only)
        puts "Execution time: #{result['execution_time'].round(3)}s" if options[:verbose] && result['execution_time']

        exit 1
      end
    end

    desc 'rm SESSION_ID', 'Remove session and its history'
    long_desc <<-LONGDESC
      Removes a stopped session and all its history.

      The SESSION_ID can be:
      - Full session ID (8 characters, e.g., a1b2c3d4)
      - Short session ID (4 characters, e.g., a1b2)
      - Target name (e.g., cone, api)

      Running sessions cannot be removed. Stop them first with 'cone stop -t TARGET'.

      Use -f/--force to skip confirmation prompt.
      Use -f/--force with a running session to stop and remove it.

      Examples:
        cone rm a1b2              # Remove by short ID
        cone rm a1b2c3d4          # Remove by full ID
        cone rm -f a1b2           # Remove without confirmation
    LONGDESC
    method_option :force, type: :boolean, aliases: '-f', desc: 'Skip confirmation (or force stop running session)'
    def rm(session_id)
      ensure_rails_project!

      # Try to find session
      session = session_registry.find_session(session_id: session_id) ||
                session_registry.find_session(target: session_id)

      unless session
        puts "✗ Session not found: #{session_id}"
        puts "Use 'cone ls -a' to see all sessions"
        exit 1
      end

      # Check if running
      if session['status'] == 'running'
        if options[:force]
          # Force stop first
          puts "Stopping running session '#{session['target']}'..."
          adapter = create_rails_adapter('development', session['target'])
          adapter.stop
          session_registry.stop_session(session_id: session['id'], reason: 'force_remove')
          clear_session_info if options[:target] == session['target']
        else
          puts "✗ Session #{session['short_id']} (#{session['target']}) is still running"
          puts "  Use 'cone stop -t #{session['target']}' first, or 'cone rm -f #{session_id}' to force"
          exit 1
        end
      end

      # Confirm deletion
      unless options[:force]
        command_count = session['command_count'] || 0
        print "Remove session #{session['id']} (#{session['target']}, #{command_count} commands)?\n"
        print 'This will permanently delete all history. [y/N]: '
        response = $stdin.gets&.strip&.downcase
        unless response == 'y' || response == 'yes'
          puts 'Cancelled'
          return
        end
      end

      # Remove session
      result = session_registry.remove_session(session_id: session['id'])

      if result && !result.is_a?(Hash)
        puts "✓ Session #{session['id']} removed"
      else
        puts "✗ Failed to remove session"
        exit 1
      end
    end

    desc 'prune', 'Remove all stopped sessions'
    long_desc <<-LONGDESC
      Removes all stopped sessions and their history.

      By default, only removes sessions from the current project.

      Use --yes to skip confirmation prompt.

      Examples:
        cone prune                # Remove stopped sessions (with confirmation)
        cone prune --yes          # Remove without confirmation
    LONGDESC
    method_option :yes, type: :boolean, aliases: '-y', desc: 'Skip confirmation'
    def prune
      ensure_rails_project!

      stopped = session_registry.list_stopped_sessions

      if stopped.empty?
        puts 'No stopped sessions to remove'
        return
      end

      # Show what will be removed
      total_commands = stopped.sum { |s| s['command_count'] || 0 }

      puts "Found #{stopped.size} stopped session(s):"
      stopped.each do |session|
        stopped_at = session['stopped_at'] ? Time.parse(session['stopped_at']).strftime('%Y-%m-%d') : '---'
        commands = session['command_count'] || 0
        puts "  #{session['short_id']}  #{session['target'].ljust(12)} stopped #{stopped_at}  #{commands} commands"
      end
      puts

      # Confirm
      unless options[:yes]
        print "Remove all stopped sessions and their history? [y/N]: "
        response = $stdin.gets&.strip&.downcase
        unless response == 'y' || response == 'yes'
          puts 'Cancelled'
          return
        end
      end

      # Remove all stopped sessions
      removed = session_registry.prune_sessions

      puts "✓ Removed #{removed.size} sessions (#{total_commands} commands)"
    end

    desc 'history', 'Show command history'
    long_desc <<-LONGDESC
      Shows command history for sessions.

      By default, shows history from the current active session (target).

      Options:
        --session ID    Show history for specific session (by ID or short ID)
        -t, --target    Show history for specific target name
        -n, --limit     Limit number of entries shown
        --today         Show only today's commands
        --date DATE     Show commands from specific date (YYYY-MM-DD)
        --success       Show only successful commands
        --failed        Show only failed commands
        --grep PATTERN  Filter by code or result matching pattern
        --all           Include history from stopped sessions with same target
        -v, --verbose   Show detailed output
        --json          Output as JSON

      Examples:
        cone history                    # Current session history
        cone history -t api             # History for 'api' target
        cone history --session a1b2     # History for specific session
        cone history -n 10              # Last 10 commands
        cone history --today            # Today's commands only
        cone history --failed           # Failed commands only
        cone history --grep User        # Filter by pattern
    LONGDESC
    method_option :session, type: :string, aliases: '-s', desc: 'Session ID or short ID'
    method_option :limit, type: :numeric, aliases: '-n', desc: 'Limit number of entries'
    method_option :today, type: :boolean, desc: 'Show only today'
    method_option :date, type: :string, desc: 'Show specific date (YYYY-MM-DD)'
    method_option :success, type: :boolean, desc: 'Show only successful commands'
    method_option :failed, type: :boolean, desc: 'Show only failed commands'
    method_option :grep, type: :string, aliases: '-g', desc: 'Filter by pattern'
    method_option :all, type: :boolean, desc: 'Include stopped sessions'
    method_option :json, type: :boolean, desc: 'Output as JSON'
    def history
      ensure_rails_project!

      history_manager = Consolle::History.new

      entries = history_manager.query(
        session_id: options[:session],
        target: options[:target],
        limit: options[:limit],
        today: options[:today],
        date: options[:date],
        success_only: options[:success],
        failed_only: options[:failed],
        grep: options[:grep],
        all_sessions: options[:all]
      )

      if entries.empty?
        puts 'No history found'
        if options[:session] || options[:target]
          puts "Try 'cone history' without filters to see all history"
        else
          puts "Execute some commands first with 'cone exec'"
        end
        return
      end

      if options[:json]
        puts history_manager.format_json(entries)
      elsif options[:verbose]
        entries.each do |entry|
          puts history_manager.format_entry_verbose(entry)
          puts
        end
      else
        entries.each do |entry|
          puts history_manager.format_entry(entry)
          puts
        end
      end

      unless options[:json]
        puts "Showing #{entries.size} entries"
      end
    end

    private

    def current_rails_env
      ENV['RAILS_ENV'] || 'development'
    end

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

    def create_rails_adapter(rails_env = 'development', target = nil, command = nil, wait_timeout = nil, mode = nil)
      target ||= options[:target]

      Consolle::Adapters::RailsConsole.new(
        socket_path: project_socket_path(target),
        pid_path: project_pid_path(target),
        log_path: project_log_path(target),
        rails_root: Dir.pwd,
        rails_env: rails_env,
        verbose: options[:verbose],
        command: command,
        wait_timeout: wait_timeout,
        mode: mode
      )
    end

    def save_session_info(adapter, session_id = nil)
      target = options[:target]

      with_sessions_lock do
        sessions = load_sessions

        sessions[target] = {
          'socket_path' => adapter.socket_path,
          'process_pid' => adapter.process_pid,
          'pid_path' => project_pid_path(target),
          'log_path' => project_log_path(target),
          'started_at' => Time.now.to_f,
          'rails_root' => Dir.pwd,
          'session_id' => session_id
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
        rails_root: session['rails_root'],
        session_id: session['session_id']
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
      # Try to use new History class if session_id is available
      session_info = load_session_info
      if session_info&.dig(:session_id)
        history_manager = Consolle::History.new
        history_manager.log_command(
          session_id: session_info[:session_id],
          target: options[:target],
          code: code,
          result: result
        )
      else
        # Fallback to legacy logging
        log_file = File.join(project_session_dir, "session_#{Date.today.strftime('%Y%m%d')}_pid#{process_pid}.log")

        log_entry = {
          timestamp: Time.now.iso8601,
          target: options[:target],
          request_id: result['request_id'],
          code: code,
          success: result['success'],
          result: result['result'],
          error: result['error'],
          message: result['message'],
          execution_time: result['execution_time']
        }

        File.open(log_file, 'a') do |f|
          f.puts JSON.generate(log_entry)
        end
      end
    rescue StandardError => e
      # Log errors should not crash the command
      puts "Warning: Failed to log session activity: #{e.message}" if options[:verbose]
    end

    def log_session_event(_process_pid, _event_type, _details = {})
      # Legacy method kept for backward compatibility with tests
      # Session events are now tracked in registry metadata
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

    def session_registry
      @session_registry ||= Consolle::SessionRegistry.new
    end

    def format_uptime(seconds)
      seconds = seconds.to_i
      if seconds < 60
        "#{seconds}s"
      elsif seconds < 3600
        "#{seconds / 60}m #{seconds % 60}s"
      elsif seconds < 86400
        hours = seconds / 3600
        mins = (seconds % 3600) / 60
        "#{hours}h #{mins}m"
      else
        days = seconds / 86400
        hours = (seconds % 86400) / 3600
        "#{days}d #{hours}h"
      end
    end

    def format_time_ago(seconds)
      seconds = seconds.to_i
      if seconds < 60
        'just now'
      elsif seconds < 3600
        "#{seconds / 60}m ago"
      elsif seconds < 86400
        "#{seconds / 3600}h ago"
      else
        days = seconds / 86400
        "#{days}d ago"
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
