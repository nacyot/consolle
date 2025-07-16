# frozen_string_literal: true

require "spec_helper"
require "consolle/server/request_broker"
require "consolle/server/console_supervisor"

RSpec.describe Consolle::Server::RequestBroker do
  let(:supervisor) do 
    double("ConsoleSupervisor",
      rails_root: "/fake/rails/root",
      rails_env: "test",
      pid: 12345,
      running?: true
    )
  end
  let(:logger) { Logger.new(nil) }
  let(:broker) { described_class.new(supervisor: supervisor, logger: logger) }

  describe "#initialize" do
    it "sets supervisor and logger" do
      expect(broker.instance_variable_get(:@supervisor)).to eq(supervisor)
      expect(broker.instance_variable_get(:@logger)).to eq(logger)
    end
  end

  describe "#start / #stop" do
    it "can start and stop" do
      broker.start
      expect(broker.instance_variable_get(:@running)).to be true
      
      broker.stop
      expect(broker.instance_variable_get(:@running)).to be false
    end
  end

  describe "#process_request" do
    before do
      broker.start
    end

    after do
      broker.stop
    end

    context "status action" do
      it "returns server status" do
        allow(supervisor).to receive(:pid).and_return(12345)
        allow(supervisor).to receive(:running?).and_return(true)

        request = { "action" => "status", "request_id" => "test-123" }
        response = broker.process_request(request)

        expect(response["success"]).to be true
        expect(response["pid"]).to eq(12345)
        expect(response["running"]).to be true
        expect(response["request_id"]).to eq("test-123")
      end
    end

    context "eval action" do
      it "executes code and returns result" do
        allow(supervisor).to receive(:eval).with("1 + 1", timeout: 30).and_return({
          success: true,
          output: "2",
          execution_time: 0.1
        })

        request = { "action" => "eval", "code" => "1 + 1", "request_id" => "test-123" }
        response = broker.process_request(request)

        expect(response["success"]).to be true
        expect(response["result"]).to eq("2")
        expect(response["execution_time"]).to eq(0.1)
        expect(response["request_id"]).to eq("test-123")
      end

      it "passes timeout" do
        allow(supervisor).to receive(:eval).with("sleep 10", timeout: 2).and_return({
          success: false,
          output: "Execution timed out after 2 seconds",
          execution_time: 2
        })

        request = { "action" => "eval", "code" => "sleep 10", "timeout" => 2, "request_id" => "test-123" }
        response = broker.process_request(request)

        expect(response["success"]).to be false
        expect(response["error"]).to eq("ExecutionError")
        expect(response["message"]).to include("timed out")
      end

      it "returns error when code is missing" do
        request = { "action" => "eval", "request_id" => "test-123" }
        response = broker.process_request(request)

        expect(response["success"]).to be false
        expect(response["error"]).to eq("MissingParameter")
        expect(response["message"]).to include("Missing required parameter: code")
      end
    end

    context "restart action" do
      it "restarts Rails console process" do
        allow(supervisor).to receive(:restart).and_return(23456)

        request = { "action" => "restart", "request_id" => "test-123" }
        response = broker.process_request(request)

        expect(response["success"]).to be true
        expect(response["pid"]).to eq(23456)
        expect(response["message"]).to include("restarted")
        expect(response["request_id"]).to eq("test-123")
      end

      it "returns error when restart fails" do
        allow(supervisor).to receive(:restart).and_raise(StandardError, "Restart failed")

        request = { "action" => "restart", "request_id" => "test-123" }
        response = broker.process_request(request)

        expect(response["success"]).to be false
        expect(response["error"]).to eq("RestartFailed")
        expect(response["message"]).to include("Failed to restart")
      end
    end

    context "invalid action" do
      it "returns UnknownAction error" do
        request = { "action" => "invalid", "request_id" => "test-123" }
        response = broker.process_request(request)

        expect(response["success"]).to be false
        expect(response["error"]).to eq("UnknownAction")
        expect(response["message"]).to include("Unknown action: invalid")
      end
    end

    context "error handling" do
      it "handles supervisor errors properly" do
        allow(supervisor).to receive(:eval).and_raise(StandardError, "Something went wrong")

        request = { "action" => "eval", "code" => "1 + 1", "request_id" => "test-123" }
        response = broker.process_request(request)

        expect(response["success"]).to be false
        expect(response["error"]).to eq("StandardError")
        expect(response["message"]).to eq("Something went wrong")
      end
    end
  end
end