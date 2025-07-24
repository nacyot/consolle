# frozen_string_literal: true

require 'spec_helper'
require 'consolle/cli'

RSpec.describe Consolle::CLI do
  describe '#stop_all' do
    let(:cli) { described_class.new }
    let(:sessions) do
      {
        '_schema' => { 'version' => '1.0' },
        'cone' => {
          'process_pid' => 12_345,
          'socket_path' => '/tmp/cone/cone.socket',
          'started_at' => Time.now.to_f,
          'rails_env' => 'development'
        },
        'secondary' => {
          'process_pid' => 12_346,
          'socket_path' => '/tmp/cone/secondary.socket',
          'started_at' => Time.now.to_f,
          'rails_env' => 'test'
        },
        'inactive' => {
          'process_pid' => 12_347,
          'socket_path' => '/tmp/cone/inactive.socket',
          'started_at' => Time.now.to_f,
          'rails_env' => 'development'
        }
      }
    end

    before do
      allow(cli).to receive(:ensure_rails_project!)
      allow(cli).to receive(:load_sessions).and_return(sessions)
      allow(cli).to receive(:save_sessions)
      allow(cli).to receive(:with_sessions_lock).and_yield
      allow(cli).to receive(:log_session_event)
      allow(cli).to receive(:puts) # Suppress output in tests
    end

    context 'when no active sessions exist' do
      before do
        allow(cli).to receive(:process_alive?).and_return(false)
      end

      it 'displays no active sessions message' do
        expect(cli).to receive(:puts).with('No active sessions to stop')
        cli.stop_all
      end
    end

    context 'when active sessions exist' do
      let(:adapter1) { double('adapter1') }
      let(:adapter2) { double('adapter2') }

      before do
        # Only first two sessions are alive
        allow(cli).to receive(:process_alive?).with(12_345).and_return(true)
        allow(cli).to receive(:process_alive?).with(12_346).and_return(true)
        allow(cli).to receive(:process_alive?).with(12_347).and_return(false)

        # Mock adapter creation
        allow(cli).to receive(:create_rails_adapter).with('development', 'cone').and_return(adapter1)
        allow(cli).to receive(:create_rails_adapter).with('development', 'secondary').and_return(adapter2)
      end

      it 'stops all active sessions' do
        allow(adapter1).to receive(:stop).and_return(true)
        allow(adapter2).to receive(:stop).and_return(true)

        expect(cli).to receive(:puts).with('Found 2 active session(s)')
        expect(cli).to receive(:puts).with("\nStopping session 'cone'...")
        expect(cli).to receive(:puts).with("✓ Session 'cone' stopped")
        expect(cli).to receive(:puts).with("\nStopping session 'secondary'...")
        expect(cli).to receive(:puts).with("✓ Session 'secondary' stopped")
        expect(cli).to receive(:puts).with("\n✓ All sessions stopped")

        # Verify sessions are removed
        expect(cli).to receive(:with_sessions_lock).twice.and_yield

        cli.stop_all
      end

      it 'handles failures gracefully' do
        allow(adapter1).to receive(:stop).and_return(true)
        allow(adapter2).to receive(:stop).and_return(false)

        expect(cli).to receive(:puts).with('Found 2 active session(s)')
        expect(cli).to receive(:puts).with("\nStopping session 'cone'...")
        expect(cli).to receive(:puts).with("✓ Session 'cone' stopped")
        expect(cli).to receive(:puts).with("\nStopping session 'secondary'...")
        expect(cli).to receive(:puts).with("✗ Failed to stop session 'secondary'")
        expect(cli).to receive(:puts).with("\n✓ All sessions stopped")

        cli.stop_all
      end

      it 'logs session stop events' do
        allow(adapter1).to receive(:stop).and_return(true)
        allow(adapter2).to receive(:stop).and_return(true)

        expect(cli).to receive(:log_session_event).with(12_345, 'session_stop', {
                                                          reason: 'stop_all_requested'
                                                        })
        expect(cli).to receive(:log_session_event).with(12_346, 'session_stop', {
                                                          reason: 'stop_all_requested'
                                                        })

        cli.stop_all
      end
    end
  end
end
