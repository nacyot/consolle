# frozen_string_literal: true

require 'spec_helper'
require 'consolle/cli'

RSpec.describe Consolle::CLI do
  describe '#exec without auto-start' do
    let(:cli) { described_class.new }
    let(:socket_path) { '/tmp/cone/cone.socket' }
    let(:session_info) do
      { socket_path: socket_path, process_pid: 12_345, started_at: Time.now.to_f, rails_root: '/test' }
    end

    before do
      allow(cli).to receive(:ensure_rails_project!)
      allow(cli).to receive(:ensure_project_directories)
      allow(cli).to receive(:validate_session_name!)
      allow(cli).to receive(:project_socket_path).and_return(socket_path)
      allow(cli).to receive(:sessions_file_path).and_return('/tmp/cone/sessions.json')
      allow(Dir).to receive(:pwd).and_return('/test')
      cli.options = { target: 'cone', timeout: 15, verbose: false, raw: false }
    end

    context 'when server is not running' do
      before do
        # No session info initially
        allow(cli).to receive(:load_session_info).and_return(nil, session_info)
        allow(cli).to receive(:clear_session_info)

        # Mock the start invocation
        allow(cli).to receive(:invoke).with(:start, [], {})

        # Mock successful code execution
        allow(cli).to receive(:send_code_to_socket).and_return({
                                                                 'success' => true,
                                                                 'result' => '42',
                                                                 'execution_time' => 0.1,
                                                                 'request_id' => 'test-123'
                                                               })
        allow(cli).to receive(:log_session_activity)
      end

      it 'shows error message when server is not running' do
        expect(cli).to receive(:puts).with('✗ Rails console is not running')
        expect(cli).to receive(:puts).with('Please start it first with: cone start')
        expect(cli).not_to receive(:invoke).with(:start, [], {})
        expect { cli.exec('21 + 21') }.to raise_error(SystemExit)
      end
    end

    context 'when server is running but not responding' do
      let(:socket) { double('socket') }

      before do
        allow(cli).to receive(:load_session_info).and_return(session_info, session_info)
        allow(cli).to receive(:clear_session_info)

        # Mock failed connection
        allow(UNIXSocket).to receive(:new).with(socket_path).and_raise(Errno::ECONNREFUSED)

        # Mock the start invocation
        allow(cli).to receive(:invoke).with(:start, [], {})

        # Mock successful code execution after restart
        allow(cli).to receive(:send_code_to_socket).and_return({
                                                                 'success' => true,
                                                                 'result' => '42',
                                                                 'execution_time' => 0.1,
                                                                 'request_id' => 'test-123'
                                                               })
        allow(cli).to receive(:log_session_activity)
      end

      it 'shows error message when server is not responding' do
        expect(cli).to receive(:puts).with('✗ Rails console is not running')
        expect(cli).to receive(:puts).with('Please start it first with: cone start')
        expect(cli).not_to receive(:invoke).with(:start, [], {})
        expect { cli.exec('21 + 21') }.to raise_error(SystemExit)
      end
    end

    context 'when server is running normally' do
      let(:socket) { double('socket') }

      before do
        allow(cli).to receive(:load_session_info).and_return(session_info)

        # Mock successful connection
        allow(UNIXSocket).to receive(:new).with(socket_path).and_return(socket)
        allow(socket).to receive(:write)
        allow(socket).to receive(:flush)
        allow(socket).to receive(:gets).and_return('{"success":true,"running":true}')
        allow(socket).to receive(:close)

        # Mock successful code execution
        allow(cli).to receive(:send_code_to_socket).and_return({
                                                                 'success' => true,
                                                                 'result' => '42',
                                                                 'execution_time' => 0.1,
                                                                 'request_id' => 'test-123'
                                                               })
        allow(cli).to receive(:log_session_activity)
      end

      it 'executes code directly without starting server' do
        expect(cli).not_to receive(:invoke).with(:start, [], {})
        expect(cli).to receive(:puts).with('42')

        cli.exec('21 + 21')
      end
    end

    context 'when using file option' do
      let(:test_file) { '/tmp/test.rb' }

      before do
        cli.options = { file: test_file, verbose: false, timeout: 15, target: 'cone', raw: false }
        allow(File).to receive(:file?).with(test_file).and_return(true)
        allow(File).to receive(:read).with(test_file, mode: 'r:UTF-8').and_return("puts 'Hello'")

        # No session info initially
        allow(cli).to receive(:load_session_info).and_return(nil, session_info)
        allow(cli).to receive(:clear_session_info)

        # Mock the start invocation
        allow(cli).to receive(:invoke).with(:start, [], {})

        # Mock successful code execution
        allow(cli).to receive(:send_code_to_socket).and_return({
                                                                 'success' => true,
                                                                 'result' => 'Hello',
                                                                 'execution_time' => 0.1,
                                                                 'request_id' => 'test-123'
                                                               })
        allow(cli).to receive(:log_session_activity)
      end

      it 'shows error message with file option when server is not running' do
        expect(cli).to receive(:puts).with('✗ Rails console is not running')
        expect(cli).to receive(:puts).with('Please start it first with: cone start')
        expect(cli).not_to receive(:invoke).with(:start, [], {})
        expect { cli.exec }.to raise_error(SystemExit)
      end
    end
  end
end
