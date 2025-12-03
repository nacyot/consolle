# frozen_string_literal: true

require 'json'
require 'time'

module Consolle
  # Manages command history for sessions
  class History
    attr_reader :registry

    def initialize(project_path = Dir.pwd)
      @registry = SessionRegistry.new(project_path)
    end

    # Log a command execution to session history
    def log_command(session_id:, target:, code:, result:)
      log_path = registry.history_log_path(session_id)

      entry = {
        'timestamp' => Time.now.iso8601,
        'session_id' => session_id,
        'target' => target,
        'request_id' => result['request_id'],
        'code' => code,
        'success' => result['success'],
        'result' => result['result'],
        'error' => result['error'],
        'message' => result['message'],
        'execution_time' => result['execution_time']
      }

      FileUtils.mkdir_p(File.dirname(log_path))
      File.open(log_path, 'a') do |f|
        f.puts JSON.generate(entry)
      end

      # Update command count in registry
      registry.record_command(session_id)

      entry
    rescue StandardError
      nil
    end

    # Query history for a session
    def query(session_id: nil, target: nil, limit: nil, today: false, date: nil,
              success_only: false, failed_only: false, grep: nil, all_sessions: false)
      entries = []

      # Get sessions to query
      sessions = if session_id
                   [registry.find_session(session_id: session_id)]
                 elsif target
                   if all_sessions
                     # All sessions with this target (including stopped)
                     registry.list_sessions(include_stopped: true).select { |s| s['target'] == target }
                   else
                     # Most recent session with this target
                     [registry.find_session(target: target)]
                   end
                 else
                   # Current project sessions
                   if all_sessions
                     registry.list_sessions(include_stopped: true)
                   else
                     registry.list_sessions(include_stopped: false)
                   end
                 end

      sessions.compact.each do |session|
        session_entries = load_history(session['id'])
        session_entries.each { |e| e['_session'] = session }
        entries.concat(session_entries)
      end

      # Apply filters
      entries = filter_by_date(entries, today: today, date: date)
      entries = filter_by_status(entries, success_only: success_only, failed_only: failed_only)
      entries = filter_by_grep(entries, grep) if grep

      # Sort by timestamp descending
      entries = entries.sort_by { |e| e['timestamp'] }.reverse

      # Apply limit
      entries = entries.first(limit) if limit

      entries
    end

    # Format history entry for display (compact)
    def format_entry(entry, show_session: true)
      timestamp = Time.parse(entry['timestamp']).strftime('%Y-%m-%d %H:%M:%S')
      session_prefix = show_session ? "[#{entry['_session']&.dig('short_id') || entry['session_id']&.[](0, 4)}] " : ''
      code_preview = entry['code'].to_s.gsub("\n", ' ').strip
      code_preview = "#{code_preview[0, 60]}..." if code_preview.length > 63

      lines = []
      lines << "#{session_prefix}#{timestamp} | #{code_preview}"

      if entry['success']
        result_preview = entry['result'].to_s.gsub("\n", ' ').strip
        result_preview = "#{result_preview[0, 70]}..." if result_preview.length > 73
        exec_time = entry['execution_time'] ? " (#{entry['execution_time'].round(3)}s)" : ''
        lines << "#{result_preview}#{exec_time}"
      else
        error_msg = entry['error'] || entry['message'] || 'Error'
        lines << "ERROR: #{error_msg}"
      end

      lines.join("\n")
    end

    # Format history entry for verbose display
    def format_entry_verbose(entry)
      lines = []
      lines << '━' * 60
      timestamp = Time.parse(entry['timestamp']).strftime('%Y-%m-%d %H:%M:%S')
      session_info = entry['_session']
      session_str = session_info ? "#{session_info['short_id']} (#{session_info['target']})" : entry['session_id']

      lines << "[#{timestamp}] Session: #{session_str}"
      lines << '━' * 60
      lines << 'Code:'
      entry['code'].to_s.lines.each { |line| lines << "  #{line.chomp}" }
      lines << ''

      if entry['success']
        lines << 'Result:'
        entry['result'].to_s.lines.each { |line| lines << "  #{line.chomp}" }
      else
        lines << "Error: #{entry['error']}"
        lines << entry['message'] if entry['message']
      end

      lines << ''
      lines << "Execution time: #{entry['execution_time']&.round(3)}s" if entry['execution_time']
      lines << '━' * 60

      lines.join("\n")
    end

    # Format history as JSON
    def format_json(entries)
      JSON.pretty_generate(entries.map { |e| e.except('_session') })
    end

    # Get total command count for a session
    def command_count(session_id)
      load_history(session_id).size
    end

    private

    def load_history(session_id)
      log_path = registry.history_log_path(session_id)
      return [] unless File.exist?(log_path)

      entries = []
      File.readlines(log_path).each do |line|
        entry = JSON.parse(line.strip)
        entries << entry
      rescue JSON::ParserError
        next
      end

      entries
    end

    def filter_by_date(entries, today: false, date: nil)
      return entries unless today || date

      target_date = if today
                      Date.today
                    elsif date.is_a?(String)
                      Date.parse(date)
                    else
                      date
                    end

      entries.select do |e|
        entry_date = Time.parse(e['timestamp']).to_date
        entry_date == target_date
      end
    end

    def filter_by_status(entries, success_only: false, failed_only: false)
      return entries unless success_only || failed_only

      if success_only
        entries.select { |e| e['success'] }
      elsif failed_only
        entries.reject { |e| e['success'] }
      else
        entries
      end
    end

    def filter_by_grep(entries, pattern)
      regex = Regexp.new(pattern, Regexp::IGNORECASE)
      entries.select do |e|
        e['code']&.match?(regex) || e['result']&.match?(regex)
      end
    rescue RegexpError
      # If invalid regex, treat as literal string
      entries.select do |e|
        e['code']&.include?(pattern) || e['result']&.include?(pattern)
      end
    end
  end
end
