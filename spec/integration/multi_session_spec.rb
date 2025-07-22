# frozen_string_literal: true

require "spec_helper"
require "consolle/cli"
require "tempfile"
require "json"

RSpec.describe "Multi-session integration tests" do
  let(:test_dir) { Dir.mktmpdir }
  let(:sessions_file) { File.join(test_dir, "tmp/cone/sessions.json") }
  
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
  
  describe "starting multiple sessions" do
    it "creates separate files for each target session" do
      # Mock the adapter to prevent actual server startup
      adapter_cone = double("adapter_cone")
      adapter_dev = double("adapter_dev")
      
      allow(adapter_cone).to receive(:socket_path).and_return(File.join(test_dir, "tmp/cone/cone.socket"))
      allow(adapter_cone).to receive(:process_pid).and_return(12345)
      allow(adapter_cone).to receive(:pid_path).and_return(File.join(test_dir, "tmp/cone/cone.pid"))
      allow(adapter_cone).to receive(:log_path).and_return(File.join(test_dir, "tmp/cone/cone.log"))
      allow(adapter_cone).to receive(:running?).and_return(false)
      allow(adapter_cone).to receive(:start).and_return(true)
      
      allow(adapter_dev).to receive(:socket_path).and_return(File.join(test_dir, "tmp/cone/dev.socket"))
      allow(adapter_dev).to receive(:process_pid).and_return(67890)
      allow(adapter_dev).to receive(:pid_path).and_return(File.join(test_dir, "tmp/cone/dev.pid"))
      allow(adapter_dev).to receive(:log_path).and_return(File.join(test_dir, "tmp/cone/dev.log"))
      allow(adapter_dev).to receive(:running?).and_return(false)
      allow(adapter_dev).to receive(:start).and_return(true)
      
      # Start default session
      cli = Consolle::CLI.new
      cli.options = { target: "cone", rails_env: "development", verbose: false }
      allow(cli).to receive(:create_rails_adapter).with("development", "cone", nil).and_return(adapter_cone)
      allow(cli).to receive(:load_session_info).and_return(nil)
      allow(cli).to receive(:log_session_event)
      
      expect { cli.start }.to output(/Rails console started successfully/).to_stdout
      
      # Start dev session
      cli2 = Consolle::CLI.new  
      cli2.options = { target: "dev", rails_env: "development", verbose: false }
      allow(cli2).to receive(:create_rails_adapter).with("development", "dev", nil).and_return(adapter_dev)
      allow(cli2).to receive(:load_session_info).and_return(nil)
      allow(cli2).to receive(:log_session_event)
      
      expect { cli2.start }.to output(/Rails console started successfully/).to_stdout
      
      # Verify sessions.json contains both sessions
      sessions = JSON.parse(File.read(sessions_file))
      expect(sessions["cone"]["process_pid"]).to eq(12345)
      expect(sessions["dev"]["process_pid"]).to eq(67890)
    end
  end
  
  describe "exec with target option" do
    before do
      # Set up sessions file with multiple sessions
      sessions_data = {
        "_schema" => 1,
        "cone" => {
          "socket_path" => File.join(test_dir, "tmp/cone/cone.socket"),
          "process_pid" => 12345
        },
        "dev" => {
          "socket_path" => File.join(test_dir, "tmp/cone/dev.socket"),
          "process_pid" => 67890
        }
      }
      File.write(sessions_file, JSON.generate(sessions_data))
    end
    
    it "executes code on the correct target session" do
      cli = Consolle::CLI.new
      cli.options = { target: "dev", timeout: 15, verbose: false, raw: false }
      
      # Mock Rails project checks
      allow(cli).to receive(:ensure_rails_project!)
      allow(cli).to receive(:ensure_project_directories)
      allow(cli).to receive(:validate_session_name!)
      
      # Mock load_session_info to return the dev session info
      session_info = {
        socket_path: File.join(test_dir, "tmp/cone/dev.socket"),
        process_pid: 67890,
        started_at: Time.now.to_f,
        rails_root: test_dir
      }
      allow(cli).to receive(:load_session_info).and_return(session_info)
      
      # Mock the socket connection check that happens in exec to verify server is running
      mock_socket = double("socket")
      allow(UNIXSocket).to receive(:new).with(File.join(test_dir, "tmp/cone/dev.socket")).and_return(mock_socket)
      allow(mock_socket).to receive(:write)
      allow(mock_socket).to receive(:flush)
      allow(mock_socket).to receive(:gets).and_return('{"success":true,"running":true}')
      allow(mock_socket).to receive(:close)
      
      # Mock socket connection to dev session
      allow(cli).to receive(:send_code_to_socket).with(
        File.join(test_dir, "tmp/cone/dev.socket"),
        "User.count",
        timeout: 15
      ).and_return({
        "success" => true,
        "result" => "42",
        "request_id" => "123"
      })
      
      allow(cli).to receive(:log_session_activity)
      
      # Should use dev.socket, not cone.socket
      expect(cli).to receive(:send_code_to_socket).with(
        File.join(test_dir, "tmp/cone/dev.socket"),
        "User.count",
        timeout: 15
      )
      
      expect { cli.exec("User.count") }.to output("42\n").to_stdout
    end
  end
  
  describe "backward compatibility" do
    it "handles existing session.json file gracefully" do
      # Create old format session.json (not sessions.json)
      old_session_file = File.join(test_dir, "tmp/cone/session.json")
      old_data = {
        "socket_path" => File.join(test_dir, "tmp/cone/cone.socket"),
        "process_pid" => 12345,
        "started_at" => Time.now.to_f,
        "rails_root" => test_dir
      }
      File.write(old_session_file, JSON.generate(old_data))
      
      cli = Consolle::CLI.new
      cli.options = { target: "cone", verbose: false }
      
      # load_session_info should work after migration
      session_info = cli.send(:load_session_info)
      
      # Should return migrated session info
      expect(session_info[:process_pid]).to eq(12345)
      expect(session_info[:socket_path]).to eq(File.join(test_dir, "tmp/cone/cone.socket"))
      
      # Old file should be deleted
      expect(File.exist?(old_session_file)).to be false
      
      # New file should exist
      expect(File.exist?(sessions_file)).to be true
    end
  end
end