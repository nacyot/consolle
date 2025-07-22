# frozen_string_literal: true

require "pty"
require "timeout"
require "fcntl"
require "logger"

# Ruby 3.4.0+ extracts base64 as a default gem
# Suppress warning by silencing verbose mode temporarily
original_verbose = $VERBOSE
$VERBOSE = nil
require "base64"
$VERBOSE = original_verbose

module Consolle
  module Server
    class ConsoleSupervisor
      attr_reader :pid, :reader, :writer, :rails_root, :rails_env, :logger

      RESTART_DELAY = 1  # seconds
      MAX_RESTARTS = 5   # within 5 minutes
      RESTART_WINDOW = 300  # 5 minutes
      # Match various Rails console prompts
      # Match various console prompts: custom sentinel, Rails app prompts, IRB prompts, and generic prompts
      # Allow optional non-word characters before the prompt (e.g., Unicode symbols like ▽)
      PROMPT_PATTERN = /^[^\w]*(\u001E\u001F<CONSOLLE>\u001F\u001E|\w+[-_]?\w*\([^)]*\)>|irb\([^)]+\):[\d]+:?[\d]*[>*]|>>|>)\s*$/
      CTRL_C = "\x03"

      def initialize(rails_root:, rails_env: "development", logger: nil, command: nil)
        @rails_root = rails_root
        @rails_env = rails_env
        @command = command || "bin/rails console"
        @logger = logger || Logger.new(STDOUT)
        @pid = nil
        @reader = nil
        @writer = nil
        @running = false
        @restart_timestamps = []
        @watchdog_thread = nil
        @mutex = Mutex.new
        @process_mutex = Mutex.new  # Separate mutex for process lifecycle management
        
        spawn_console
        start_watchdog
      end

      def eval(code, timeout: 30)
        @mutex.synchronize do
          raise "Console is not running" unless running?
          
          # Check if this is a remote console
          is_remote = @command.include?("ssh") || @command.include?("kamal") || @command.include?("docker")
          
          if is_remote
            # Send Ctrl-C to ensure clean state before execution
            @writer.write(CTRL_C)
            @writer.flush
            
            # Clear any pending output
            clear_buffer
            
            # Wait for prompt after Ctrl-C
            begin
              wait_for_prompt(timeout: 1, consume_all: true)
            rescue Timeout::Error
              # Continue anyway, some consoles may not show prompt immediately
            end
          else
            # For local consoles, just clear buffer
            clear_buffer
          end
          
          # Encode code using Base64 to handle special characters and remote consoles
          encoded_code = Base64.strict_encode64(code)
          
          # Use eval to execute the Base64-decoded code
          eval_command = "eval(Base64.decode64('#{encoded_code}'), IRB.CurrentContext.workspace.binding)"
          logger.debug "[ConsoleSupervisor] Sending eval command (Base64 encoded)"
          @writer.puts eval_command
          @writer.flush
          
          # Collect output
          output = +""
          deadline = Time.now + timeout
          
          begin
            loop do
              if Time.now > deadline
                # Timeout - send Ctrl-C
                @writer.write(CTRL_C)
                @writer.flush
                sleep 0.5
                clear_buffer
                return { 
                  success: false, 
                  output: "Execution timed out after #{timeout} seconds",
                  execution_time: timeout 
                }
              end
              
              begin
                chunk = @reader.read_nonblock(4096)
                output << chunk
                
                # Check if we got prompt back
                clean = strip_ansi(output)
                if clean.match?(PROMPT_PATTERN)
                  # Wait a bit for any trailing output
                  sleep 0.1
                  begin
                    output << @reader.read_nonblock(4096)
                  rescue IO::WaitReadable, Errno::EIO
                    # No more data
                  end
                  break
                end
              rescue IO::WaitReadable
                IO.select([@reader], nil, nil, 0.1)
              rescue Errno::EIO
                # PTY can throw EIO when no data available
                IO.select([@reader], nil, nil, 0.1)
              rescue EOFError
                return { 
                  success: false, 
                  output: "Console terminated", 
                  execution_time: nil 
                }
              end
            end
            
            # Parse and return result
            result = parse_output(output, eval_command)
            
            # Log for debugging object output issues
            logger.debug "[ConsoleSupervisor] Raw output: #{output.inspect}"
            logger.debug "[ConsoleSupervisor] Parsed result: #{result.inspect}"
            
            { success: true, output: result, execution_time: nil }
          rescue StandardError => e
            logger.error "[ConsoleSupervisor] Eval error: #{e.message}"
            { success: false, output: "Error: #{e.message}", execution_time: nil }
          end
        end
      end

      def running?
        return false unless @pid
        
        begin
          Process.kill(0, @pid)
          true
        rescue Errno::ESRCH
          false
        end
      end

      def stop
        @running = false
        
        # Stop watchdog first to prevent it from restarting the process
        @watchdog_thread&.kill
        @watchdog_thread&.join(1)
        
        # Use process mutex for clean shutdown
        @process_mutex.synchronize do
          stop_console
        end
        
        logger.info "[ConsoleSupervisor] Stopped"
      end

      def restart
        logger.info "[ConsoleSupervisor] Restarting Rails console subprocess..."
        
        @process_mutex.synchronize do
          stop_console
          spawn_console
        end
        
        @pid
      end

      private

      def spawn_console
        env = {
          "RAILS_ENV" => @rails_env,
          
          # Skip IRB configuration file (prevent conflicts with existing settings)
          "IRBRC" => "skip",
          
          # Disable pry-rails (force IRB instead of Pry)
          "DISABLE_PRY_RAILS" => "1",
          
          # Completely disable pager
          "PAGER" => "cat",           # Set pager to cat (immediate output)
          "NO_PAGER" => "1",          # Pager disable flag
          "LESS" => "",               # Clear less pager options
          
          # Terminal settings (minimal features only)
          "TERM" => "dumb",           # Set to dumb terminal (minimize color/pager features)
          
          # Disable Rails/ActiveSupport log colors
          "FORCE_COLOR" => "0",       # Force disable colors
          "NO_COLOR" => "1",          # Completely disable color output
          
          # Disable other interactive features
          "COLUMNS" => "120",         # Fixed column count (prevent auto-detection)
          "LINES" => "24"             # Fixed line count (prevent auto-detection)
        }
        logger.info "[ConsoleSupervisor] Spawning console with command: #{@command} (#{@rails_env})"
        
        @reader, @writer, @pid = PTY.spawn(env, @command, chdir: @rails_root)
        
        # Non-blocking mode
        @reader.sync = @writer.sync = true
        flags = @reader.fcntl(Fcntl::F_GETFL, 0)
        @reader.fcntl(Fcntl::F_SETFL, flags | Fcntl::O_NONBLOCK)
        
        @running = true
        
        # Record restart timestamp
        @restart_timestamps << Time.now
        trim_restart_history
        
        # Wait for initial prompt
        wait_for_prompt(timeout: 15)
        
        # Configure IRB settings for automation
        configure_irb_for_automation
        
        # For remote consoles (like kamal), we need more aggressive initialization
        # Check if this looks like a remote console based on the command
        is_remote = @command.include?("ssh") || @command.include?("kamal") || @command.include?("docker")
        
        if is_remote
          # Send Ctrl-C to ensure clean state
          @writer.write(CTRL_C)
          @writer.flush
          
          # Wait for prompt after Ctrl-C
          begin
            wait_for_prompt(timeout: 2, consume_all: true)
          rescue Timeout::Error
            logger.warn "[ConsoleSupervisor] No prompt after Ctrl-C, continuing anyway"
          end
          
          # Send a unique marker command to ensure all initialization output is consumed
          marker = "__consolle_init_#{Time.now.to_f}__"
          @writer.puts "puts '#{marker}'"
          @writer.flush
          
          # Read until we see our marker
          output = +""
          deadline = Time.now + 3
          marker_found = false
          
          while Time.now < deadline && !marker_found
            begin
              chunk = @reader.read_nonblock(4096)
              output << chunk
              marker_found = output.include?(marker)
            rescue IO::WaitReadable
              IO.select([@reader], nil, nil, 0.1)
            rescue Errno::EIO
              IO.select([@reader], nil, nil, 0.1)
            end
          end
          
          unless marker_found
            logger.warn "[ConsoleSupervisor] Initialization marker not found, continuing anyway"
          end
          
          # Final cleanup for remote consoles
          @writer.write(CTRL_C)
          @writer.flush
          clear_buffer
        else
          # For local consoles, minimal cleanup is sufficient
          clear_buffer
        end
        
        logger.info "[ConsoleSupervisor] Rails console started (PID: #{@pid})"
      rescue StandardError => e
        logger.error "[ConsoleSupervisor] Failed to spawn console: #{e.message}"
        raise
      end

      def start_watchdog
        @watchdog_thread = Thread.new do
          Thread.current[:consolle_watchdog] = true  # Tag thread for test cleanup
          while @running
            begin
              sleep 0.5
              
              # Use process mutex to avoid race conditions with restart
              @process_mutex.synchronize do
                # Check if process is still alive
                dead_pid = Process.waitpid(@pid, Process::WNOHANG) rescue nil
                
                if dead_pid || !running?
                  if @running  # Only restart if we're supposed to be running
                    logger.warn "[ConsoleSupervisor] Console process died (PID: #{@pid}), restarting..."
                    
                    # Wait before restart
                    sleep RESTART_DELAY
                    
                    # Respawn
                    spawn_console
                  end
                end
              end
            rescue Errno::ECHILD
              # Process already reaped
              @process_mutex.synchronize do
                if @running
                  logger.warn "[ConsoleSupervisor] Console process missing, restarting..."
                  sleep RESTART_DELAY
                  spawn_console
                end
              end
            rescue StandardError => e
              logger.error "[ConsoleSupervisor] Watchdog error: #{e.message}"
            end
          end
          
          logger.info "[ConsoleSupervisor] Watchdog thread stopped"
        end
      end

      def wait_for_prompt(timeout: 15, consume_all: false)
        output = +""
        deadline = Time.now + timeout
        prompt_found = false
        last_data_time = Time.now
        
        loop do
          if Time.now > deadline
            logger.error "[ConsoleSupervisor] Output so far: #{output.inspect}"
            logger.error "[ConsoleSupervisor] Stripped: #{strip_ansi(output).inspect}"
            raise Timeout::Error, "No prompt after #{timeout} seconds"
          end
          
          # If we found prompt and consume_all is true, continue reading for a bit more
          if prompt_found && consume_all
            if Time.now - last_data_time > 0.5
              logger.info "[ConsoleSupervisor] No more data for 0.5s after prompt, stopping"
              return true
            end
          elsif prompt_found
            return true
          end
          
          begin
            chunk = @reader.read_nonblock(4096)
            output << chunk
            last_data_time = Time.now
            logger.debug "[ConsoleSupervisor] Got chunk: #{chunk.inspect}"
            
            clean = strip_ansi(output)
            # Check each line for prompt pattern
            clean.lines.each do |line|
              if line.match?(PROMPT_PATTERN)
                logger.info "[ConsoleSupervisor] Found prompt!"
                prompt_found = true
              end
            end
          rescue IO::WaitReadable
            IO.select([@reader], nil, nil, 0.1)
          rescue Errno::EIO
            # PTY can throw EIO when no data available
            IO.select([@reader], nil, nil, 0.1)
          end
        end
      end

      def clear_buffer
        # Try to clear buffer multiple times for remote consoles
        3.times do |i|
          begin
            loop do
              @reader.read_nonblock(4096)
            end
          rescue IO::WaitReadable, Errno::EIO
            # Buffer cleared for this iteration
          end
          sleep 0.05 if i < 2  # Sleep between iterations except the last
        end
      end

      def configure_irb_for_automation
        # Create the invisible-wrapper sentinel prompt
        sentinel_prompt = "\u001E\u001F<CONSOLLE>\u001F\u001E "
        
        # Send IRB configuration commands to disable interactive features
        irb_commands = [
          # Configure custom prompt mode to eliminate continuation prompts
          "IRB.conf[:PROMPT][:CONSOLLE] = { " \
            "AUTO_INDENT: false, " \
            "PROMPT_I: #{sentinel_prompt.inspect}, " \
            "PROMPT_N: '', " \
            "PROMPT_S: '', " \
            "PROMPT_C: '', " \
            "RETURN: \"=> %s\\n\" }",
          "IRB.conf[:PROMPT_MODE] = :CONSOLLE",
          
          # Disable interactive features
          "IRB.conf[:USE_PAGER] = false",          # Disable pager
          "IRB.conf[:USE_COLORIZE] = false",       # Disable color output
          "IRB.conf[:USE_AUTOCOMPLETE] = false",   # Disable autocompletion
          "IRB.conf[:USE_MULTILINE] = false",      # Disable multiline editor to process code at once
          "ActiveSupport::LogSubscriber.colorize_logging = false if defined?(ActiveSupport::LogSubscriber)"  # Disable Rails logging colors
        ]
        
        irb_commands.each do |cmd|
          begin
            @writer.puts cmd
            @writer.flush
            
            # Wait briefly for command to execute
            sleep 0.1
            
            # Clear any output from the configuration command (these commands typically don't produce visible output)
            clear_buffer
          rescue StandardError => e
            logger.warn "[ConsoleSupervisor] Failed to configure IRB setting: #{cmd} - #{e.message}"
          end
        end
        
        # Send multiple empty lines to ensure all settings are processed
        # This is especially important for remote consoles like kamal console
        2.times do
          @writer.puts
          @writer.flush
          sleep 0.05
        end
        
        # Clear buffer again after sending empty lines
        clear_buffer
        
        # Wait for prompt after configuration with reasonable timeout
        begin
          wait_for_prompt(timeout: 2, consume_all: false)
        rescue Timeout::Error
          # This can fail with some console types, but that's okay
          logger.debug "[ConsoleSupervisor] No prompt after IRB configuration, continuing"
        end
        
        # Final buffer clear
        clear_buffer
        
        logger.debug "[ConsoleSupervisor] IRB configured for automation"
      end

      def strip_ansi(text)
        # Remove all ANSI escape sequences
        text
          .gsub(/\e\[[\d;]*[a-zA-Z]/, "")  # Standard ANSI codes
          .gsub(/\e\[\?[\d]+[hl]/, "")     # Private mode codes like [?2004h
          .gsub(/\e[<>=]/, "")             # Other escape sequences
          .gsub(/[\x00-\x08\x0B-\x0C\x0E-\x1D\x7F]/, "")  # Control chars except \t(09) \n(0A) \r(0D) \u001E(1E) \u001F(1F)
          .gsub(/\r\n/, "\n")              # Normalize line endings
      end
      

      def parse_output(output, code)
        # Remove ANSI codes
        clean = strip_ansi(output)
        
        # Split into lines
        lines = clean.lines
        result_lines = []
        skip_echo = true
        
        lines.each_with_index do |line, idx|
          # Skip the eval command echo (both file-based and Base64)
          if skip_echo && (line.include?("eval(File.read") || line.include?("eval(Base64.decode64"))
            skip_echo = false
            next
          end
          
          # Skip prompts (but not return values that start with =>)
          if line.match?(PROMPT_PATTERN) && !line.start_with?("=>")
            next
          end
          
          # Skip common IRB configuration output patterns
          if line.match?(/^(IRB\.conf|DISABLE_PRY_RAILS|Switch to inspect mode|Loading .*\.rb|nil)$/) ||
             line.match?(/^__consolle_init_[\d.]+__$/) ||
             line.match?(/^'consolle_init'$/) ||
             line.strip == "false" && idx == 0  # Skip leading false from IRB config
            next
          end
          
          # Collect all other lines (including return values and side effects)
          result_lines << line
        end
        
        # Join all lines - this includes both side effects and return values
        result = result_lines.join.strip
        
        result
      end

      def trim_restart_history
        # Keep only restarts within the window
        cutoff = Time.now - RESTART_WINDOW
        @restart_timestamps.keep_if { |t| t > cutoff }
        
        # Check if too many restarts
        if @restart_timestamps.size > MAX_RESTARTS
          logger.error "[ConsoleSupervisor] Too many restarts (#{@restart_timestamps.size} in #{RESTART_WINDOW}s)"
          # TODO: Send alert to ops team
        end
      end

      def stop_console
        return unless running?
        
        begin
          @writer.puts("exit")
          @writer.flush
        rescue StandardError
          # PTY might be closed already
        end
        
        # Wait for process to exit gracefully
        waited = Process.waitpid(@pid, Process::WNOHANG) rescue nil
        unless waited
          # Give it up to 3 seconds to exit gracefully
          30.times do
            sleep 0.1
            break unless running?
            waited = Process.waitpid(@pid, Process::WNOHANG) rescue nil
            break if waited
          end
        end
        
        # Force kill if still running
        if running? && !waited
          Process.kill("TERM", @pid) rescue nil
          sleep 0.5
          Process.kill("KILL", @pid) rescue nil if running?
        end
      rescue Errno::ECHILD
        # Process already gone
      ensure
        # Close PTY file descriptors
        @reader&.close rescue nil
        @writer&.close rescue nil
      end
    end
  end
end