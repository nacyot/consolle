# frozen_string_literal: true

require 'spec_helper'
require 'consolle/cli'
require 'tempfile'

RSpec.describe Consolle::CLI do
  describe '#exec' do
    let(:cli) { described_class.new }
    let(:socket_path) { '/tmp/test.socket' }
    let(:session_info) do
      {
        socket_path: socket_path,
        process_pid: 12_345,
        started_at: Time.now.to_f,
        rails_root: '/test/project'
      }
    end

    before do
      allow(cli).to receive(:ensure_rails_project!)
      allow(cli).to receive(:ensure_project_directories)
      allow(cli).to receive(:validate_session_name!)
      allow(cli).to receive(:load_session_info).and_return(session_info)
      allow(cli).to receive(:invoke).with(:start, [], {}) # Prevent auto-start from actually happening
      allow(Process).to receive(:kill).with(0, 12_345).and_return(1)
      cli.options = { target: 'cone' } # Set default options

      # Mock socket connection for server status check
      socket = double('socket')
      allow(UNIXSocket).to receive(:new).with(socket_path).and_return(socket)
      allow(socket).to receive(:write)
      allow(socket).to receive(:flush)
      allow(socket).to receive(:gets).and_return('{"success":true,"running":true}')
      allow(socket).to receive(:close)

      # Mock log_session_activity
      allow(cli).to receive(:log_session_activity)
    end

    context 'with code as argument' do
      it 'executes single line code' do
        allow(cli).to receive(:send_code_to_socket).and_return({
                                                                 'success' => true,
                                                                 'result' => '=> 4',
                                                                 'execution_time' => 0.1,
                                                                 'request_id' => 'test-123'
                                                               })

        expect { cli.exec('2 + 2') }.to output(/=> 4/).to_stdout
      end

      it 'handles nil results' do
        allow(cli).to receive(:send_code_to_socket).and_return({
                                                                 'success' => true,
                                                                 'result' => '=> nil',
                                                                 'execution_time' => 0.1,
                                                                 'request_id' => 'test-123'
                                                               })

        expect { cli.exec('nil') }.to output(/=> nil/).to_stdout
      end

      it 'handles empty code' do
        expect { cli.exec('') }.to output(/Error: No code provided/).to_stdout.and raise_error(SystemExit)
      end
    end

    context 'with -f option' do
      let(:temp_file) { Tempfile.new(['test', '.rb']) }

      before do
        cli.options = { file: temp_file.path, target: 'cone' }
      end

      after do
        temp_file.close
        temp_file.unlink
      end

      it 'executes code from file' do
        temp_file.write("puts 'Hello from file'\n42")
        temp_file.flush

        allow(cli).to receive(:send_code_to_socket).and_return({
                                                                 'success' => true,
                                                                 'result' => "Hello from file\n=> 42",
                                                                 'execution_time' => 0.1,
                                                                 'request_id' => 'test-123'
                                                               })

        expect { cli.exec }.to output(/Hello from file/).to_stdout
      end

      it 'handles non-existent file' do
        cli.options = { file: '/non/existent/file.rb', target: 'cone' }
        expect { cli.exec }.to output(/Error: File not found/).to_stdout.and raise_error(SystemExit)
      end

      it 'handles empty file' do
        temp_file.write('')
        temp_file.flush

        # Don't inherit the session_info from parent context
        allow(cli).to receive(:load_session_info).and_return(nil)

        expect { cli.exec }.to output(/Error: No code provided/).to_stdout.and raise_error(SystemExit)
      end
    end

    context 'with multiple arguments' do
      it 'joins arguments with space' do
        allow(cli).to receive(:send_code_to_socket) do |_path, code, _opts|
          expect(code).to eq('puts 1 puts 2')
          {
            'success' => true,
            'result' => '=> nil',
            'execution_time' => 0.1,
            'request_id' => 'test-123'
          }
        end

        cli.exec('puts', '1', 'puts', '2')
      end
    end
  end
end
