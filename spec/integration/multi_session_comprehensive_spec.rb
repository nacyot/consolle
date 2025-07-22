# frozen_string_literal: true

require "spec_helper"
require "consolle/cli"
require "tempfile"
require "json"
require "fileutils"

RSpec.describe "Comprehensive multi-session tests" do
  let(:test_dir) { Dir.mktmpdir }
  let(:sessions_file) { File.join(test_dir, "tmp/cone/sessions.json") }
  let(:legacy_session_file) { File.join(test_dir, "tmp/cone/session.json") }
  
  before do
    @original_pwd = Dir.pwd
    Dir.chdir(test_dir)
    
    # Create a minimal Rails-like structure
    FileUtils.mkdir_p("config")
    File.write("config/environment.rb", "# Rails environment")
    FileUtils.mkdir_p("tmp/cone")
  end
  
  after do
    Dir.chdir(@original_pwd)
    FileUtils.rm_rf(test_dir)
  end
  
  describe "session name validation" do
    let(:cli) { Consolle::CLI.new }
    
    before do
      cli.options = { target: "test" }
    end
    
    it "rejects names with special characters" do
      invalid_names = ["test/123", "test.123", "test 123", "test@123", "", " ", "test*", "test$"]
      
      invalid_names.each do |name|
        cli.options[:target] = name
        expect { cli.send(:validate_session_name!, name) }.to raise_error(SystemExit)
      end
    end
    
    it "accepts valid names" do
      valid_names = ["test", "TEST", "test123", "test_123", "test-123", "test_dev", "prod-2"]
      
      valid_names.each do |name|
        cli.options[:target] = name
        expect { cli.send(:validate_session_name!, name) }.not_to raise_error
      end
    end
    
    it "rejects names longer than 50 characters" do
      long_name = "a" * 51
      cli.options[:target] = long_name
      expect { cli.send(:validate_session_name!, long_name) }.to raise_error(SystemExit)
    end
  end
  
  describe "file locking and concurrent access" do
    let(:cli) { Consolle::CLI.new }
    
    before do
      cli.options = { target: "cone" }
    end
    
    it "handles concurrent session modifications safely" do
      # Create initial sessions
      sessions = {
        "session1" => { "process_pid" => 1001 },
        "session2" => { "process_pid" => 1002 }
      }
      cli.send(:save_sessions, sessions)
      
      # Simulate concurrent modifications
      threads = []
      5.times do |i|
        threads << Thread.new do
          cli_thread = Consolle::CLI.new
          cli_thread.options = { target: "thread#{i}" }
          
          cli_thread.send(:with_sessions_lock) do
            current_sessions = cli_thread.send(:load_sessions)
            current_sessions["thread#{i}"] = { "process_pid" => 2000 + i }
            cli_thread.send(:save_sessions, current_sessions)
          end
        end
      end
      
      threads.each(&:join)
      
      # Verify all sessions were added
      final_sessions = cli.send(:load_sessions)
      expect(final_sessions.keys).to include("session1", "session2", "thread0", "thread1", "thread2", "thread3", "thread4")
    end
    
    it "uses unique temp files to avoid conflicts" do
      # Initialize with empty sessions
      cli = Consolle::CLI.new
      cli.options = { target: "test" }
      allow(cli).to receive(:sessions_file_path).and_return(sessions_file)
      cli.send(:save_sessions, {})
      
      # Simulate concurrent saves
      5.times do |i|
        cli_instance = Consolle::CLI.new
        cli_instance.options = { target: "test#{i}" }
        allow(cli_instance).to receive(:sessions_file_path).and_return(sessions_file)
        
        # Use locking to properly append
        cli_instance.send(:with_sessions_lock) do
          current = cli_instance.send(:load_sessions)
          current["test#{i}"] = { "pid" => i }
          cli_instance.send(:save_sessions, current)
        end
      end
      
      # Verify all sessions were saved
      final_sessions = JSON.parse(File.read(sessions_file))
      expect(final_sessions.keys).to include("test0", "test1", "test2", "test3", "test4")
    end
  end
  
  describe "legacy session migration" do
    let(:cli) { Consolle::CLI.new }
    
    before do
      cli.options = { target: "cone", verbose: false }
    end
    
    it "migrates old session.json format automatically" do
      # Create legacy session file
      legacy_data = {
        "socket_path" => "/path/to/cone.socket",
        "process_pid" => 12345,
        "started_at" => Time.now.to_f,
        "rails_root" => test_dir
      }
      File.write(legacy_session_file, JSON.generate(legacy_data))
      
      # Load sessions should trigger migration
      sessions = cli.send(:load_sessions)
      
      # Verify migration
      expect(File.exist?(legacy_session_file)).to be false
      expect(File.exist?(sessions_file)).to be true
      expect(sessions["_schema"]).to eq(1)
      expect(sessions["cone"]["process_pid"]).to eq(12345)
    end
    
    it "handles sessions.json with legacy format inside" do
      # Create sessions.json with old format (missing _schema)
      legacy_in_new = {
        "socket_path" => "/path/to/cone.socket",
        "process_pid" => 12345,
        "started_at" => Time.now.to_f,
        "rails_root" => test_dir
      }
      File.write(sessions_file, JSON.generate(legacy_in_new))
      
      # Load should convert it
      sessions = cli.send(:load_sessions)
      expect(sessions["cone"]["process_pid"]).to eq(12345)
    end
  end
  
  describe "session cleanup" do
    let(:cli) { Consolle::CLI.new }
    
    before do
      cli.options = { target: "cone" }
    end
    
    it "cleans up stale sessions during ls command" do
      # Create sessions with mix of alive and dead processes
      sessions_data = {
        "_schema" => 1,
        "alive" => {
          "socket_path" => File.join(test_dir, "tmp/cone/alive.socket"),
          "process_pid" => Process.pid  # Current process, definitely alive
        },
        "dead1" => {
          "socket_path" => File.join(test_dir, "tmp/cone/dead1.socket"),
          "process_pid" => 99999  # Non-existent
        },
        "dead2" => {
          "socket_path" => File.join(test_dir, "tmp/cone/dead2.socket"),
          "process_pid" => 99998  # Non-existent
        }
      }
      cli.send(:save_sessions, sessions_data)
      
      # Mock adapter to prevent actual socket connections
      adapter = double("adapter")
      allow(adapter).to receive(:get_status).and_return({
        "success" => true,
        "running" => true,
        "rails_env" => "development",
        "pid" => Process.pid
      })
      allow(cli).to receive(:create_rails_adapter).and_return(adapter)
      
      # Capture output
      output = StringIO.new
      allow(cli).to receive(:puts) { |msg| output.puts(msg) }
      
      # Run ls command
      cli.ls
      
      # Verify only alive session remains
      final_sessions = cli.send(:load_sessions)
      expect(final_sessions.keys).to include("alive", "_schema")
      expect(final_sessions.keys).not_to include("dead1", "dead2")
    end
  end
  
  describe "multi-environment support" do
    it "supports different Rails environments for different sessions" do
      # This would require actual Rails adapter testing
      # Skipping for now since it needs real Rails integration
      skip "Requires actual Rails project for environment testing"
    end
  end
  
  describe "error recovery" do
    let(:cli) { Consolle::CLI.new }
    
    before do
      cli.options = { target: "test" }
    end
    
    it "recovers from corrupted sessions.json" do
      # Write corrupted JSON
      File.write(sessions_file, "{ invalid json }")
      
      # Should return empty hash and not crash
      sessions = cli.send(:load_sessions)
      expect(sessions).to eq({})
    end
    
    it "handles missing sessions.json gracefully" do
      # Ensure file doesn't exist
      FileUtils.rm_f(sessions_file)
      
      sessions = cli.send(:load_sessions)
      expect(sessions).to eq({})
    end
    
    it "cleans up temp files on save failure" do
      # Make directory read-only to cause save to fail
      FileUtils.chmod(0444, File.dirname(sessions_file))
      
      # Attempt to save should fail but clean up temp file
      expect {
        cli.send(:save_sessions, { "test" => {} })
      }.to raise_error(StandardError)
      
      # No temp files should remain
      temp_files = Dir.glob("#{sessions_file}.tmp.*")
      expect(temp_files).to be_empty
    ensure
      # Restore permissions
      FileUtils.chmod(0755, File.dirname(sessions_file))
    end
  end
end