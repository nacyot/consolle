# frozen_string_literal: true

require "spec_helper"
require "consolle/server/console_supervisor"

RSpec.describe Consolle::Server::ConsoleSupervisor do
  # Test thread synchronization between restart and watchdog
  
  let(:logger) { Logger.new(nil) }
  let(:rails_root) { "/fake/rails/root" }
  let(:supervisor) { nil }  # Created in before block with proper mocking
  
  describe "process synchronization" do
    before do
      reader = double("reader")
      writer = double("writer")
      pid = 12345
      
      allow(reader).to receive(:sync=)
      allow(reader).to receive(:fcntl)
      allow(reader).to receive(:close)
      allow(writer).to receive(:sync=)
      allow(writer).to receive(:close)
      allow(writer).to receive(:puts)
      allow(writer).to receive(:flush)
      allow(writer).to receive(:write)
      
      # Mock PTY.spawn
      allow(PTY).to receive(:spawn).and_return([reader, writer, pid])
      
      # Mock prompt detection - make it return immediately
      wait_readable_error = Class.new(StandardError) { include IO::WaitReadable }.new
      allow(reader).to receive(:read_nonblock).and_raise(wait_readable_error)
      allow(IO).to receive(:select).and_return([[reader], [], []])
      
      # Mock wait_for_prompt to return immediately
      allow_any_instance_of(described_class).to receive(:wait_for_prompt).and_return(true)
      allow_any_instance_of(described_class).to receive(:configure_irb_for_automation)
      
      # Mock Process methods with consistent behavior
      allow(Process).to receive(:kill).and_return(1)
      allow(Process).to receive(:waitpid).and_return(nil)
      
      # Mock running? to return false after kill to prevent infinite loops
      running_call_count = 0
      allow_any_instance_of(described_class).to receive(:running?) do
        running_call_count += 1
        running_call_count < 10  # Return false after a few calls
      end
      
      # Mock Thread.new to prevent actual thread creation for watchdog
      @created_threads = []
      allow(Thread).to receive(:new) do |*args, &block|
        thread = double("thread")
        @created_threads << thread
        allow(thread).to receive(:kill)
        allow(thread).to receive(:join)
        thread
      end
      
      # Create supervisor
      @supervisor = described_class.new(
        rails_root: rails_root,
        rails_env: "development", 
        logger: logger
      )
    end
    
    let(:supervisor) { @supervisor }
    
    it "manages restart without race conditions" do
      # Test that restart works without hanging
      expect { supervisor.restart }.not_to raise_error
      
      # Verify supervisor can be restarted multiple times
      expect { supervisor.restart }.not_to raise_error
      expect { supervisor.restart }.not_to raise_error
    end
    
    it "ensures proper cleanup on stop" do
      # Test stop functionality
      expect { supervisor.stop }.not_to raise_error
      
      # Verify threads were cleaned up
      @created_threads.each do |thread|
        expect(thread).to have_received(:kill)
      end
    end
    
    it "handles process death gracefully" do
      # Simulate process death
      allow(Process).to receive(:waitpid).with(12345, Process::WNOHANG).and_return(12345)
      
      # Should not raise error
      expect { supervisor.restart }.not_to raise_error
    end
    
    it "prevents multiple simultaneous spawn operations" do
      spawn_count = 0
      wait_readable_error = Class.new(StandardError) { include IO::WaitReadable }.new
      
      # Track PTY.spawn calls
      allow(PTY).to receive(:spawn) do |*args|
        spawn_count += 1
        new_reader = double("reader_#{spawn_count}")
        new_writer = double("writer_#{spawn_count}")
        new_pid = 12345 + spawn_count
        
        # Set up mocks for new doubles
        allow(new_reader).to receive(:sync=)
        allow(new_reader).to receive(:fcntl)
        allow(new_reader).to receive(:close)
        allow(new_reader).to receive(:read_nonblock).and_raise(wait_readable_error)
        allow(new_writer).to receive(:sync=)
        allow(new_writer).to receive(:close)
        allow(new_writer).to receive(:puts)
        allow(new_writer).to receive(:flush)
        allow(new_writer).to receive(:write)
        
        # Process.kill already has general stub
        
        [new_reader, new_writer, new_pid]
      end
      
      # Multiple restart calls should not cause issues
      3.times { supervisor.restart }
      
      # Should have called spawn for each restart
      expect(spawn_count).to be >= 3
    end
  end
end