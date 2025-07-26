# frozen_string_literal: true

require 'spec_helper'
require 'consolle/adapters/rails_console'
require 'tempfile'
require 'fileutils'

RSpec.describe Consolle::Adapters::RailsConsole do
  describe 'server failure scenarios' do
    let(:test_dir) { Dir.mktmpdir }
    let(:socket_path) { File.join(test_dir, 'test.socket') }
    let(:pid_path) { File.join(test_dir, 'test.pid') }
    let(:log_path) { File.join(test_dir, 'test.log') }
    
    let(:adapter) do
      described_class.new(
      socket_path: socket_path,
      pid_path: pid_path,
      log_path: log_path,
      rails_root: test_dir
    )
  end

  after do
    FileUtils.rm_rf(test_dir)
  end

  describe '#wait_for_server' do
    context 'when server process dies with error' do
      before do
        # Create a fake PID file
        File.write(pid_path, '99999')
        
        # Create a log file with error message
        File.write(log_path, <<~LOG)
          [Server] Starting... PID: 99998
          [Server] Daemon started, PID: 99999
          [Server] Starting server with log level: info...
          I, [2025-07-27T00:48:10.016330 #99999]  INFO -- : [ConsoleSupervisor] Spawning console with command: mise console (development)
          E, [2025-07-27T00:48:10.018195 #99999] ERROR -- : [ConsoleSupervisor] Failed to spawn console: No prompt after 15 seconds
          E, [2025-07-27T00:48:10.018906 #99999] ERROR -- : [ConsoleSocketServer] Failed to start: No prompt after 15 seconds
          [Server] Error: Timeout::Error: No prompt after 15 seconds
        LOG
      end

      it 'detects server failure and raises appropriate error' do
        # Mock Process.kill to simulate dead process
        allow(Process).to receive(:kill).with(0, 99999).and_raise(Errno::ESRCH)
        
        # Simulate that log file doesn't exist initially
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(log_path).and_return(false, true)
        allow(File).to receive(:size).with(log_path).and_return(0)
        
        expect {
          adapter.send(:wait_for_server, timeout: 1)
        }.to raise_error(RuntimeError, /Server failed to start: \[Server\] Error: Timeout::Error: No prompt after 15 seconds/)
      end
    end

    context 'when server process dies without clear error' do
      before do
        # Create a fake PID file
        File.write(pid_path, '99999')
        
        # Create a log file without error message
        File.write(log_path, <<~LOG)
          [Server] Starting... PID: 99998
          [Server] Daemon started, PID: 99999
        LOG
      end

      it 'detects process death and raises generic error' do
        # Mock Process.kill to simulate dead process
        allow(Process).to receive(:kill).with(0, 99999).and_raise(Errno::ESRCH)
        
        expect {
          adapter.send(:wait_for_server, timeout: 1)
        }.to raise_error(RuntimeError, /Server failed to start: Server process died unexpectedly/)
      end
    end

    context 'when server starts successfully' do
      before do
        # Create socket file to simulate successful start
        FileUtils.touch(socket_path)
        
        # Mock get_status to return success with running status
        allow(adapter).to receive(:get_status).and_return({'success' => true, 'running' => true})
      end

      it 'returns true' do
        expect(adapter.send(:wait_for_server, timeout: 1)).to eq(true)
      end
    end

    context 'when timeout occurs without server starting' do
      it 'raises timeout error' do
        expect {
          adapter.send(:wait_for_server, timeout: 0.1)
        }.to raise_error(RuntimeError, /Server failed to start within 0.1 seconds/)
      end
    end
  end

  describe '#start' do
    context 'when server fails to start' do
      before do
        # Mock the daemon spawning to create a fake process
        allow(Process).to receive(:spawn).and_return(99999)
        allow(Process).to receive(:detach)
        
        # Create a fake PID file and error log
        allow(adapter).to receive(:start_server_daemon) do
          File.write(pid_path, '99999')
          File.write(log_path, "[Server] Error: Timeout::Error: Console failed to start")
        end
        
        # Mock Process.kill to simulate dead process
        allow(Process).to receive(:kill).with(0, 99999).and_raise(Errno::ESRCH)
      end

      it 'cleans up and raises error' do
        expect(adapter).to receive(:stop_server_daemon)
        
        expect {
          adapter.start
        }.to raise_error(RuntimeError, /Server failed to start/)
      end
    end
  end
  end
end