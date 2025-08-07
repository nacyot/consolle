# frozen_string_literal: true

require 'pty'
require 'timeout'
require 'fcntl'
require 'logger'
require_relative '../constants'
require_relative '../errors'

# Ruby 3.4.0+ extracts base64 as a default gem
# Suppress warning by silencing verbose mode temporarily
original_verbose = $VERBOSE
$VERBOSE = nil
require 'base64'
$VERBOSE = original_verbose

module Consolle
  module Server
    class ConsoleSupervisor
      attr_reader :pid, :reader, :writer, :rails_root, :rails_env, :logger

      RESTART_DELAY = 1  # seconds
      MAX_RESTARTS = 5   # within 5 minutes
      RESTART_WINDOW = 300 # 5 minutes
      # Match various Rails console prompts
      # Match various console prompts: custom sentinel, Rails app prompts, IRB prompts, and generic prompts
      # Allow optional non-word characters before the prompt (e.g., Unicode symbols like ▽)
      PROMPT_PATTERN = /^[^\w]*(\u001E\u001F<CONSOLLE>\u001F\u001E|\w+[-_]?\w*\([^)]*\)>|irb\([^)]+\):\d+:?\d*[>*]|>>|>)\s*$/
      CTRL_C = "\x03"

      def initialize(rails_root:, rails_env: 'development', logger: nil, command: nil, wait_timeout: nil)
        @rails_root = rails_root
        @rails_env = rails_env
        @command = command || 'bin/rails console'
        @logger = logger || Logger.new(STDOUT)
        @wait_timeout = wait_timeout || Consolle::DEFAULT_WAIT_TIMEOUT
        @pid = nil
        @reader = nil
        @writer = nil
        @running = false
        @restart_timestamps = []
        @watchdog_thread = nil
        @mutex = Mutex.new
        @process_mutex = Mutex.new # Separate mutex for process lifecycle management

        spawn_console
        start_watchdog
      end

      def eval(code, timeout: nil)
        # Allow timeout to be configured via environment variable
        default_timeout = ENV['CONSOLLE_TIMEOUT'] ? ENV['CONSOLLE_TIMEOUT'].to_i : 30
        timeout ||= default_timeout
        @mutex.synchronize do
          raise 'Console is not running' unless running?

          # Record start time for execution measurement
          start_time = Time.now

          # Check if this is a remote console
          is_remote = @command.include?('ssh') || @command.include?('kamal') || @command.include?('docker')

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
          # Ensure UTF-8 encoding to handle strings that may be tagged as ASCII-8BIT
          utf8_code = if code.encoding == Encoding::UTF_8
                        code
                      else
                        # Try to handle ASCII-8BIT strings that might contain UTF-8 data
                        temp = code.dup
                        if code.encoding == Encoding::ASCII_8BIT
                          # First try to interpret as UTF-8
                          temp.force_encoding('UTF-8')
                          if temp.valid_encoding?
                            temp
                          else
                            # If not valid UTF-8, try other common encodings
                            # or use replacement characters
                            code.encode('UTF-8', invalid: :replace, undef: :replace)
                          end
                        else
                          # For other encodings, convert to UTF-8
                          code.encode('UTF-8')
                        end
                      end
          # For large code, use temporary file approach
          if utf8_code.bytesize > 1000
            logger.debug "[ConsoleSupervisor] Large code (#{utf8_code.bytesize} bytes), using temporary file approach"
            
            # Create temp file with unique name
            require 'tempfile'
            require 'securerandom'
            
            temp_filename = "consolle_temp_#{SecureRandom.hex(8)}.rb"
            temp_path = if defined?(Rails) && Rails.root
                         Rails.root.join('tmp', temp_filename).to_s
                       else
                         File.join(Dir.tmpdir, temp_filename)
                       end
            
            # Write code to temp file
            File.write(temp_path, utf8_code)
            logger.debug "[ConsoleSupervisor] Wrote code to temp file: #{temp_path}"
            
            # Load and execute the file with timeout
            eval_command = <<~RUBY.strip
              begin
                require 'timeout'
                _temp_file = '#{temp_path}'
                Timeout.timeout(#{timeout - 1}) do
                  load _temp_file
                end
              rescue Timeout::Error => e
                puts "Timeout::Error: Code execution timed out after #{timeout - 1} seconds"
                nil
              rescue Exception => e
                puts "\#{e.class}: \#{e.message}"
                puts e.backtrace.first(5).join("\\n") if e.backtrace
                nil
              ensure
                File.unlink(_temp_file) if File.exist?(_temp_file)
              end
            RUBY
            
            @writer.puts eval_command
            @writer.flush
          else
            # For smaller code, use Base64 encoding to avoid escaping issues
            encoded_code = Base64.strict_encode64(utf8_code)
            eval_command = "begin; require 'timeout'; Timeout.timeout(#{timeout - 1}) { eval(Base64.decode64('#{encoded_code}').force_encoding('UTF-8'), IRB.CurrentContext.workspace.binding) }; rescue Timeout::Error => e; puts \"Timeout::Error: Code execution timed out after #{timeout - 1} seconds\"; nil; rescue Exception => e; puts \"\#{e.class}: \#{e.message}\"; nil; end"
            logger.debug "[ConsoleSupervisor] Small code (#{encoded_code.bytesize} bytes), using direct Base64 approach"
            @writer.puts eval_command
            @writer.flush
          end
          
          logger.debug "[ConsoleSupervisor] Code preview (first 100 chars): #{utf8_code[0..100].inspect}" if ENV['DEBUG']
          
          logger.debug "[ConsoleSupervisor] Command sent at #{Time.now}, waiting for response..."

          # Collect output
          output = +''
          deadline = Time.now + timeout

          begin
            loop do
              if Time.now > deadline
                logger.debug "[ConsoleSupervisor] Timeout reached after #{Time.now - start_time}s, output so far: #{output.bytesize} bytes"
                logger.debug "[ConsoleSupervisor] Output content: #{output.inspect}" if ENV['DEBUG']
                # Timeout - send Ctrl-C
                @writer.write(CTRL_C)
                @writer.flush
                sleep 0.5
                clear_buffer
                execution_time = Time.now - start_time
                return build_timeout_response(timeout)
              end

              begin
                chunk = @reader.read_nonblock(4096)
                output << chunk
                logger.debug "[ConsoleSupervisor] Got #{chunk.bytesize} bytes, total output: #{output.bytesize} bytes" if ENV['DEBUG']

                # Respond to cursor position request during command execution
                if chunk.include?("\e[6n")
                  logger.debug "[ConsoleSupervisor] Detected cursor position request during eval, sending response"
                  @writer.write("\e[1;1R")
                  @writer.flush
                end

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
                logger.debug "[ConsoleSupervisor] Waiting for data... (#{Time.now - start_time}s elapsed, output size: #{output.bytesize})" if ENV['DEBUG']
                IO.select([@reader], nil, nil, 0.1)
              rescue Errno::EIO
                # PTY can throw EIO when no data available
                IO.select([@reader], nil, nil, 0.1)
              rescue EOFError
                execution_time = Time.now - start_time
                return build_error_response(
                  EOFError.new('Console terminated'),
                  execution_time: execution_time
                )
              end
            end

            # Check if output is too large and truncate if necessary
            max_output_size = 100_000  # 100KB limit for output
            truncated = false
            
            if output.bytesize > max_output_size
              logger.warn "[ConsoleSupervisor] Output too large (#{output.bytesize} bytes), truncating to #{max_output_size} bytes"
              output = output[0...max_output_size]
              truncated = true
            end
            
            # Parse and return result
            parsed_result = parse_output(output, eval_command)

            # Log for debugging object output issues
            logger.debug "[ConsoleSupervisor] Raw output: #{output.inspect}"
            logger.debug "[ConsoleSupervisor] Parsed result: #{parsed_result.inspect}"

            # Calculate execution time
            execution_time = Time.now - start_time

            # Check if the output contains an error
            if parsed_result.is_a?(Hash) && parsed_result[:error]
              build_error_response(parsed_result[:exception], execution_time: execution_time)
            else
              result = { success: true, output: parsed_result, execution_time: execution_time }
              result[:truncated] = true if truncated
              result[:truncated_at] = max_output_size if truncated
              result
            end
          rescue StandardError => e
            logger.error "[ConsoleSupervisor] Eval error: #{e.message}"
            execution_time = Time.now - start_time
            build_error_response(e, execution_time: execution_time)
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

        logger.info '[ConsoleSupervisor] Stopped'
      end

      def restart
        logger.info '[ConsoleSupervisor] Restarting Rails console subprocess...'

        @process_mutex.synchronize do
          stop_console
          spawn_console
        end

        @pid
      end

      private

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

      def build_error_response(exception, execution_time: nil)
        # Handle string messages that come from eval output parsing
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

      def spawn_console
        env = {
          'RAILS_ENV' => @rails_env,

          # Skip IRB configuration file (prevent conflicts with existing settings)
          'IRBRC' => 'skip',

          # Disable pry-rails (force IRB instead of Pry)
          'DISABLE_PRY_RAILS' => '1',

          # Completely disable pager (critical for automation)
          'PAGER' => 'cat',           # Set pager to cat (immediate output)
          'GEM_PAGER' => 'cat',       # Disable gem pager
          'IRB_PAGER' => 'cat',       # Ruby 3.3+ specific pager setting
          'NO_PAGER' => '1',          # Pager disable flag
          'LESS' => '',               # Clear less pager options

          # Terminal settings (minimal features only)
          'TERM' => 'dumb', # Set to dumb terminal (minimize color/pager features)

          # Disable Rails/ActiveSupport log colors
          'FORCE_COLOR' => '0',       # Force disable colors
          'NO_COLOR' => '1',          # Completely disable color output

          # Disable other interactive features
          'COLUMNS' => '120',         # Fixed column count (prevent auto-detection)
          'LINES' => '24'             # Fixed line count (prevent auto-detection)
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
        wait_for_prompt(timeout: @wait_timeout)

        # Configure IRB settings for automation
        configure_irb_for_automation

        # For remote consoles (like kamal), we need more aggressive initialization
        # Check if this looks like a remote console based on the command
        is_remote = @command.include?('ssh') || @command.include?('kamal') || @command.include?('docker')

        if is_remote
          # Send Ctrl-C to ensure clean state
          @writer.write(CTRL_C)
          @writer.flush

          # Wait for prompt after Ctrl-C
          begin
            wait_for_prompt(timeout: 2, consume_all: true)
          rescue Timeout::Error
            logger.warn '[ConsoleSupervisor] No prompt after Ctrl-C, continuing anyway'
          end

          # Send a unique marker command to ensure all initialization output is consumed
          marker = "__consolle_init_#{Time.now.to_f}__"
          @writer.puts "puts '#{marker}'"
          @writer.flush

          # Read until we see our marker
          output = +''
          deadline = Time.now + 3
          marker_found = false

          while Time.now < deadline && !marker_found
            begin
              chunk = @reader.read_nonblock(4096)
              output << chunk
              marker_found = output.include?(marker)
              
              # Respond to cursor position request during initialization
              if chunk.include?("\e[6n")
                logger.debug "[ConsoleSupervisor] Detected cursor position request during init, sending response"
                @writer.write("\e[1;1R")
                @writer.flush
              end
            rescue IO::WaitReadable
              IO.select([@reader], nil, nil, 0.1)
            rescue Errno::EIO
              IO.select([@reader], nil, nil, 0.1)
            end
          end

          logger.warn '[ConsoleSupervisor] Initialization marker not found, continuing anyway' unless marker_found

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
          Thread.current[:consolle_watchdog] = true # Tag thread for test cleanup
          while @running
            begin
              sleep 0.5

              # Use process mutex to avoid race conditions with restart
              @process_mutex.synchronize do
                # Check if process is still alive
                dead_pid = begin
                  Process.waitpid(@pid, Process::WNOHANG)
                rescue StandardError
                  nil
                end

                if (dead_pid || !running?) && @running # Only restart if we're supposed to be running
                  logger.warn "[ConsoleSupervisor] Console process died (PID: #{@pid}), restarting..."

                  # Wait before restart
                  sleep RESTART_DELAY

                  # Respawn
                  spawn_console
                end
              end
            rescue Errno::ECHILD
              # Process already reaped
              @process_mutex.synchronize do
                if @running
                  logger.warn '[ConsoleSupervisor] Console process missing, restarting...'
                  sleep RESTART_DELAY
                  spawn_console
                end
              end
            rescue StandardError => e
              logger.error "[ConsoleSupervisor] Watchdog error: #{e.message}"
            end
          end

          logger.info '[ConsoleSupervisor] Watchdog thread stopped'
        end
      end

      def wait_for_prompt(timeout: 15, consume_all: false)
        output = +''
        start_time = Time.now
        deadline = start_time + timeout
        prompt_found = false
        last_data_time = Time.now

        logger.info "[ConsoleSupervisor] Waiting for prompt with timeout: #{timeout}s (deadline: #{deadline}, now: #{start_time})"

        loop do
          current_time = Time.now
          if current_time > deadline
            logger.error "[ConsoleSupervisor] Timeout reached. Current: #{current_time}, Deadline: #{deadline}, Elapsed: #{current_time - start_time}s"
            logger.error "[ConsoleSupervisor] Output so far: #{output.inspect}"
            logger.error "[ConsoleSupervisor] Stripped: #{strip_ansi(output).inspect}"
            raise Timeout::Error, "No prompt after #{timeout} seconds"
          end

          # If we found prompt and consume_all is true, continue reading for a bit more
          if prompt_found && consume_all
            if Time.now - last_data_time > 0.5
              logger.info '[ConsoleSupervisor] No more data for 0.5s after prompt, stopping'
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

            # Respond to cursor position request (ESC[6n)
            if chunk.include?("\e[6n")
              logger.debug "[ConsoleSupervisor] Detected cursor position request, sending response"
              @writer.write("\e[1;1R")  # Report cursor at position 1,1
              @writer.flush
            end

            clean = strip_ansi(output)
            # Check each line for prompt pattern
            clean.lines.each do |line|
              if line.match?(PROMPT_PATTERN)
                logger.info '[ConsoleSupervisor] Found prompt!'
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
              chunk = @reader.read_nonblock(4096)
              # Respond to cursor position request even while clearing buffer
              if chunk.include?("\e[6n")
                logger.debug "[ConsoleSupervisor] Detected cursor position request during clear_buffer, sending response"
                @writer.write("\e[1;1R")
                @writer.flush
              end
            end
          rescue IO::WaitReadable, Errno::EIO
            # Buffer cleared for this iteration
          end
          sleep 0.05 if i < 2 # Sleep between iterations except the last
        end
      end

      def configure_irb_for_automation
        # Create the invisible-wrapper sentinel prompt
        sentinel_prompt = "\u001E\u001F<CONSOLLE>\u001F\u001E "

        # Send IRB configuration commands to disable interactive features
        irb_commands = [
          # CRITICAL: Disable pager first to prevent hanging on large outputs
          'IRB.conf[:USE_PAGER] = false',          # Disable pager completely
          
          # Configure custom prompt mode to eliminate continuation prompts
          'IRB.conf[:PROMPT][:CONSOLLE] = { ' \
            'AUTO_INDENT: false, ' \
            "PROMPT_I: #{sentinel_prompt.inspect}, " \
            "PROMPT_N: '', " \
            "PROMPT_S: '', " \
            "PROMPT_C: '', " \
            'RETURN: "=> %s\\n" }',
          'IRB.conf[:PROMPT_MODE] = :CONSOLLE',

          # Disable other interactive features
          'IRB.conf[:USE_COLORIZE] = false',       # Disable color output
          'IRB.conf[:USE_AUTOCOMPLETE] = false',   # Disable autocompletion
          'IRB.conf[:USE_MULTILINE] = false',      # Disable multiline editor to process code at once
          'ActiveSupport::LogSubscriber.colorize_logging = false if defined?(ActiveSupport::LogSubscriber)' # Disable Rails logging colors
        ]

        irb_commands.each do |cmd|
          @writer.puts cmd
          @writer.flush

          # Wait briefly for command to execute
          sleep 0.1

          # Clear any output from the configuration command (these commands typically don't produce visible output)
          clear_buffer
        rescue StandardError => e
          logger.warn "[ConsoleSupervisor] Failed to configure IRB setting: #{cmd} - #{e.message}"
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
          logger.debug '[ConsoleSupervisor] No prompt after IRB configuration, continuing'
        end

        # Final buffer clear
        clear_buffer

        logger.debug '[ConsoleSupervisor] IRB configured for automation'
      end

      def strip_ansi(text)
        # Remove all ANSI escape sequences
        text
          .gsub(/\e\[[\d;]*[a-zA-Z]/, '') # Standard ANSI codes
          .gsub(/\e\[\?\d+[hl]/, '') # Private mode codes like [?2004h
          .gsub(/\e[<>=]/, '') # Other escape sequences
          .gsub(/[\x00-\x08\x0B-\x0C\x0E-\x1D\x7F]/, '') # Control chars except \t(09) \n(0A) \r(0D) \u001E(1E) \u001F(1F)
          .gsub(/\r\n/, "\n") # Normalize line endings
      end

      def parse_output(output, _code)
        # Remove ANSI codes
        clean = strip_ansi(output)

        # Split into lines
        lines = clean.lines
        result_lines = []
        skip_echo = true
        error_exception = nil

        lines.each_with_index do |line, idx|
          # Skip the eval command echo (both file-based and Base64)
          if skip_echo && (line.include?('eval(File.read') || line.include?('eval(Base64.decode64'))
            skip_echo = false
            next
          end

          # Skip prompts (but not return values that start with =>)
          next if line.match?(PROMPT_PATTERN) && !line.start_with?('=>')

          # Skip common IRB configuration output patterns
          if line.match?(/^(IRB\.conf|DISABLE_PRY_RAILS|Switch to inspect mode|Loading .*\.rb|nil)$/) ||
             line.match?(/^__consolle_init_[\d.]+__$/) ||
             line.match?(/^'consolle_init'$/) ||
             line.strip == 'false' && idx == 0 # Skip leading false from IRB config
            next
          end

          # Check for error patterns
          if !error_exception && line.match?(/^(.*Error|.*Exception):/)
            error_match = line.match(/^((?:\w+::)*\w*(?:Error|Exception)):\s*(.*)/)
            if error_match
              error_class = error_match[1]
              error_message = error_match[2]
              
              # Try to create the actual exception object
              begin
                # Handle namespaced errors
                if error_class.include?('::')
                  parts = error_class.split('::')
                  klass = Object
                  parts.each { |part| klass = klass.const_get(part) }
                  error_exception = klass.new(error_message)
                else
                  # Try core Ruby error classes
                  error_exception = Object.const_get(error_class).new(error_message)
                end
              rescue NameError
                # If we can't find the exact error class, use a generic RuntimeError
                error_exception = RuntimeError.new("#{error_class}: #{error_message}")
              end
            end
          end

          # Collect all other lines (including return values and side effects)
          result_lines << line
        end

        # If an error was detected, return it as a hash
        if error_exception
          { error: true, exception: error_exception, output: result_lines.join.strip }
        else
          # Join all lines - this includes both side effects and return values
          result_lines.join.strip
        end
      end

      def trim_restart_history
        # Keep only restarts within the window
        cutoff = Time.now - RESTART_WINDOW
        @restart_timestamps.keep_if { |t| t > cutoff }

        # Check if too many restarts
        return unless @restart_timestamps.size > MAX_RESTARTS

        logger.error "[ConsoleSupervisor] Too many restarts (#{@restart_timestamps.size} in #{RESTART_WINDOW}s)"
        # TODO: Send alert to ops team
      end

      def stop_console
        return unless running?

        begin
          @writer.puts('exit')
          @writer.flush
        rescue StandardError
          # PTY might be closed already
        end

        # Wait for process to exit gracefully
        waited = begin
          Process.waitpid(@pid, Process::WNOHANG)
        rescue StandardError
          nil
        end
        unless waited
          # Give it up to 3 seconds to exit gracefully
          30.times do
            sleep 0.1
            break unless running?

            waited = begin
              Process.waitpid(@pid, Process::WNOHANG)
            rescue StandardError
              nil
            end
            break if waited
          end
        end

        # Force kill if still running
        if running? && !waited
          begin
            Process.kill('TERM', @pid)
          rescue StandardError
            nil
          end
          sleep 0.5
          if running?
            begin
              Process.kill('KILL', @pid)
            rescue StandardError
              nil
            end
          end
        end
      rescue Errno::ECHILD
        # Process already gone
      ensure
        # Close PTY file descriptors
        begin
          @reader&.close
        rescue StandardError
          nil
        end
        begin
          @writer&.close
        rescue StandardError
          nil
        end
      end
    end
  end
end
