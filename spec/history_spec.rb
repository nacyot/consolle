# frozen_string_literal: true

require 'spec_helper'
require 'consolle/session_registry'
require 'consolle/history'
require 'tmpdir'

RSpec.describe Consolle::History do
  let(:test_dir) { Dir.mktmpdir }
  let(:registry) { Consolle::SessionRegistry.new(test_dir) }
  let(:history) { described_class.new(test_dir) }
  let!(:session) do
    registry.create_session(
      target: 'test',
      socket_path: '/tmp/test.socket',
      pid: 12345,
      rails_env: 'development',
      mode: 'pty'
    )
  end

  after do
    FileUtils.rm_rf(test_dir)
  end

  describe '#log_command' do
    it 'logs command to history file' do
      history.log_command(
        session_id: session['id'],
        target: 'test',
        code: 'User.count',
        result: {
          'request_id' => 'test123',
          'success' => true,
          'result' => '=> 42',
          'execution_time' => 0.015
        }
      )

      log_path = registry.history_log_path(session['id'])
      expect(File.exist?(log_path)).to be true

      entry = JSON.parse(File.readlines(log_path).first)
      expect(entry['code']).to eq('User.count')
      expect(entry['success']).to be true
      expect(entry['result']).to eq('=> 42')
    end
  end

  describe '#query' do
    before do
      # Log some test commands
      3.times do |i|
        history.log_command(
          session_id: session['id'],
          target: 'test',
          code: "User.find(#{i})",
          result: {
            'request_id' => "req#{i}",
            'success' => i != 1, # Second one fails
            'result' => "=> User##{i}",
            'error' => i == 1 ? 'NotFound' : nil,
            'execution_time' => 0.01 * (i + 1)
          }
        )
      end
    end

    it 'returns all entries for session' do
      entries = history.query(session_id: session['id'])
      expect(entries.size).to eq(3)
    end

    it 'limits number of entries' do
      entries = history.query(session_id: session['id'], limit: 2)
      expect(entries.size).to eq(2)
    end

    it 'filters by success' do
      entries = history.query(session_id: session['id'], success_only: true)
      expect(entries.size).to eq(2)
    end

    it 'filters by failure' do
      entries = history.query(session_id: session['id'], failed_only: true)
      expect(entries.size).to eq(1)
    end

    it 'filters by grep pattern' do
      entries = history.query(session_id: session['id'], grep: 'find\\(1\\)')
      expect(entries.size).to eq(1)
    end
  end

  describe '#format_entry' do
    it 'formats entry for display' do
      entry = {
        'timestamp' => Time.now.iso8601,
        'code' => 'User.count',
        'success' => true,
        'result' => '=> 42',
        'execution_time' => 0.015,
        '_session' => { 'short_id' => 'a1b2' }
      }

      output = history.format_entry(entry)
      expect(output).to include('a1b2')
      expect(output).to include('User.count')
      expect(output).to include('42')
    end
  end

  describe '#format_json' do
    it 'formats entries as JSON' do
      entries = [
        {
          'timestamp' => Time.now.iso8601,
          'code' => 'User.count',
          'success' => true,
          '_session' => { 'short_id' => 'a1b2' }
        }
      ]

      json = history.format_json(entries)
      parsed = JSON.parse(json)
      expect(parsed.first['code']).to eq('User.count')
      expect(parsed.first).not_to have_key('_session')
    end
  end
end
