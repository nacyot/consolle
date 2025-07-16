# frozen_string_literal: true

require "spec_helper"
require "consolle/adapters/rails_console"

# RailsConsole adapter does not require Rails itself
# It's a tool to manage Rails console processes, so it should always be available
RSpec.describe "Consolle::Adapters::RailsConsole availability" do
  it "can use the adapter without Rails" do
    expect(defined?(Consolle::Adapters::RailsConsole)).to be_truthy
  end
end

RSpec.describe Consolle::Adapters::RailsConsole do
  let(:adapter) { described_class.new }

  describe "#initialize" do
    it "can set socket path" do
      adapter = described_class.new(socket_path: "/tmp/test.sock")
      expect(adapter.socket_path).to eq("/tmp/test.sock")
    end

    it "can set Rails environment" do
      adapter = described_class.new(rails_env: "test")
      expect(adapter.instance_variable_get(:@rails_env)).to eq("test")
    end
  end

  describe "#running?" do
    it "returns false when no process exists" do
      expect(adapter.running?).to be false
    end
  end

  describe "#process_pid" do
    it "returns nil when no process exists" do
      # Mock File.exist? to return false for PID file
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(/\.pid$/).and_return(false)
      
      expect(adapter.process_pid).to be_nil
    end
  end

  describe "#send_code" do
    it "raises an error when console is not running" do
      # Adapter has running? false in initial state, so
      # calling send_code should raise an error
      expect(adapter.running?).to be false
      
      # Debug: check adapter's @session state
      expect(adapter.instance_variable_get(:@session)).to be_nil
      
      expect { adapter.send_code("1 + 1") }.to raise_error(RuntimeError, "Console is not running")
    end
  end

  describe "#stop" do
    it "returns false even when no process exists" do
      expect(adapter.stop).to be false
    end
  end
end