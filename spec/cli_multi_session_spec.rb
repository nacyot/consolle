# frozen_string_literal: true

require "spec_helper"
require "consolle/cli"
require "tempfile"
require "json"

RSpec.describe "Multi-session support" do
  let(:cli) { Consolle::CLI.new }
  let(:test_dir) { Dir.mktmpdir }
  let(:sessions_file) { File.join(test_dir, "tmp/cone/sessions.json") }
  
  before do
    allow(Dir).to receive(:pwd).and_return(test_dir)
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with("config/environment.rb").and_return(true)
    FileUtils.mkdir_p(File.dirname(sessions_file))
  end
  
  after do
    FileUtils.rm_rf(test_dir)
  end
  
  describe "#sessions_file_path" do
    it "returns the correct sessions.json path" do
      expect(cli.send(:sessions_file_path)).to eq(File.join(test_dir, "tmp/cone/sessions.json"))
    end
  end
  
  describe "#project_socket_path" do
    it "uses target option for socket name" do
      cli.options = { target: "dev" }
      expect(cli.send(:project_socket_path)).to eq(File.join(test_dir, "tmp/cone/dev.socket"))
    end
    
    it "defaults to cone.socket" do
      cli.options = { target: "cone" }
      expect(cli.send(:project_socket_path)).to eq(File.join(test_dir, "tmp/cone/cone.socket"))
    end
  end
  
  describe "#project_pid_path" do
    it "uses target option for pid name" do
      cli.options = { target: "dev" }
      expect(cli.send(:project_pid_path)).to eq(File.join(test_dir, "tmp/cone/dev.pid"))
    end
  end
  
  describe "#project_log_path" do
    it "uses target option for log name" do
      cli.options = { target: "dev" }
      expect(cli.send(:project_log_path)).to eq(File.join(test_dir, "tmp/cone/dev.log"))
    end
  end
  
  describe "#load_sessions" do
    context "with no sessions file" do
      it "returns empty hash" do
        expect(cli.send(:load_sessions)).to eq({})
      end
    end
    
    context "with legacy single session format" do
      before do
        legacy_data = {
          "socket_path" => "/path/to/cone.socket",
          "process_pid" => 12345,
          "started_at" => Time.now.to_f,
          "rails_root" => test_dir
        }
        File.write(sessions_file, JSON.generate(legacy_data))
      end
      
      it "converts to new format with cone as default" do
        sessions = cli.send(:load_sessions)
        expect(sessions["cone"]).to include(
          "socket_path" => "/path/to/cone.socket",
          "process_pid" => 12345
        )
      end
    end
    
    context "with new multi-session format" do
      before do
        multi_data = {
          "_schema" => 1,
          "cone" => {
            "socket_path" => "/path/to/cone.socket",
            "process_pid" => 12345
          },
          "dev" => {
            "socket_path" => "/path/to/dev.socket", 
            "process_pid" => 67890
          }
        }
        File.write(sessions_file, JSON.generate(multi_data))
      end
      
      it "loads all sessions correctly" do
        sessions = cli.send(:load_sessions)
        expect(sessions["cone"]["process_pid"]).to eq(12345)
        expect(sessions["dev"]["process_pid"]).to eq(67890)
        expect(sessions["_schema"]).to eq(1)
      end
    end
  end
  
  describe "#save_sessions" do
    it "adds schema version and writes to file" do
      sessions = {
        "cone" => { "process_pid" => 12345 },
        "dev" => { "process_pid" => 67890 }
      }
      
      cli.send(:save_sessions, sessions)
      
      saved_data = JSON.parse(File.read(sessions_file))
      expect(saved_data["_schema"]).to eq(1)
      expect(saved_data["cone"]["process_pid"]).to eq(12345)
      expect(saved_data["dev"]["process_pid"]).to eq(67890)
    end
  end
  
  describe "#with_sessions_lock" do
    it "creates directory if not exists" do
      FileUtils.rm_rf(File.dirname(sessions_file))
      
      cli.send(:with_sessions_lock) do
        # Directory should be created
        expect(File.directory?(File.dirname(sessions_file))).to be true
      end
    end
    
    it "prevents concurrent access" do
      # This is a basic test - proper concurrency testing would require threads
      expect_any_instance_of(File).to receive(:flock).with(File::LOCK_EX)
      expect_any_instance_of(File).to receive(:flock).with(File::LOCK_UN)
      
      cli.send(:with_sessions_lock) { }
    end
  end
  
  describe "#process_alive?" do
    it "returns true for running process" do
      expect(cli.send(:process_alive?, Process.pid)).to be true
    end
    
    it "returns false for non-existent process" do
      expect(cli.send(:process_alive?, 999999)).to be false
    end
    
    it "returns false for nil pid" do
      expect(cli.send(:process_alive?, nil)).to be false
    end
  end
  
  describe "legacy session migration" do
    let(:legacy_file) { File.join(test_dir, "tmp/cone/session.json") }
    
    before do
      cli.options = { verbose: false }
      
      # Create legacy session.json
      legacy_data = {
        "socket_path" => "/path/to/cone.socket",
        "process_pid" => 12345,
        "started_at" => Time.now.to_f,
        "rails_root" => test_dir
      }
      File.write(legacy_file, JSON.generate(legacy_data))
    end
    
    it "migrates legacy session.json to sessions.json" do
      # Ensure sessions.json doesn't exist
      FileUtils.rm_f(sessions_file)
      
      # Load sessions should trigger migration
      sessions = cli.send(:load_sessions)
      
      # Check migration results
      expect(File.exist?(legacy_file)).to be false
      expect(File.exist?(sessions_file)).to be true
      
      expect(sessions["_schema"]).to eq(1)
      expect(sessions["cone"]["process_pid"]).to eq(12345)
    end
    
    it "does not migrate if sessions.json already exists" do
      # Create sessions.json
      File.write(sessions_file, JSON.generate({ "_schema" => 1, "test" => {} }))
      
      # Load sessions should not trigger migration
      sessions = cli.send(:load_sessions)
      
      # Legacy file should still exist
      expect(File.exist?(legacy_file)).to be true
      expect(sessions).not_to have_key("cone")
    end
  end
  
  describe "#ls with multiple sessions" do
    before do
      cli.options = { target: "cone" }
      multi_data = {
        "_schema" => 1,
        "cone" => {
          "socket_path" => File.join(test_dir, "tmp/cone/cone.socket"),
          "process_pid" => Process.pid  # Use current process for alive check
        },
        "dev" => {
          "socket_path" => File.join(test_dir, "tmp/cone/dev.socket"),
          "process_pid" => 999999  # Non-existent process
        }
      }
      File.write(sessions_file, JSON.generate(multi_data))
      
      # Mock adapter to prevent actual socket connections
      adapter = double("adapter")
      allow(adapter).to receive(:get_status).and_return({
        "success" => true,
        "running" => true,
        "rails_env" => "development",
        "pid" => Process.pid
      })
      allow(cli).to receive(:create_rails_adapter).and_return(adapter)
    end
    
    it "shows active sessions and cleans up stale ones" do
      expect { cli.ls }.to output(/cone \(development\) - PID: #{Process.pid}/).to_stdout
      
      # Verify stale session was removed
      sessions = JSON.parse(File.read(sessions_file))
      expect(sessions).not_to have_key("dev")
    end
  end
end