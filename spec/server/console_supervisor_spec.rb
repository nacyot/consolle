# frozen_string_literal: true

require "spec_helper"
require "consolle/server/console_supervisor"
require "tempfile"

RSpec.describe Consolle::Server::ConsoleSupervisor do
  # Tests requiring PTY and actual process creation are handled with mocking
  # Configured to allow testing without actual Rails console

  let(:logger) { Logger.new(nil) }
  let(:rails_root) { "/fake/rails/root" }
  let(:supervisor) { nil }  # Created in before block with proper mocking

  # Mock PTY.spawn to avoid creating actual process
  before do
    reader = double("reader")
    writer = double("writer")
    pid = 12345

    allow(reader).to receive(:sync=)
    allow(writer).to receive(:sync=)
    allow(reader).to receive(:fcntl)
    allow(reader).to receive(:close)
    allow(writer).to receive(:close)
    allow(writer).to receive(:puts)  # For all puts calls
    allow(writer).to receive(:flush)  # For all flush calls
    
    # Create a proper exception for IO::WaitReadable
    wait_readable_error = Class.new(StandardError) { include IO::WaitReadable }.new
    
    # Mock initial prompt waiting
    allow(reader).to receive(:read_nonblock).and_raise(wait_readable_error)
    allow(IO).to receive(:select).and_return([[reader], [], []])
    
    # Mock wait_for_prompt method
    allow_any_instance_of(described_class).to receive(:wait_for_prompt).and_return(true)
    
    # Mock configure_irb_for_automation method (prevent conflicts with existing tests)
    allow_any_instance_of(described_class).to receive(:configure_irb_for_automation)
    
    allow(PTY).to receive(:spawn).and_return([reader, writer, pid])
    allow(Process).to receive(:waitpid).with(pid, Process::WNOHANG).and_return(nil)
    allow(Process).to receive(:kill).with(0, pid).and_return(1)
    allow(Process).to receive(:kill).with("TERM", pid).and_return(1)
    allow(Process).to receive(:kill).with("KILL", pid).and_return(1)
    
    # Create supervisor after mocking is set up
    @supervisor = described_class.new(rails_root: rails_root, logger: logger)
  end
  
  after do
    # Stop the supervisor (watchdog threads are now cleaned up globally in spec_helper)
    @supervisor&.stop rescue nil
  end
  
  let(:supervisor) { @supervisor }

  describe "#initialize" do
    it "sets Rails environment" do
      expect(supervisor.rails_env).to eq("development")
      
      supervisor2 = described_class.new(rails_root: rails_root, rails_env: "test", logger: logger)
      expect(supervisor2.rails_env).to eq("test")
    end

    it "sets Rails root" do
      expect(supervisor.rails_root).to eq(rails_root)
    end
  end

  describe "#running?" do
    it "returns true when process is running" do
      expect(supervisor.running?).to be true
    end

    it "returns false when no process exists" do
      allow(Process).to receive(:kill).with(0, 12345).and_raise(Errno::ESRCH)
      expect(supervisor.running?).to be false
    end
  end

  describe "#eval" do
    let(:reader) { supervisor.instance_variable_get(:@reader) }
    let(:writer) { supervisor.instance_variable_get(:@writer) }

    before do
      allow(writer).to receive(:puts)
      allow(writer).to receive(:flush)
      allow(writer).to receive(:write)
      # Mock clear_buffer and sleep to avoid delays in tests
      allow(supervisor).to receive(:clear_buffer)
      allow(supervisor).to receive(:sleep)
    end

    it "executes code and returns result" do
      # Create a proper exception for IO::WaitReadable
      wait_readable_error = Class.new(StandardError) { include IO::WaitReadable }.new
      
      # Mock Base64 encoding
      encoded_code = Base64.strict_encode64("1 + 1")
      
      # Mock execution result - Rails console actual output format with eval command
      # The actual command sent is: eval(Base64.decode64('...'), IRB.CurrentContext.workspace.binding)
      eval_command = "eval(Base64.decode64('#{encoded_code}'), IRB.CurrentContext.workspace.binding)"
      output_with_prompt = "#{eval_command}\n=> 2\nlua-home(dev)> "
      
      read_count = 0
      allow(reader).to receive(:read_nonblock) do
        read_count += 1
        case read_count
        when 1  # clear_buffer call
          raise wait_readable_error
        when 2  # first read gets the result
          output_with_prompt
        else    # subsequent reads
          raise wait_readable_error
        end
      end

      allow(IO).to receive(:select).and_return([[reader], [], []])

      result = supervisor.eval("1 + 1")
      
      expect(result[:success]).to be true
      expect(result[:output]).to eq("=> 2")
    end

    it "sends Ctrl-C on timeout" do
      # Create a proper exception for IO::WaitReadable
      wait_readable_error = Class.new(StandardError) { include IO::WaitReadable }.new
      
      # Mock timeout situation
      allow(reader).to receive(:read_nonblock).and_raise(wait_readable_error)
      allow(IO).to receive(:select).and_return([[reader], [], []])
      
      result = supervisor.eval("loop { }", timeout: 0.1)
      
      expect(writer).to have_received(:write).with("\x03")
      expect(result[:success]).to be false
      expect(result[:output]).to include("timed out")
    end
    
    xit "properly displays output for multiline code ending with object" do
      # Mock tempfile
      tempfile = double("tempfile")
      allow(tempfile).to receive(:write).with("class TestClass; end\nobj = TestClass.new\nobj")
      allow(tempfile).to receive(:close)
      allow(tempfile).to receive(:path).and_return("/tmp/consolle_eval_12345.rb")
      allow(tempfile).to receive(:unlink)
      allow(Tempfile).to receive(:new).and_return(tempfile)
      
      # Mock execution result with simple object output
      eval_command = "result = eval(File.read('/tmp/consolle_eval_12345.rb'), IRB.CurrentContext.workspace.binding); pp result; result"
      # Simplified output format that matches parse_output expectations
      output_with_prompt = "#{eval_command}\n#<TestClass:0x00007f8b8c0a1b20>\n=> #<TestClass:0x00007f8b8c0a1b20>\nlua-home(dev)> "
      
      read_count = 0
      wait_readable_error = Class.new(StandardError) { include IO::WaitReadable }.new
      allow(reader).to receive(:read_nonblock) do
        read_count += 1
        case read_count
        when 1  # clear_buffer call
          raise wait_readable_error
        when 2  # first read gets the result
          output_with_prompt
        else    # subsequent reads
          raise wait_readable_error
        end
      end

      allow(IO).to receive(:select).and_return([[reader], [], []])

      result = supervisor.eval("class TestClass; end\nobj = TestClass.new\nobj")
      
      expect(result[:success]).to be true
      expect(result[:output]).not_to be_empty
    end
  end

  describe "#stop" do
    before do
      allow(supervisor.instance_variable_get(:@writer)).to receive(:puts)
      allow(supervisor.instance_variable_get(:@writer)).to receive(:flush)
    end

    it "terminates the process gracefully" do
      supervisor.stop
      
      expect(supervisor.instance_variable_get(:@running)).to be false
    end
  end

  describe "restart history" do
    it "manages restart history" do
      # Test trim_restart_history method
      timestamps = supervisor.instance_variable_get(:@restart_timestamps)
      expect(timestamps).to be_an(Array)
      expect(timestamps.size).to be >= 1  # Added on initial start
    end
  end
end