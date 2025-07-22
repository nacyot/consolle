# frozen_string_literal: true

require "spec_helper"
require "consolle/server/console_supervisor"

RSpec.describe Consolle::Server::ConsoleSupervisor do
  let(:logger) { Logger.new(nil) }
  let(:rails_root) { "/fake/rails/root" }
  let(:supervisor) { nil }

  # Mock PTY.spawn to avoid creating actual process
  before do
    @reader = double("reader")
    @writer = double("writer")
    @pid = 12345
    @new_pid = 12346

    allow(@reader).to receive(:sync=)
    allow(@writer).to receive(:sync=)
    allow(@reader).to receive(:fcntl)
    allow(@reader).to receive(:close)
    allow(@writer).to receive(:close)
    allow(@writer).to receive(:puts)
    allow(@writer).to receive(:write)
    allow(@writer).to receive(:flush)
    
    # Create a proper exception for IO::WaitReadable
    wait_readable_error = Class.new(StandardError) { include IO::WaitReadable }.new
    
    # Mock initial prompt waiting
    allow(@reader).to receive(:read_nonblock).and_raise(wait_readable_error)
    allow(IO).to receive(:select).and_return([[@reader], [], []])
    
    # Mock wait_for_prompt method
    allow_any_instance_of(described_class).to receive(:wait_for_prompt).and_return(true)
    
    # Mock configure_irb_for_automation method (prevent conflicts with existing tests)
    allow_any_instance_of(described_class).to receive(:configure_irb_for_automation)
    
    # First spawn returns original PID
    spawn_count = 0
    allow(PTY).to receive(:spawn) do
      spawn_count += 1
      if spawn_count == 1
        [@reader, @writer, @pid]
      else
        # New reader/writer for restart
        new_reader = double("new_reader")
        new_writer = double("new_writer")
        allow(new_reader).to receive(:sync=)
        allow(new_writer).to receive(:sync=)
        allow(new_reader).to receive(:fcntl)
        allow(new_reader).to receive(:close)
        allow(new_writer).to receive(:close)
        allow(new_writer).to receive(:puts)
        allow(new_writer).to receive(:write)
        allow(new_writer).to receive(:flush)
        allow(new_reader).to receive(:read_nonblock).and_raise(wait_readable_error)
        [new_reader, new_writer, @new_pid]
      end
    end
    
    allow(Process).to receive(:waitpid).and_return(nil)
    allow(Process).to receive(:kill).with(0, @pid).and_return(1)
    allow(Process).to receive(:kill).with(0, @new_pid).and_return(1)
    allow(Process).to receive(:kill).with("TERM", @pid).and_return(1)
    allow(Process).to receive(:kill).with("KILL", @pid).and_return(1)
    
    # Create supervisor after mocking is set up
    @supervisor = described_class.new(rails_root: rails_root, logger: logger)
  end
  
  let(:supervisor) { @supervisor }

  describe "#restart" do
    it "restarts Rails console process" do
      # Initial PID
      expect(supervisor.pid).to eq(@pid)
      expect(supervisor.running?).to be true
      
      # Allow writer operations
      allow(supervisor.instance_variable_get(:@writer)).to receive(:puts)
      allow(supervisor.instance_variable_get(:@writer)).to receive(:flush)
      
      # Process becomes not running after exit command
      allow(Process).to receive(:kill).with(0, @pid).and_raise(Errno::ESRCH)
      
      # Restart the process
      new_pid = supervisor.restart
      
      # Check new PID
      expect(new_pid).to eq(@new_pid)
      expect(supervisor.pid).to eq(@new_pid)
      
      # Verify exit was sent to old process
      writer = supervisor.instance_variable_get(:@writer)
      expect(writer).not_to be_nil
    end

    it "sends TERM/KILL signals when force termination is needed" do
      # Allow writer operations
      allow(supervisor.instance_variable_get(:@writer)).to receive(:puts)
      allow(supervisor.instance_variable_get(:@writer)).to receive(:flush)
      
      # Process doesn't exit gracefully
      allow(Process).to receive(:kill).with(0, @pid).and_return(1)
      
      # Restart the process
      supervisor.restart
      
      # Verify force kill was attempted
      expect(Process).to have_received(:kill).with("TERM", @pid)
    end

    it "works normally even after restart" do
      # Allow writer operations
      allow(supervisor.instance_variable_get(:@writer)).to receive(:puts)
      allow(supervisor.instance_variable_get(:@writer)).to receive(:flush)
      
      # Process becomes not running after exit command
      allow(Process).to receive(:kill).with(0, @pid).and_raise(Errno::ESRCH)
      
      # Restart
      supervisor.restart
      
      # Verify supervisor is still running with new process
      expect(supervisor.running?).to be true
      expect(supervisor.instance_variable_get(:@running)).to be true
    end
  end
end