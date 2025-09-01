# frozen_string_literal: true

require 'spec_helper'
require 'consolle/cli'

RSpec.describe Consolle::CLI do
  describe 'custom command option' do
    let(:cli) { described_class.new }
    let(:socket_path) { '/tmp/cone/test.socket' }
    let(:adapter) { double('adapter') }

    before do
      allow(cli).to receive(:ensure_rails_project!)
      allow(cli).to receive(:ensure_project_directories)
      allow(cli).to receive(:validate_session_name!)
      allow(cli).to receive(:load_session_info).and_return(nil)
      allow(cli).to receive(:save_session_info)
      allow(cli).to receive(:log_session_event)
      allow(cli).to receive(:puts)

      # Mock adapter creation and start
      allow(adapter).to receive(:start).and_return(true)
      allow(adapter).to receive(:process_pid).and_return(12_345)
      allow(adapter).to receive(:socket_path).and_return(socket_path)
    end

    context 'with default command' do
      before do
        cli.options = {
          target: 'test',
          command: 'bin/rails console',
          verbose: false
        }
      end

      it 'creates adapter with default command' do
        expect(cli).to receive(:create_rails_adapter).with(
          anything,   # rails_env is provided externally; not asserted
          'test',
          'bin/rails console',
          nil
        ).and_return(adapter)

        cli.start
      end
    end

    context 'with custom command' do
      before do
        cli.options = {
          target: 'test',
          command: 'bundle exec rails console',
          verbose: false
        }
      end

      it 'creates adapter with custom command' do
        expect(cli).to receive(:create_rails_adapter).with(
          anything,   # rails_env is provided externally; not asserted
          'test',
          'bundle exec rails console',
          nil
        ).and_return(adapter)

        cli.start
      end
    end

    context 'with kamal-style command' do
      before do
        cli.options = {
          target: 'kamal',
          command: 'docker exec -it app-web-123 bin/rails console',
          verbose: false
        }
      end

      it 'creates adapter with complex command' do
        expect(cli).to receive(:create_rails_adapter).with(
          anything,   # rails_env is provided externally; not asserted
          'kamal',
          'docker exec -it app-web-123 bin/rails console',
          nil
        ).and_return(adapter)

        cli.start
      end
    end
  end

  describe '#create_rails_adapter with command' do
    let(:cli) { described_class.new }

    before do
      cli.options = { target: 'test', verbose: false }
      allow(Dir).to receive(:pwd).and_return('/test')
    end

    it 'passes command to RailsConsole adapter' do
      expect(Consolle::Adapters::RailsConsole).to receive(:new).with(
        hash_including(
          command: 'custom command',
          rails_env: 'development',
          verbose: false
        )
      )

      cli.send(:create_rails_adapter, 'development', 'test', 'custom command')
    end

    it 'passes nil command when not provided' do
      expect(Consolle::Adapters::RailsConsole).to receive(:new).with(
        hash_including(
          command: nil,
          rails_env: 'development',
          verbose: false
        )
      )

      cli.send(:create_rails_adapter, 'development', 'test', nil)
    end
  end
end
