# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "timeout"

RSpec.describe "Socket Server Integration" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:socket_path) { File.join(tmpdir, "test.socket") }
  let(:rails_root) { File.expand_path("../../../../../..", __dir__) }
  let(:adapter) { Consolle::Adapters::RailsConsole.new(socket_path: socket_path, rails_root: rails_root, rails_env: "test") }

  after do
    # Cleanup after test
    adapter.stop rescue nil
    FileUtils.rm_rf(tmpdir) if Dir.exist?(tmpdir)
  end

  describe "server start/stop" do
    it "can start and stop socket server" do
      skip "Skip if not a Rails project" unless File.exist?(File.join(rails_root, "config/environment.rb"))

      # Start server
      expect(adapter.start).to be true
      expect(adapter.running?).to be true
      expect(File.exist?(socket_path)).to be true
      
      # Check PID
      pid = adapter.process_pid
      expect(pid).to be_a(Integer)
      expect(pid).to be > 0
      
      # Stop server
      expect(adapter.stop).to be true
      expect(adapter.running?).to be false
      expect(File.exist?(socket_path)).to be false
    end
  end

  describe "code execution" do
    it "executes Ruby code and returns result" do
      skip "Skip if not a Rails project" unless File.exist?(File.join(rails_root, "config/environment.rb"))

      adapter.start
      
      # Simple calculation
      result = adapter.send_code("1 + 1")
      expect(result["success"]).to be true
      expect(result["result"]).to eq("2")
      
      # Rails related code
      result = adapter.send_code("Rails.version")
      expect(result["success"]).to be true
      expect(result["result"]).to match(/\d+\.\d+\.\d+/)
      
      adapter.stop
    end
  end

  describe "timeout handling" do
    it "can interrupt infinite loop with timeout" do
      skip "Skip if not a Rails project" unless File.exist?(File.join(rails_root, "config/environment.rb"))

      adapter.start
      
      # Infinite loop with short timeout
      result = adapter.send_code("loop { sleep 0.1 }", timeout: 2)
      expect(result["success"]).to be false
      expect(result["message"]).to include("timed out")
      
      # Still works normally after interruption
      result = adapter.send_code("2 + 2")
      expect(result["success"]).to be true
      expect(result["result"]).to eq("4")
      
      adapter.stop
    end
  end

  describe "server restart" do
    it "can restart server" do
      skip "Skip if not a Rails project" unless File.exist?(File.join(rails_root, "config/environment.rb"))

      # First start
      adapter.start
      first_pid = adapter.process_pid
      
      # Restart
      adapter.restart
      second_pid = adapter.process_pid
      
      # Check if PID changed
      expect(second_pid).not_to eq(first_pid)
      expect(adapter.running?).to be true
      
      # Still works normally after restart
      result = adapter.send_code("3 + 3")
      expect(result["success"]).to be true
      expect(result["result"]).to eq("6")
      
      adapter.stop
    end
  end

  describe "error handling" do
    it "handles syntax errors properly" do
      skip "Skip if not a Rails project" unless File.exist?(File.join(rails_root, "config/environment.rb"))

      adapter.start
      
      # Syntax error
      result = adapter.send_code("1 +")
      expect(result["success"]).to be false
      expect(result["message"]).to include("syntax error")
      
      # Still works normally after error
      result = adapter.send_code("4 + 4")
      expect(result["success"]).to be true
      expect(result["result"]).to eq("8")
      
      adapter.stop
    end

    it "handles runtime errors properly" do
      skip "Skip if not a Rails project" unless File.exist?(File.join(rails_root, "config/environment.rb"))

      adapter.start
      
      # Runtime error
      result = adapter.send_code("1 / 0")
      expect(result["success"]).to be false
      expect(result["message"]).to include("divided by 0")
      
      # Still works normally after error
      result = adapter.send_code("5 + 5")
      expect(result["success"]).to be true
      expect(result["result"]).to eq("10")
      
      adapter.stop
    end
  end
end