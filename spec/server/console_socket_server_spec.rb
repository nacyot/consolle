# frozen_string_literal: true

require 'spec_helper'
require 'consolle/server/console_socket_server'
require 'tmpdir'

RSpec.describe Consolle::Server::ConsoleSocketServer do
  let(:tmpdir) { Dir.mktmpdir }
  let(:socket_path) { File.join(tmpdir, 'test.socket') }
  let(:rails_root) { '/fake/rails/root' }
  let(:server) { described_class.new(socket_path: socket_path, rails_root: rails_root) }

  after do
    begin
      server.stop
    rescue StandardError
      nil
    end
    FileUtils.rm_rf(tmpdir) if Dir.exist?(tmpdir)
  end

  describe '#initialize' do
    it 'sets the socket path' do
      expect(server.socket_path).to eq(socket_path)
    end

    it 'creates a default logger' do
      expect(server.logger).to be_a(Logger)
    end

    it 'can use a custom logger' do
      custom_logger = Logger.new(STDOUT)
      server = described_class.new(socket_path: socket_path, rails_root: rails_root, logger: custom_logger)
      expect(server.logger).to eq(custom_logger)
    end
  end

  describe '#start' do
    before do
      # Mock ConsoleSupervisor creation
      supervisor_double = double('ConsoleSupervisor',
                                 running?: true,
                                 stop: true,
                                 eval: { success: true, output: 'result', execution_time: 0.1 },
                                 rails_root: rails_root,
                                 rails_env: 'development',
                                 pid: 12_345)
      allow(Consolle::Server::ConsoleSupervisor).to receive(:new).and_return(supervisor_double)

      # Mock RequestBroker
      broker_double = double('RequestBroker', start: true, stop: true)
      allow(Consolle::Server::RequestBroker).to receive(:new).and_return(broker_double)
    end

    it 'creates a socket file' do
      server.start
      expect(File.exist?(socket_path)).to be true
      expect(File.stat(socket_path).mode & 0o777).to eq(0o600)
    end

    it 'returns false if already running' do
      server.start
      expect(server.start).to be false
    end
  end

  describe '#stop' do
    before do
      # Mock ConsoleSupervisor creation
      supervisor_double = double('ConsoleSupervisor',
                                 running?: true,
                                 stop: true,
                                 eval: { success: true, output: 'result', execution_time: 0.1 },
                                 rails_root: rails_root,
                                 rails_env: 'development',
                                 pid: 12_345)
      allow(Consolle::Server::ConsoleSupervisor).to receive(:new).and_return(supervisor_double)

      # Mock RequestBroker
      broker_double = double('RequestBroker', start: true, stop: true)
      allow(Consolle::Server::RequestBroker).to receive(:new).and_return(broker_double)
    end

    it 'removes the socket file' do
      server.start
      server.stop
      expect(File.exist?(socket_path)).to be false
    end

    it 'returns false if not running' do
      expect(server.stop).to be false
    end
  end

  describe '#running?' do
    before do
      # Mock ConsoleSupervisor creation
      @supervisor_double = double('ConsoleSupervisor',
                                  running?: true,
                                  stop: true,
                                  eval: { success: true, output: 'result', execution_time: 0.1 },
                                  rails_root: rails_root,
                                  rails_env: 'development',
                                  pid: 12_345)
      allow(Consolle::Server::ConsoleSupervisor).to receive(:new).and_return(@supervisor_double)

      # Mock RequestBroker
      broker_double = double('RequestBroker', start: true, stop: true)
      allow(Consolle::Server::RequestBroker).to receive(:new).and_return(broker_double)
    end

    it 'returns false before starting' do
      expect(server.running?).to be false
    end

    it 'returns true after starting' do
      server.start
      expect(server.running?).to be true
    end
  end
end
