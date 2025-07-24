# frozen_string_literal: true

require 'spec_helper'
require 'consolle/server/console_supervisor'

RSpec.describe Consolle::Server::ConsoleSupervisor do
  let(:logger) { Logger.new(nil) }
  let(:rails_root) { '/fake/rails/root' }
  let(:supervisor) { described_class.new(rails_root: rails_root, logger: logger) }

  describe 'PTY environment variable settings' do
    before do
      # Mock PTY.spawn to verify environment variables
      allow(PTY).to receive(:spawn) do |env, cmd, options|
        @captured_env = env
        @captured_cmd = cmd
        @captured_options = options

        # Mock PTY objects
        reader = double('reader')
        writer = double('writer')
        pid = 12_345

        allow(reader).to receive(:sync=)
        allow(writer).to receive(:sync=)
        allow(reader).to receive(:fcntl)
        allow(reader).to receive(:close)
        allow(writer).to receive(:close)
        allow(writer).to receive(:puts)
        allow(writer).to receive(:write)
        allow(writer).to receive(:flush)

        wait_readable_error = Class.new(StandardError) { include IO::WaitReadable }.new
        allow(reader).to receive(:read_nonblock).and_raise(wait_readable_error)

        [reader, writer, pid]
      end

      allow(IO).to receive(:select).and_return([[], [], []])
      allow_any_instance_of(described_class).to receive(:wait_for_prompt).and_return(true)
      allow_any_instance_of(described_class).to receive(:configure_irb_for_automation)
      allow(Process).to receive(:waitpid).and_return(nil)
      allow(Process).to receive(:kill).and_return(1)
    end

    it 'sets correct environment variables' do
      # Call spawn_console method directly
      supervisor.send(:spawn_console)

      # Verify environment variables
      expect(@captured_env).to include(
        'RAILS_ENV' => 'development',
        'IRBRC' => 'skip',
        'PAGER' => 'cat',
        'NO_PAGER' => '1',
        'LESS' => '',
        'TERM' => 'dumb',
        'FORCE_COLOR' => '0',
        'NO_COLOR' => '1',
        'COLUMNS' => '120',
        'LINES' => '24'
      )
    end

    it 'executes correct Rails console command' do
      supervisor.send(:spawn_console)

      expect(@captured_cmd).to eq('bin/rails console')
    end

    it 'sets correct working directory' do
      supervisor.send(:spawn_console)

      expect(@captured_options).to include(chdir: rails_root)
    end
  end

  describe 'IRB automation settings' do
    let(:writer) { double('writer') }
    let(:supervisor_without_init) { described_class.allocate }

    before do
      # Initialize instance variables without calling initialize
      supervisor_without_init.instance_variable_set(:@rails_root, rails_root)
      supervisor_without_init.instance_variable_set(:@rails_env, 'development')
      supervisor_without_init.instance_variable_set(:@logger, logger)
      supervisor_without_init.instance_variable_set(:@writer, writer)
      supervisor_without_init.instance_variable_set(:@restart_timestamps, [])
      supervisor_without_init.instance_variable_set(:@mutex, Mutex.new)
      supervisor_without_init.instance_variable_set(:@running, false)

      allow(writer).to receive(:puts)
      allow(writer).to receive(:flush)
      allow(supervisor_without_init).to receive(:clear_buffer)
      allow(supervisor_without_init).to receive(:wait_for_prompt)
    end

    it 'sends IRB configuration commands' do
      expected_commands = [
        'IRB.conf[:USE_PAGER] = false',
        'IRB.conf[:USE_COLORIZE] = false',
        'IRB.conf[:USE_AUTOCOMPLETE] = false',
        'ActiveSupport::LogSubscriber.colorize_logging = false if defined?(ActiveSupport::LogSubscriber)'
      ]

      supervisor_without_init.send(:configure_irb_for_automation)

      expected_commands.each do |cmd|
        expect(writer).to have_received(:puts).with(cmd)
      end
      expect(writer).to have_received(:flush).at_least(expected_commands.length).times
    end

    it 'has short wait time after configuration' do
      # Allow various sleep times that occur during configuration
      allow(supervisor_without_init).to receive(:sleep)

      supervisor_without_init.send(:configure_irb_for_automation)

      # Verify that sleep was called with reasonable times
      expect(supervisor_without_init).to have_received(:sleep).with(0.1).at_least(5).times # For each IRB command
      expect(supervisor_without_init).to have_received(:sleep).with(0.05).at_least(2).times # For empty lines
    end
  end
end
