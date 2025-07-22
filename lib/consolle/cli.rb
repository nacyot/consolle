# frozen_string_literal: true

require "thor"
require "fileutils"
require "json"
require "socket"
require "timeout"
require "securerandom"
require "date"
require_relative "adapters/rails_console"

module Consolle
  class CLI < Thor
    class_option :verbose, type: :boolean, aliases: "-v", desc: "Verbose output"
    class_option :target, type: :string, aliases: "-t", desc: "Target session name", default: "cone"

    def self.exit_on_failure?
      true
    end

    default_task :default

    desc "default", "Start console"
    def default
      start
    end

    desc "version", "Show consolle version"
    def version
      puts "Consolle version #{Consolle::VERSION}"
    end

    desc "rule FILE", "Write cone command guide to FILE"
    def rule(file_path)
      # Read the embedded rule content
      rule_content = File.read(File.expand_path("../../../rule.md", __FILE__))
      
      # Write to the specified file
      File.write(file_path, rule_content)
      puts "✓ Cone command guide written to #{file_path}"
    rescue => e
      puts "✗ Failed to write rule file: #{e.message}"
      exit 1
    end

    desc "start", "Start Rails console in background"
    method_option :rails_env, type: :string, aliases: "-e", desc: "Rails environment", default: "development"
    method_option :command, type: :string, aliases: "-c", desc: "Custom console command", default: "bin/rails console"
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
      
      adapter = create_rails_adapter(options[:rails_env], options[:target], options[:command])

      puts "Starting Rails console..."
      
      begin
        adapter.start
        puts "✓ Rails console started successfully"
        puts "  PID: #{adapter.process_pid}"
        puts "  Socket: #{adapter.socket_path}"
        
        # Save session info
        save_session_info(adapter)
        
        # Log session start
        log_session_event(adapter.process_pid, "session_start", {
          rails_env: options[:rails_env],
          socket_path: adapter.socket_path
        })
      rescue StandardError => e
        puts "✗ Failed to start Rails console: #{e.message}"
        exit 1
      end
    end

    desc "status", "Show Rails console status"
    def status
      ensure_rails_project!
      validate_session_name!(options[:target])
      
      session_info = load_session_info
      
      if session_info.nil?
        puts "No active Rails console session found"
        return
      end

      # Check if server is actually responsive
      adapter = create_rails_adapter("development", options[:target])
      server_status = adapter.get_status rescue nil
      process_running = server_status && server_status["success"] && server_status["running"]
      
      if process_running
        rails_env = server_status["rails_env"] || "unknown"
        console_pid = server_status["pid"] || "unknown"
        
        puts "✓ Rails console is running"
        puts "  PID: #{console_pid}"
        puts "  Environment: #{rails_env}"
        puts "  Session: #{session_info[:socket_path]}"
        puts "  Ready for input: Yes"
      else
        puts "✗ Rails console is not running"
        clear_session_info
      end
    end

    desc "ls", "List active Rails console sessions"
    def ls
      ensure_rails_project!
      
      sessions = load_sessions
      
      if sessions.empty? || sessions.size == 1 && sessions.key?("_schema")
        puts "No active sessions"
        return
      end
      
      active_sessions = []
      stale_sessions = []
      
      sessions.each do |name, info|
        next if name == "_schema"  # Skip schema field
        
        # Check if process is alive
        if info["process_pid"] && process_alive?(info["process_pid"])
          # Try to get server status
          adapter = create_rails_adapter("development", name)
          server_status = adapter.get_status rescue nil
          
          if server_status && server_status["success"] && server_status["running"]
            rails_env = server_status["rails_env"] || "development"
            console_pid = server_status["pid"] || info["process_pid"]
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
        puts "No active sessions"
      else
        active_sessions.each { |session| puts session }
      end
    end

    desc "stop", "Stop Rails console"
    def stop
      ensure_rails_project!
      validate_session_name!(options[:target])
      
      adapter = create_rails_adapter("development", options[:target])
      
      if adapter.running?
        puts "Stopping Rails console..."
        
        if adapter.stop
          puts "✓ Rails console stopped"
          
          # Log session stop
          session_info = load_session_info
          if session_info && session_info[:process_pid]
            log_session_event(session_info[:process_pid], "session_stop", {
              reason: "user_requested"
            })
          end
        else
          puts "✗ Failed to stop Rails console"
        end
      else
        puts "Rails console is not running"
      end
      
      clear_session_info
    end

    desc "restart", "Restart Rails console"
    method_option :rails_env, type: :string, aliases: "-e", desc: "Rails environment", default: "development"
    method_option :force, type: :boolean, aliases: "-f", desc: "Force restart the entire server"
    def restart
      ensure_rails_project!
      validate_session_name!(options[:target])
      
      adapter = create_rails_adapter(options[:rails_env], options[:target])
      
      if adapter.running?
        # Check if environment needs to be changed
        current_status = adapter.get_status rescue nil
        current_env = current_status&.dig("rails_env") || "development"
        needs_full_restart = options[:force] || (current_env != options[:rails_env])
        
        if needs_full_restart
          if current_env != options[:rails_env]
            puts "Environment change detected (#{current_env} -> #{options[:rails_env]})"
            puts "Performing full server restart..."
          else
            puts "Force restarting Rails console server..."
          end
          
          # Save current rails_env for start command
          old_env = @rails_env
          @rails_env = options[:rails_env]
          
          stop
          sleep 1
          invoke(:start, [], { rails_env: options[:rails_env] })
          
          @rails_env = old_env
        else
          puts "Restarting Rails console subprocess..."
          
          # Send restart request to the socket server
          request = {
            "action" => "restart",
            "request_id" => SecureRandom.uuid
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
            
            if response["success"]
              puts "✓ Rails console subprocess restarted"
              puts "  New PID: #{response["pid"]}" if response["pid"]
            else
              puts "✗ Failed to restart: #{response["message"]}"
              puts "You can try 'cone restart --force' to restart the entire server"
            end
          rescue StandardError => e
            puts "✗ Error restarting: #{e.message}"
            puts "You can try 'cone restart --force' to restart the entire server"
          end
        end
      else
        puts "Rails console is not running. Starting it..."
        invoke(:start, [], { rails_env: options[:rails_env] })
      end
    end

    desc "exec CODE", "Execute Ruby code in Rails console"
    method_option :timeout, type: :numeric, aliases: "-t", desc: "Timeout in seconds", default: 15
    method_option :file, type: :string, aliases: "-f", desc: "Read Ruby code from FILE"
    method_option :raw, type: :boolean, desc: "Do not apply escape fixes for Claude Code (keep \\! as is)"
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
        File.read(path, mode: "r:UTF-8")
      else
        code_parts.join(" ")
      end

      if code.strip.empty?
        puts "Error: No code provided (pass CODE or use -f FILE)"
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
            "action" => "status",
            "request_id" => SecureRandom.uuid
          }
          socket.write(JSON.generate(request))
          socket.write("\n")
          socket.flush
          response_data = socket.gets
          socket.close
          
          response = JSON.parse(response_data)
          server_running = response["success"] && response["running"]
        rescue StandardError
          # Server not responsive
          server_running = false
        end
      end
      
      # Check if server is running
      unless server_running
        puts "✗ Rails console is not running"
        puts "Please start it first with: cone start"
        exit 1
      end

      # Apply Claude Code escape fix unless --raw option is specified
      unless options[:raw]
        code = code.gsub('\\!', '!')
      end

      puts "Executing: #{code}" if options[:verbose]
      
      # Send code to socket
      result = send_code_to_socket(session_info[:socket_path], code, timeout: options[:timeout])
      
      # Log the request and response
      log_session_activity(session_info[:process_pid], code, result)
      
      if result["success"]
        # Always print result, even if empty (multiline code often returns empty string)
        puts result["result"] unless result["result"].nil?
        puts "Execution time: #{result["execution_time"]}s" if options[:verbose] && result["execution_time"]
      else
        puts "Error: #{result["error"]}"
        puts result["message"]
        puts result["backtrace"]&.join("\n") if options[:verbose]
        exit 1
      end
    end

    private

    def ensure_rails_project!
      unless File.exist?("config/environment.rb") || File.exist?("config/application.rb")
        puts "Error: This command must be run from a Rails project root directory"
        exit 1
      end
    end

    def ensure_project_directories
      # Create tmp/cone directory for socket
      socket_dir = File.join(Dir.pwd, "tmp", "cone")
      FileUtils.mkdir_p(socket_dir) unless Dir.exist?(socket_dir)
      
      # Create session directory based on PWD
      session_dir = project_session_dir
      FileUtils.mkdir_p(session_dir) unless Dir.exist?(session_dir)
    end

    def project_session_dir
      # Convert PWD to directory name (Claude Code style)
      pwd_as_dirname = Dir.pwd.gsub("/", "-")
      File.expand_path("~/.cone/sessions/#{pwd_as_dirname}")
    end

    def project_socket_path(target = nil)
      target ||= options[:target]
      File.join(Dir.pwd, "tmp", "cone", "#{target}.socket")
    end

    def project_pid_path(target = nil)
      target ||= options[:target]
      File.join(Dir.pwd, "tmp", "cone", "#{target}.pid")
    end

    def project_log_path(target = nil)
      target ||= options[:target]
      File.join(Dir.pwd, "tmp", "cone", "#{target}.log")
    end

    def send_code_to_socket(socket_path, code, timeout: 15)
      request_id = SecureRandom.uuid
      request = {
        "action" => "eval",
        "code" => code,
        "timeout" => timeout,
        "request_id" => request_id
      }

      Timeout.timeout(timeout + 5) do
        socket = UNIXSocket.new(socket_path)
        
        # Send request as single line JSON
        socket.write(JSON.generate(request))
        socket.write("\n")
        socket.flush
        
        # Read response
        response_data = socket.gets
        socket.close
        
        JSON.parse(response_data)
      end
    rescue Timeout::Error
      { "success" => false, "error" => "Timeout", "message" => "Request timed out after #{timeout} seconds" }
    rescue StandardError => e
      { "success" => false, "error" => e.class.name, "message" => e.message }
    end

    def sessions_file_path
      File.join(Dir.pwd, "tmp", "cone", "sessions.json")
    end

    def create_rails_adapter(rails_env = "development", target = nil, command = nil)
      target ||= options[:target]
      
      Consolle::Adapters::RailsConsole.new(
        socket_path: project_socket_path(target),
        pid_path: project_pid_path(target),
        log_path: project_log_path(target),
        rails_root: Dir.pwd,
        rails_env: rails_env,
        verbose: options[:verbose],
        command: command
      )
    end

    def save_session_info(adapter)
      target = options[:target]
      
      with_sessions_lock do
        sessions = load_sessions
        
        sessions[target] = {
          "socket_path" => adapter.socket_path,
          "process_pid" => adapter.process_pid,
          "pid_path" => project_pid_path(target),
          "log_path" => project_log_path(target),
          "started_at" => Time.now.to_f,
          "rails_root" => Dir.pwd
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
        socket_path: session["socket_path"],
        process_pid: session["process_pid"],
        started_at: session["started_at"],
        rails_root: session["rails_root"]
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
        request_id: result["request_id"],
        code: code,
        success: result["success"],
        result: result["result"],
        error: result["error"],
        message: result["message"],
        execution_time: result["execution_time"]
      }
      
      # Append to log file
      File.open(log_file, "a") do |f|
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
      File.open(log_file, "a") do |f|
        f.puts JSON.generate(log_entry)
      end
    rescue StandardError => e
      # Log errors should not crash the command
      puts "Warning: Failed to log session event: #{e.message}" if options[:verbose]
    end
    
    def load_sessions
      # Check for legacy session.json file first
      legacy_file = File.join(Dir.pwd, "tmp", "cone", "session.json")
      if File.exist?(legacy_file) && !File.exist?(sessions_file_path)
        # Migrate from old format
        migrate_legacy_session(legacy_file)
      end
      
      return {} unless File.exist?(sessions_file_path)
      
      json = JSON.parse(File.read(sessions_file_path))
      
      # Handle backward compatibility with old single-session format
      if json.key?("socket_path")
        # Legacy single session format - convert to new format
        { "cone" => json }
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
        "_schema" => 1,
        "cone" => legacy_data
      }
      
      # Write new format
      File.write(sessions_file_path, JSON.pretty_generate(new_sessions))
      
      # Remove old file
      File.delete(legacy_file)
      
      puts "Migrated session data to new multi-session format" if options[:verbose]
    rescue StandardError => e
      puts "Warning: Failed to migrate legacy session: #{e.message}" if options[:verbose]
    end
    
    def save_sessions(sessions)
      # Add schema version for future migrations
      sessions_with_schema = { "_schema" => 1 }.merge(sessions)
      
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
    
    def with_sessions_lock(&block)
      # Ensure directory exists
      FileUtils.mkdir_p(File.dirname(sessions_file_path))
      
      # Create lock file separate from sessions file to avoid issues
      lock_file_path = "#{sessions_file_path}.lock"
      
      # Use file locking to prevent concurrent access
      File.open(lock_file_path, File::RDWR | File::CREAT, 0644) do |f|
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
        puts "Session names can only contain letters, numbers, hyphens (-), and underscores (_)"
        exit 1
      end
      
      # Check length (reasonable limit)
      if name.length > 50
        puts "Error: Session name is too long (maximum 50 characters)"
        exit 1
      end
    end
  end
end