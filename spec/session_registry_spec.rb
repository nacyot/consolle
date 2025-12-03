# frozen_string_literal: true

require 'spec_helper'
require 'consolle/session_registry'
require 'tmpdir'

RSpec.describe Consolle::SessionRegistry do
  let(:test_dir) { Dir.mktmpdir }
  let(:registry) { described_class.new(test_dir) }

  after do
    FileUtils.rm_rf(test_dir)
  end

  describe '#generate_session_id' do
    it 'generates 8 character hex string' do
      id = registry.generate_session_id
      expect(id).to match(/\A[a-f0-9]{8}\z/)
    end

    it 'generates unique IDs' do
      ids = 10.times.map { registry.generate_session_id }
      expect(ids.uniq.size).to eq(10)
    end
  end

  describe '#short_id' do
    it 'returns first 4 characters' do
      expect(registry.short_id('a1b2c3d4')).to eq('a1b2')
    end
  end

  describe '#create_session' do
    it 'creates a new session entry' do
      session = registry.create_session(
        target: 'test',
        socket_path: '/tmp/test.socket',
        pid: 12345,
        rails_env: 'development',
        mode: 'pty'
      )

      expect(session['id']).to match(/\A[a-f0-9]{8}\z/)
      expect(session['short_id']).to eq(session['id'][0, 4])
      expect(session['target']).to eq('test')
      expect(session['status']).to eq('running')
      expect(session['pid']).to eq(12345)
      expect(session['command_count']).to eq(0)
    end

    it 'creates session directory' do
      session = registry.create_session(
        target: 'test',
        socket_path: '/tmp/test.socket',
        pid: 12345,
        rails_env: 'development',
        mode: 'pty'
      )

      expect(Dir.exist?(registry.session_directory(session['id']))).to be true
    end
  end

  describe '#find_session' do
    let!(:session) do
      registry.create_session(
        target: 'api',
        socket_path: '/tmp/api.socket',
        pid: 12345,
        rails_env: 'development',
        mode: 'pty'
      )
    end

    it 'finds by full session ID' do
      found = registry.find_session(session_id: session['id'])
      expect(found['target']).to eq('api')
    end

    it 'finds by short ID' do
      found = registry.find_session(session_id: session['short_id'])
      expect(found['target']).to eq('api')
    end

    it 'finds by target name' do
      found = registry.find_session(target: 'api')
      expect(found['id']).to eq(session['id'])
    end
  end

  describe '#stop_session' do
    let!(:session) do
      registry.create_session(
        target: 'test',
        socket_path: '/tmp/test.socket',
        pid: 12345,
        rails_env: 'development',
        mode: 'pty'
      )
    end

    it 'marks session as stopped' do
      registry.stop_session(session_id: session['id'], reason: 'user_requested')

      found = registry.find_session(session_id: session['id'])
      expect(found['status']).to eq('stopped')
      expect(found['stop_reason']).to eq('user_requested')
      expect(found['stopped_at']).not_to be_nil
    end
  end

  describe '#list_sessions' do
    before do
      @running = registry.create_session(
        target: 'running',
        socket_path: '/tmp/running.socket',
        pid: 12345,
        rails_env: 'development',
        mode: 'pty'
      )

      @stopped = registry.create_session(
        target: 'stopped',
        socket_path: '/tmp/stopped.socket',
        pid: 12346,
        rails_env: 'development',
        mode: 'pty'
      )
      registry.stop_session(session_id: @stopped['id'])
    end

    it 'returns only running sessions by default' do
      sessions = registry.list_sessions
      expect(sessions.size).to eq(1)
      expect(sessions.first['target']).to eq('running')
    end

    it 'returns all sessions with include_stopped: true' do
      sessions = registry.list_sessions(include_stopped: true)
      expect(sessions.size).to eq(2)
    end
  end

  describe '#remove_session' do
    let!(:session) do
      s = registry.create_session(
        target: 'test',
        socket_path: '/tmp/test.socket',
        pid: 12345,
        rails_env: 'development',
        mode: 'pty'
      )
      registry.stop_session(session_id: s['id'])
      s
    end

    it 'removes stopped session' do
      result = registry.remove_session(session_id: session['id'])
      expect(result['target']).to eq('test')

      found = registry.find_session(session_id: session['id'])
      expect(found).to be_nil
    end

    it 'returns error for running session' do
      running = registry.create_session(
        target: 'running',
        socket_path: '/tmp/running.socket',
        pid: 99999,
        rails_env: 'development',
        mode: 'pty'
      )

      result = registry.remove_session(session_id: running['id'])
      expect(result[:error]).to eq('running')
    end
  end

  describe '#prune_sessions' do
    before do
      2.times do |i|
        s = registry.create_session(
          target: "stopped#{i}",
          socket_path: "/tmp/stopped#{i}.socket",
          pid: 10000 + i,
          rails_env: 'development',
          mode: 'pty'
        )
        registry.stop_session(session_id: s['id'])
      end

      registry.create_session(
        target: 'running',
        socket_path: '/tmp/running.socket',
        pid: 99999,
        rails_env: 'development',
        mode: 'pty'
      )
    end

    it 'removes all stopped sessions' do
      removed = registry.prune_sessions
      expect(removed.size).to eq(2)

      sessions = registry.list_sessions(include_stopped: true)
      expect(sessions.size).to eq(1)
      expect(sessions.first['target']).to eq('running')
    end
  end
end
