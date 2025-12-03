# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'

module Consolle
  # Manages session registry with unique session IDs
  # Provides persistent storage for session metadata even after sessions stop
  class SessionRegistry
    SCHEMA_VERSION = 2
    SESSION_ID_LENGTH = 8
    SHORT_ID_LENGTH = 4

    attr_reader :project_path

    def initialize(project_path = Dir.pwd)
      @project_path = project_path
    end

    # Generate a new unique session ID (8 hex characters)
    def generate_session_id
      SecureRandom.hex(SESSION_ID_LENGTH / 2)
    end

    # Get short ID (first 4 characters)
    def short_id(session_id)
      session_id[0, SHORT_ID_LENGTH]
    end

    # Create a new session entry
    def create_session(target:, socket_path:, pid:, rails_env:, mode:)
      session_id = generate_session_id

      session_data = {
        'id' => session_id,
        'short_id' => short_id(session_id),
        'target' => target,
        'project' => project_path,
        'project_hash' => project_hash,
        'rails_env' => rails_env,
        'mode' => mode,
        'status' => 'running',
        'pid' => pid,
        'socket_path' => socket_path,
        'created_at' => Time.now.iso8601,
        'started_at' => Time.now.iso8601,
        'stopped_at' => nil,
        'last_activity_at' => Time.now.iso8601,
        'command_count' => 0
      }

      with_registry_lock do
        registry = load_registry
        registry['sessions'][session_id] = session_data
        save_registry(registry)
      end

      # Create session directory
      ensure_session_directory(session_id)

      # Save session metadata
      save_session_metadata(session_id, session_data)

      session_data
    end

    # Update session status to stopped
    def stop_session(session_id: nil, target: nil, reason: 'user_requested')
      session = find_session(session_id: session_id, target: target)
      return nil unless session

      with_registry_lock do
        registry = load_registry
        if registry['sessions'][session['id']]
          registry['sessions'][session['id']]['status'] = 'stopped'
          registry['sessions'][session['id']]['stopped_at'] = Time.now.iso8601
          registry['sessions'][session['id']]['stop_reason'] = reason
          save_registry(registry)
        end
      end

      # Update metadata file
      metadata = load_session_metadata(session['id'])
      if metadata
        metadata['status'] = 'stopped'
        metadata['stopped_at'] = Time.now.iso8601
        metadata['stop_reason'] = reason
        save_session_metadata(session['id'], metadata)
      end

      session
    end

    # Record command execution
    def record_command(session_id)
      with_registry_lock do
        registry = load_registry
        if registry['sessions'][session_id]
          registry['sessions'][session_id]['command_count'] ||= 0
          registry['sessions'][session_id]['command_count'] += 1
          registry['sessions'][session_id]['last_activity_at'] = Time.now.iso8601
          save_registry(registry)
        end
      end
    end

    # Find session by ID (full or short) or target name
    def find_session(session_id: nil, target: nil, status: nil)
      registry = load_registry

      if session_id
        # Try exact match first
        session = registry['sessions'][session_id]
        return session if session && (status.nil? || session['status'] == status)

        # Try short ID match
        matches = registry['sessions'].values.select do |s|
          s['short_id'] == session_id && s['project'] == project_path
        end
        matches = matches.select { |s| s['status'] == status } if status
        return matches.first if matches.size == 1

        # Ambiguous short ID
        return nil if matches.size > 1
      end

      if target
        # Find by target name in current project
        matches = registry['sessions'].values.select do |s|
          s['target'] == target && s['project'] == project_path
        end
        matches = matches.select { |s| s['status'] == status } if status

        # Return most recent running session, or most recently created
        matches.sort_by { |s| s['created_at'] }.last
      end
    end

    # Find running session by target
    def find_running_session(target:)
      find_session(target: target, status: 'running')
    end

    # List sessions for current project
    def list_sessions(include_stopped: false, all_projects: false)
      registry = load_registry

      sessions = registry['sessions'].values

      # Filter by project unless all_projects
      sessions = sessions.select { |s| s['project'] == project_path } unless all_projects

      # Filter by status
      sessions = sessions.select { |s| s['status'] == 'running' } unless include_stopped

      # Sort by created_at descending
      sessions.sort_by { |s| s['created_at'] }.reverse
    end

    # List only stopped sessions
    def list_stopped_sessions(all_projects: false)
      registry = load_registry

      sessions = registry['sessions'].values.select { |s| s['status'] == 'stopped' }

      # Filter by project unless all_projects
      sessions = sessions.select { |s| s['project'] == project_path } unless all_projects

      # Sort by stopped_at descending
      sessions.sort_by { |s| s['stopped_at'] || s['created_at'] }.reverse
    end

    # Remove session and its history
    def remove_session(session_id: nil, target: nil)
      session = find_session(session_id: session_id, target: target)
      return nil unless session

      # Check if running
      if session['status'] == 'running'
        return { error: 'running', session: session }
      end

      with_registry_lock do
        registry = load_registry
        registry['sessions'].delete(session['id'])
        save_registry(registry)
      end

      # Remove session directory
      session_dir = session_directory(session['id'])
      FileUtils.rm_rf(session_dir) if Dir.exist?(session_dir)

      session
    end

    # Remove all stopped sessions (prune)
    def prune_sessions(all_projects: false)
      stopped = list_stopped_sessions(all_projects: all_projects)
      removed = []

      stopped.each do |session|
        result = remove_session(session_id: session['id'])
        # Check if result is session data (success) vs error hash
        removed << result if result && !result.key?(:error)
      end

      removed
    end

    # Get session directory path
    def session_directory(session_id)
      File.join(sessions_base_dir, session_id)
    end

    # Get history log path for session
    def history_log_path(session_id)
      File.join(session_directory(session_id), 'history.log')
    end

    # Migration from old sessions.json format
    def migrate_from_legacy
      legacy_sessions_file = File.join(project_path, 'tmp', 'cone', 'sessions.json')
      return unless File.exist?(legacy_sessions_file)

      legacy_data = JSON.parse(File.read(legacy_sessions_file))
      return if legacy_data.empty?

      legacy_data.each do |target, info|
        next if target == '_schema'

        # Create new session entry for running legacy sessions
        if info['process_pid'] && process_alive?(info['process_pid'])
          create_session(
            target: target,
            socket_path: info['socket_path'],
            pid: info['process_pid'],
            rails_env: 'development',
            mode: 'pty'
          )
        end
      end
    end

    private

    def registry_path
      File.expand_path('~/.cone/registry.json')
    end

    def sessions_base_dir
      File.join(File.expand_path('~/.cone/sessions'), project_hash)
    end

    def project_hash
      project_path.gsub('/', '-')
    end

    def ensure_session_directory(session_id)
      dir = session_directory(session_id)
      FileUtils.mkdir_p(dir)
      dir
    end

    def load_registry
      FileUtils.mkdir_p(File.dirname(registry_path))

      if File.exist?(registry_path)
        data = JSON.parse(File.read(registry_path))
        # Ensure schema version
        data['_schema'] ||= SCHEMA_VERSION
        data['sessions'] ||= {}
        data
      else
        { '_schema' => SCHEMA_VERSION, 'sessions' => {} }
      end
    rescue JSON::ParserError
      { '_schema' => SCHEMA_VERSION, 'sessions' => {} }
    end

    def save_registry(registry)
      registry['_schema'] = SCHEMA_VERSION
      temp_path = "#{registry_path}.tmp.#{Process.pid}"
      File.write(temp_path, JSON.pretty_generate(registry))
      File.rename(temp_path, registry_path)
    rescue StandardError => e
      File.unlink(temp_path) if File.exist?(temp_path)
      raise e
    end

    def with_registry_lock
      FileUtils.mkdir_p(File.dirname(registry_path))
      lock_file_path = "#{registry_path}.lock"

      File.open(lock_file_path, File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)
        yield
      ensure
        f.flock(File::LOCK_UN)
      end
    end

    def load_session_metadata(session_id)
      metadata_path = File.join(session_directory(session_id), 'metadata.json')
      return nil unless File.exist?(metadata_path)

      JSON.parse(File.read(metadata_path))
    rescue JSON::ParserError
      nil
    end

    def save_session_metadata(session_id, metadata)
      ensure_session_directory(session_id)
      metadata_path = File.join(session_directory(session_id), 'metadata.json')
      File.write(metadata_path, JSON.pretty_generate(metadata))
    end

    def process_alive?(pid)
      return false unless pid

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end
  end
end
