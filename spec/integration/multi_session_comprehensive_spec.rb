# frozen_string_literal: true

require 'spec_helper'
require 'consolle/cli'
require 'tempfile'
require 'json'
require 'fileutils'

RSpec.describe 'Comprehensive multi-session tests' do
  let(:test_dir) { Dir.mktmpdir }
  let(:sessions_file) { File.join(test_dir, 'tmp/cone/sessions.json') }
  let(:legacy_session_file) { File.join(test_dir, 'tmp/cone/session.json') }

  before do
    @original_pwd = Dir.pwd
    Dir.chdir(test_dir)

    # Create a minimal Rails-like structure
    FileUtils.mkdir_p('config')
    File.write('config/environment.rb', '# Rails environment')
    FileUtils.mkdir_p('tmp/cone')
  end

  after do
    Dir.chdir(@original_pwd)
    FileUtils.rm_rf(test_dir)
  end

  describe 'session name validation' do
    let(:cli) { Consolle::CLI.new }

    before do
      cli.options = { target: 'test' }
      # Suppress error output during validation tests
      allow(cli).to receive(:puts)
    end

    it 'rejects names with special characters' do
      invalid_names = ['test/123', 'test.123', 'test 123', 'test@123', '', ' ', 'test*', 'test$']

      invalid_names.each do |name|
        cli.options[:target] = name
        expect { cli.send(:validate_session_name!, name) }.to raise_error(SystemExit)
      end
    end

    it 'accepts valid names' do
      valid_names = %w[test TEST test123 test_123 test-123 test_dev prod-2]

      valid_names.each do |name|
        cli.options[:target] = name
        expect { cli.send(:validate_session_name!, name) }.not_to raise_error
      end
    end

    it 'rejects names longer than 50 characters' do
      long_name = 'a' * 51
      cli.options[:target] = long_name
      expect { cli.send(:validate_session_name!, long_name) }.to raise_error(SystemExit)
    end
  end

  describe 'file locking and concurrent access' do
    let(:cli) { Consolle::CLI.new }

    before do
      cli.options = { target: 'cone' }
    end

    it 'handles concurrent session modifications safely' do
      # Create initial sessions
      sessions = {
        'session1' => { 'process_pid' => 1001 },
        'session2' => { 'process_pid' => 1002 }
      }
      cli.send(:save_sessions, sessions)

      # Simulate concurrent modifications
      threads = []
      5.times do |i|
        threads << Thread.new do
          cli_thread = Consolle::CLI.new
          cli_thread.options = { target: "thread#{i}" }

          cli_thread.send(:with_sessions_lock) do
            current_sessions = cli_thread.send(:load_sessions)
            current_sessions["thread#{i}"] = { 'process_pid' => 2000 + i }
            cli_thread.send(:save_sessions, current_sessions)
          end
        end
      end

      threads.each(&:join)

      # Verify all sessions were added
      final_sessions = cli.send(:load_sessions)
      expect(final_sessions.keys).to include('session1', 'session2', 'thread0', 'thread1', 'thread2', 'thread3',
                                             'thread4')
    end

    it 'uses unique temp files to avoid conflicts' do
      # Initialize with empty sessions
      cli = Consolle::CLI.new
      cli.options = { target: 'test' }
      allow(cli).to receive(:sessions_file_path).and_return(sessions_file)
      cli.send(:save_sessions, {})

      # Simulate concurrent saves
      5.times do |i|
        cli_instance = Consolle::CLI.new
        cli_instance.options = { target: "test#{i}" }
        allow(cli_instance).to receive(:sessions_file_path).and_return(sessions_file)

        # Use locking to properly append
        cli_instance.send(:with_sessions_lock) do
          current = cli_instance.send(:load_sessions)
          current["test#{i}"] = { 'pid' => i }
          cli_instance.send(:save_sessions, current)
        end
      end

      # Verify all sessions were saved
      final_sessions = JSON.parse(File.read(sessions_file))
      expect(final_sessions.keys).to include('test0', 'test1', 'test2', 'test3', 'test4')
    end
  end

  describe 'session cleanup' do
    let(:cli) { Consolle::CLI.new }

    before do
      cli.options = { target: 'cone' }
    end

    it 'cleans up stale sessions during ls command' do
      # Create sessions with mix of alive and dead processes
      sessions_data = {
        '_schema' => 1,
        'alive' => {
          'socket_path' => File.join(test_dir, 'tmp/cone/alive.socket'),
          'process_pid' => Process.pid # Current process, definitely alive
        },
        'dead1' => {
          'socket_path' => File.join(test_dir, 'tmp/cone/dead1.socket'),
          'process_pid' => 99_999  # Non-existent
        },
        'dead2' => {
          'socket_path' => File.join(test_dir, 'tmp/cone/dead2.socket'),
          'process_pid' => 99_998  # Non-existent
        }
      }
      cli.send(:save_sessions, sessions_data)

      # Mock adapter to prevent actual socket connections
      adapter = double('adapter')
      allow(adapter).to receive(:get_status).and_return({
                                                          'success' => true,
                                                          'running' => true,
                                                          'rails_env' => 'development',
                                                          'pid' => Process.pid
                                                        })
      allow(cli).to receive(:create_rails_adapter).and_return(adapter)

      # Capture output
      output = StringIO.new
      allow(cli).to receive(:puts) { |msg| output.puts(msg) }

      # Run ls command
      cli.ls

      # Verify only alive session remains
      final_sessions = cli.send(:load_sessions)
      expect(final_sessions.keys).to include('alive', '_schema')
      expect(final_sessions.keys).not_to include('dead1', 'dead2')
    end
  end

  describe 'multi-environment support' do
    it 'supports different Rails environments for different sessions' do
      # This would require actual Rails adapter testing
      # Skipping for now since it needs real Rails integration
      skip 'Requires actual Rails project for environment testing'
    end
  end

  describe 'starting multiple sessions' do
    it 'creates separate files for each target session' do
      # Mock the adapter to prevent actual server startup
      adapter_cone = double('adapter_cone')
      adapter_dev = double('adapter_dev')

      allow(adapter_cone).to receive(:socket_path).and_return(File.join(test_dir, 'tmp/cone/cone.socket'))
      allow(adapter_cone).to receive(:process_pid).and_return(12_345)
      allow(adapter_cone).to receive(:pid_path).and_return(File.join(test_dir, 'tmp/cone/cone.pid'))
      allow(adapter_cone).to receive(:log_path).and_return(File.join(test_dir, 'tmp/cone/cone.log'))
      allow(adapter_cone).to receive(:running?).and_return(false)
      allow(adapter_cone).to receive(:start).and_return(true)

      allow(adapter_dev).to receive(:socket_path).and_return(File.join(test_dir, 'tmp/cone/dev.socket'))
      allow(adapter_dev).to receive(:process_pid).and_return(67_890)
      allow(adapter_dev).to receive(:pid_path).and_return(File.join(test_dir, 'tmp/cone/dev.pid'))
      allow(adapter_dev).to receive(:log_path).and_return(File.join(test_dir, 'tmp/cone/dev.log'))
      allow(adapter_dev).to receive(:running?).and_return(false)
      allow(adapter_dev).to receive(:start).and_return(true)

      # Start default session
      cli = Consolle::CLI.new
      cli.options = { target: 'cone', rails_env: 'development', verbose: false }
      allow(cli).to receive(:create_rails_adapter).with('development', 'cone', nil, nil).and_return(adapter_cone)
      allow(cli).to receive(:load_session_info).and_return(nil)
      allow(cli).to receive(:log_session_event)

      expect { cli.start }.to output(/Rails console started successfully/).to_stdout

      # Start dev session
      cli2 = Consolle::CLI.new
      cli2.options = { target: 'dev', rails_env: 'development', verbose: false }
      allow(cli2).to receive(:create_rails_adapter).with('development', 'dev', nil, nil).and_return(adapter_dev)
      allow(cli2).to receive(:load_session_info).and_return(nil)
      allow(cli2).to receive(:log_session_event)

      expect { cli2.start }.to output(/Rails console started successfully/).to_stdout

      # Verify sessions.json contains both sessions
      sessions = JSON.parse(File.read(sessions_file))
      expect(sessions['cone']['process_pid']).to eq(12_345)
      expect(sessions['dev']['process_pid']).to eq(67_890)
    end
  end

  describe 'exec with target option' do
    before do
      # Set up sessions file with multiple sessions
      sessions_data = {
        '_schema' => 1,
        'cone' => {
          'socket_path' => File.join(test_dir, 'tmp/cone/cone.socket'),
          'process_pid' => 12_345
        },
        'dev' => {
          'socket_path' => File.join(test_dir, 'tmp/cone/dev.socket'),
          'process_pid' => 67_890
        }
      }
      File.write(sessions_file, JSON.generate(sessions_data))
    end

    it 'executes code on the correct target session' do
      cli = Consolle::CLI.new
      cli.options = { target: 'dev', timeout: 15, verbose: false, raw: false }

      # Mock Rails project checks
      allow(cli).to receive(:ensure_rails_project!)
      allow(cli).to receive(:ensure_project_directories)
      allow(cli).to receive(:validate_session_name!)

      # Mock load_session_info to return the dev session info
      session_info = {
        socket_path: File.join(test_dir, 'tmp/cone/dev.socket'),
        process_pid: 67_890,
        started_at: Time.now.to_f,
        rails_root: test_dir
      }
      allow(cli).to receive(:load_session_info).and_return(session_info)

      # Mock the socket connection check that happens in exec to verify server is running
      mock_socket = double('socket')
      allow(UNIXSocket).to receive(:new).with(File.join(test_dir, 'tmp/cone/dev.socket')).and_return(mock_socket)
      allow(mock_socket).to receive(:write)
      allow(mock_socket).to receive(:flush)
      allow(mock_socket).to receive(:gets).and_return('{"success":true,"running":true}')
      allow(mock_socket).to receive(:close)

      # Mock socket connection to dev session
      allow(cli).to receive(:send_code_to_socket).with(
        File.join(test_dir, 'tmp/cone/dev.socket'),
        'User.count',
        timeout: 15
      ).and_return({
                     'success' => true,
                     'result' => '42',
                     'request_id' => '123'
                   })

      allow(cli).to receive(:log_session_activity)

      # Should use dev.socket, not cone.socket
      expect(cli).to receive(:send_code_to_socket).with(
        File.join(test_dir, 'tmp/cone/dev.socket'),
        'User.count',
        timeout: 15
      )

      expect { cli.exec('User.count') }.to output("42\n").to_stdout
    end
  end

  describe 'error recovery' do
    let(:cli) { Consolle::CLI.new }

    before do
      cli.options = { target: 'test' }
    end

    it 'recovers from corrupted sessions.json' do
      # Write corrupted JSON
      File.write(sessions_file, '{ invalid json }')

      # Should return empty hash and not crash
      sessions = cli.send(:load_sessions)
      expect(sessions).to eq({})
    end

    it 'handles missing sessions.json gracefully' do
      # Ensure file doesn't exist
      FileUtils.rm_f(sessions_file)

      sessions = cli.send(:load_sessions)
      expect(sessions).to eq({})
    end

    it 'cleans up temp files on save failure' do
      # Make directory read-only to cause save to fail
      FileUtils.chmod(0o444, File.dirname(sessions_file))

      # Attempt to save should fail but clean up temp file
      expect do
        cli.send(:save_sessions, { 'test' => {} })
      end.to raise_error(StandardError)

      # No temp files should remain
      temp_files = Dir.glob("#{sessions_file}.tmp.*")
      expect(temp_files).to be_empty
    ensure
      # Restore permissions
      FileUtils.chmod(0o755, File.dirname(sessions_file))
    end
  end
end
