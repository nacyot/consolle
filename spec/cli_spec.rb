# frozen_string_literal: true

require 'spec_helper'
require 'consolle/cli'

RSpec.describe Consolle::CLI do
  describe '#version' do
    it 'outputs the version' do
      expect { described_class.new.version }.to output(/Consolle version \d+\.\d+\.\d+/).to_stdout
    end
  end

  describe 'Rails project validation' do
    it 'raises an error if not a Rails project' do
      allow(File).to receive(:exist?).with('config/environment.rb').and_return(false)
      allow(File).to receive(:exist?).with('config/application.rb').and_return(false)

      cli = described_class.new
      expect { cli.send(:ensure_rails_project!) }.to raise_error(SystemExit)
    end
  end

  describe 'socket and session paths' do
    let(:cli) { described_class.new }
    let(:current_pwd) { '/Users/test/project' }

    before do
      allow(Dir).to receive(:pwd).and_return(current_pwd)
    end

    it 'creates the project socket path correctly' do
      cli.options = { target: 'cone' }
      expect(cli.send(:project_socket_path)).to eq('/Users/test/project/tmp/cone/cone.socket')
    end

    it 'creates the sessions file path correctly' do
      expect(cli.send(:sessions_file_path)).to eq('/Users/test/project/tmp/cone/sessions.json')
    end

    it 'creates the project session directory correctly' do
      expected_dir = File.expand_path('~/.cone/sessions/-Users-test-project')
      expect(cli.send(:project_session_dir)).to eq(expected_dir)
    end
  end

  describe '#create_rails_adapter' do
    let(:cli) { described_class.new }

    before do
      allow(Dir).to receive(:pwd).and_return('/Users/test/project')
    end

    it 'creates RailsConsole adapter with correct socket path' do
      adapter = cli.send(:create_rails_adapter, 'test')
      expect(adapter).to be_a(Consolle::Adapters::RailsConsole)
      expect(adapter.socket_path).to eq('/Users/test/project/tmp/cone/cone.socket')
    end
  end

  describe '#status' do
    let(:cli) { described_class.new }

    before do
      allow(cli).to receive(:ensure_rails_project!)
    end

    it 'outputs appropriate message when no session file exists' do
      allow(cli).to receive(:load_session_info).and_return(nil)
      expect { cli.status }.to output(/No active Rails console session found/).to_stdout
    end

    context 'when session file exists' do
      let(:session_info) do
        {
          socket_path: '/test/socket.sock',
          process_pid: 12_345,
          started_at: Time.now.to_f,
          rails_root: '/test/project'
        }
      end

      before do
        allow(cli).to receive(:load_session_info).and_return(session_info)
      end

      it 'displays running status when process is running' do
        adapter = double('adapter')
        allow(cli).to receive(:create_rails_adapter).and_return(adapter)
        allow(adapter).to receive(:get_status).and_return({
                                                            'success' => true,
                                                            'running' => true,
                                                            'rails_env' => 'development',
                                                            'pid' => 12_345
                                                          })

        expect { cli.status }.to output(/Rails console is running/).to_stdout
      end

      it 'displays not running when process is not found' do
        adapter = double('adapter')
        allow(cli).to receive(:create_rails_adapter).and_return(adapter)
        allow(adapter).to receive(:get_status).and_return(nil)
        allow(cli).to receive(:clear_session_info)

        expect { cli.status }.to output(/Rails console is not running/).to_stdout
      end
    end
  end
end
