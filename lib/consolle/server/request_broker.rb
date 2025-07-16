# frozen_string_literal: true

require "thread"
require "securerandom"
require "logger"

module Consolle
  module Server
    class RequestBroker
      attr_reader :supervisor, :logger

      def initialize(supervisor:, logger: nil)
        @supervisor = supervisor
        @logger = logger || Logger.new(STDOUT)
        @queue = Queue.new
        @running = false
        @worker_thread = nil
        @request_map = {}
        @mutex = Mutex.new
      end

      def start
        return if @running
        
        @running = true
        @worker_thread = start_worker
        logger.info "[RequestBroker] Started"
      end

      def stop
        return unless @running
        
        @running = false
        
        # Push poison pill to wake up worker
        @queue.push(nil)
        
        # Wait for worker to finish
        @worker_thread&.join(5)
        
        logger.info "[RequestBroker] Stopped"
      end

      def process_request(request)
        request_id = request["request_id"] || SecureRandom.uuid
        
        # Create future for response
        future = RequestFuture.new
        
        # Store in map
        @mutex.synchronize do
          @request_map[request_id] = future
        end
        
        # Queue request
        @queue.push({
          id: request_id,
          request: request,
          timestamp: Time.now
        })
        
        # Wait for response (with timeout)
        begin
          future.get(timeout: request["timeout"] || 30)
        rescue Timeout::Error
          {
            "success" => false,
            "error" => "RequestTimeout",
            "message" => "Request timed out",
            "request_id" => request_id
          }
        ensure
          # Clean up
          @mutex.synchronize do
            @request_map.delete(request_id)
          end
        end
      end

      private

      def start_worker
        Thread.new do
          logger.info "[RequestBroker] Worker thread started"
          
          while @running
            begin
              # Get next request
              item = @queue.pop
              
              # Check for poison pill
              break if item.nil? && !@running
              next if item.nil?
              
              # Process request
              process_item(item)
            rescue StandardError => e
              logger.error "[RequestBroker] Worker error: #{e.message}"
              logger.error e.backtrace.join("\n")
            end
          end
          
          logger.info "[RequestBroker] Worker thread stopped"
        end
      end

      def process_item(item)
        request_id = item[:id]
        request = item[:request]
        
        logger.debug "[RequestBroker] Processing request: #{request_id}"
        
        # Get future
        future = @mutex.synchronize { @request_map[request_id] }
        return unless future
        
        # Process based on request type
        response = case request["action"]
        when "eval", "exec"
          process_eval_request(request)
        when "status"
          process_status_request
        when "restart"
          process_restart_request
        else
          {
            "success" => false,
            "error" => "UnknownAction",
            "message" => "Unknown action: #{request["action"]}"
          }
        end
        
        # Add request_id to response
        response["request_id"] = request_id
        
        # Set future result
        future.set(response)
        
        logger.debug "[RequestBroker] Request completed: #{request_id}"
      rescue StandardError => e
        logger.error "[RequestBroker] Error processing request #{request_id}: #{e.message}"
        
        error_response = {
          "success" => false,
          "error" => e.class.name,
          "message" => e.message,
          "request_id" => request_id
        }
        
        future&.set(error_response)
      end

      def process_eval_request(request)
        code = request["code"]
        timeout = request["timeout"] || 30
        
        unless code
          return {
            "success" => false,
            "error" => "MissingParameter",
            "message" => "Missing required parameter: code"
          }
        end
        
        # Execute through supervisor
        result = @supervisor.eval(code, timeout: timeout)
        
        # Format response
        if result[:success]
          {
            "success" => true,
            "result" => result[:output],
            "execution_time" => result[:execution_time]
          }
        else
          {
            "success" => false,
            "error" => "ExecutionError",
            "message" => result[:output]
          }
        end
      end

      def process_status_request
        {
          "success" => true,
          "running" => @supervisor.running?,
          "pid" => @supervisor.pid,
          "rails_root" => @supervisor.rails_root,
          "rails_env" => @supervisor.rails_env
        }
      end

      def process_restart_request
        begin
          # Restart the Rails console subprocess
          new_pid = @supervisor.restart
          
          {
            "success" => true,
            "message" => "Rails console subprocess restarted",
            "pid" => new_pid,
            "rails_root" => @supervisor.rails_root,
            "rails_env" => @supervisor.rails_env
          }
        rescue StandardError => e
          logger.error "[RequestBroker] Restart failed: #{e.message}"
          logger.error e.backtrace.join("\n")
          
          {
            "success" => false,
            "error" => "RestartFailed",
            "message" => "Failed to restart Rails console: #{e.message}"
          }
        end
      end

      # Simple future implementation
      class RequestFuture
        def initialize
          @mutex = Mutex.new
          @condition = ConditionVariable.new
          @value = nil
          @set = false
        end

        def set(value)
          @mutex.synchronize do
            @value = value
            @set = true
            @condition.signal
          end
        end

        def get(timeout: nil)
          @mutex.synchronize do
            unless @set
              @condition.wait(@mutex, timeout)
              raise Timeout::Error, "Future timed out" unless @set
            end
            @value
          end
        end
      end
    end
  end
end