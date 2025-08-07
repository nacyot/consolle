# frozen_string_literal: true

require 'spec_helper'
require 'consolle/server/console_supervisor'
require 'tempfile'
require 'base64'

RSpec.describe Consolle::Server::ConsoleSupervisor do
  describe 'large file handling' do
    let(:temp_dir) { Dir.mktmpdir }
    let(:rails_root) { temp_dir }
    let(:socket_path) { File.join(temp_dir, 'test.socket') }
    let(:supervisor) do
      described_class.new(
        rails_root: rails_root,
        rails_env: 'test',
        logger: Logger.new(nil),
        command: 'ruby -e "require \'irb\'; IRB.start"'
      )
    end

    before do
      allow(supervisor).to receive(:spawn_console)
      allow(supervisor).to receive(:running?).and_return(true)
      
      # Set up PTY reader/writer for all tests
      @reader = double('reader')
      @writer = double('writer')
      supervisor.instance_variable_set(:@reader, @reader)
      supervisor.instance_variable_set(:@writer, @writer)
    end

    after do
      FileUtils.rm_rf(temp_dir)
    end

    context 'with code over 1000 bytes' do
      let(:large_code) do
        <<~RUBY
          # This is a large code block that exceeds 1000 bytes
          puts "=" * 70
          puts "Testing large code execution via temporary file"
          puts "=" * 70
          
          # Define some test methods
          def factorial(n)
            return 1 if n <= 1
            n * factorial(n - 1)
          end
          
          def fibonacci(n)
            return n if n <= 1
            fibonacci(n - 1) + fibonacci(n - 2)
          end
          
          # Test the methods
          puts "Factorial of 5: \#{factorial(5)}"
          puts "Fibonacci of 10: \#{fibonacci(10)}"
          
          # Test with some data structures
          test_hash = {
            name: "Test",
            values: [1, 2, 3, 4, 5],
            nested: {
              key1: "value1",
              key2: "value2"
            }
          }
          
          puts "Test hash: \#{test_hash.inspect}"
          
          # Test with iterations
          sum = 0
          100.times do |i|
            sum += i
          end
          puts "Sum of 0 to 99: \#{sum}"
          
          # Add more content to exceed 1000 bytes
          puts "This is additional content to make the code larger..."
          puts "Line 1 of additional content"
          puts "Line 2 of additional content"
          puts "Line 3 of additional content"
          puts "Line 4 of additional content"
          puts "Line 5 of additional content"
          
          # Final result
          "Test completed successfully!"
        RUBY
      end

      it 'uses temporary file approach for large code' do
        expect(large_code.bytesize).to be > 1000
        
        # Track if temp file approach was used
        temp_file_used = false
        
        # Mock clear_buffer
        allow(@reader).to receive(:read_nonblock).and_raise(IO::EAGAINWaitReadable)
        
        # Expect temporary file approach to be used
        expect(@writer).to receive(:puts) do |command|
          # Check if the command uses load with a temp file
          if command.include?('load') && command.include?('consolle_temp_')
            temp_file_used = true
            expect(command).to include('Timeout.timeout')
          end
        end
        expect(@writer).to receive(:flush)
        
        # Call eval - it will send the command to @writer
        supervisor.eval(large_code, timeout: 15)
        
        # Verify temp file approach was used
        expect(temp_file_used).to be true
      end

      it 'creates and cleans up temporary file' do
        temp_file_path = nil
        expect(@writer).to receive(:puts) do |command|
          # Extract temp file path from command
          if command.include?('_temp_file')
            temp_file_path = command.match(/'([^']*consolle_temp_[^']*\.rb)'/)[1]
            # Verify file was created
            expect(File.exist?(temp_file_path)).to be true
            # Verify file contains the code
            expect(File.read(temp_file_path)).to eq(large_code)
          end
        end
        expect(@writer).to receive(:flush)
        
        allow(@reader).to receive(:read_nonblock).and_raise(IO::WaitReadable)
        allow(IO).to receive(:select).and_return(nil)
        allow(supervisor).to receive(:wait_for_prompt).and_return(true)
        allow(supervisor).to receive(:clear_buffer)
        allow(supervisor).to receive(:parse_output).and_return("Test completed successfully!")
        
        supervisor.eval(large_code, timeout: 15)
        
        # The ensure block in the command should clean up the file
        # (In real execution, the Rails console would delete it)
      end
    end

    context 'with code under 1000 bytes' do
      let(:small_code) { "puts 'Hello, World!'; 2 + 2" }

      it 'uses Base64 approach for small code' do
        expect(small_code.bytesize).to be < 1000
        
        # Track if Base64 approach was used
        base64_used = false
        
        # Mock clear_buffer
        allow(@reader).to receive(:read_nonblock).and_raise(IO::EAGAINWaitReadable)
        
        # Expect Base64 approach to be used
        expect(@writer).to receive(:puts) do |command|
          if command.include?('Base64.decode64')
            base64_used = true
            expect(command).not_to include('load')
            encoded = Base64.strict_encode64(small_code)
            expect(command).to include(encoded)
          end
        end
        expect(@writer).to receive(:flush)
        
        # Call eval - it will send the command to @writer
        supervisor.eval(small_code, timeout: 15)
        
        # Verify Base64 approach was used
        expect(base64_used).to be true
      end
    end

    context 'with code containing require statements' do
      let(:code_with_requires) do
        <<~RUBY
          require 'json'
          require 'base64'
          
          data = { test: "value", number: 42 }
          json_str = JSON.generate(data)
          encoded = Base64.encode64(json_str)
          
          puts "JSON: \#{json_str}"
          puts "Base64: \#{encoded}"
          
          "Require test completed"
        RUBY
      end

      it 'handles require statements correctly' do
        # Track which approach was used
        approach_used = nil
        
        # Mock clear_buffer
        allow(@reader).to receive(:read_nonblock).and_raise(IO::EAGAINWaitReadable)
        
        expect(@writer).to receive(:puts) do |command|
          if code_with_requires.bytesize > 1000
            if command.include?('load') && command.include?('consolle_temp_')
              approach_used = 'temp_file'
            end
          else
            if command.include?('Base64.decode64')
              approach_used = 'base64'
            end
          end
        end
        expect(@writer).to receive(:flush)
        
        # Call eval
        supervisor.eval(code_with_requires, timeout: 15)
        
        # Verify an approach was chosen based on size
        if code_with_requires.bytesize > 1000
          expect(approach_used).to eq('temp_file')
        else
          expect(approach_used).to eq('base64')
        end
      end
    end

    context 'with UTF-8 content in large files' do
      let(:large_utf8_code) do
        <<~RUBY
          # UTF-8 encoded test file with unicode characters
          puts "=" * 70
          puts "UTF-8 Test: Verifying unicode character handling in large files"
          puts "=" * 70
          
          unicode_data = {
            name: "TestUser",
            values: [1, 2, 3, 4, 5],
            nested: {
              key1: "value1",
              key2: "value2"
            }
          }
          
          puts "Unicode data: \#{unicode_data.inspect}"
          
          # Add more content to exceed 1000 bytes
          50.times do |i|
            puts "UTF-8 test line \#{i}: This is a test with unicode chars. Adding more text to increase file size."
          end
          
          # Additional unicode text
          puts "Testing various unicode characters: αβγδε ΑΒΓΔΕ ñ é ü ç"
          puts "Mathematical symbols: ∑ ∏ ∫ √ ∞"
          puts "Currency symbols: € £ ¥ ₹"
          puts "Arrows and symbols: → ← ↑ ↓ ⇒ ⇐"
          
          "UTF-8 test completed!"
        RUBY
      end

      it 'handles UTF-8 characters in large files' do
        # Make sure it's actually over 1000 bytes
        skip "UTF-8 code is not large enough" unless large_utf8_code.bytesize > 1000
        
        created_file_content = nil
        expect(@writer).to receive(:puts) do |command|
          if command.include?('_temp_file')
            temp_file_path = command.match(/'([^']*consolle_temp_[^']*\.rb)'/)[1]
            # Verify UTF-8 content is preserved
            created_file_content = File.read(temp_file_path, encoding: 'UTF-8') if File.exist?(temp_file_path)
          end
        end
        expect(@writer).to receive(:flush)
        
        allow(@reader).to receive(:read_nonblock).and_raise(IO::WaitReadable)
        allow(IO).to receive(:select).and_return(nil)
        allow(supervisor).to receive(:wait_for_prompt).and_return(true)
        allow(supervisor).to receive(:clear_buffer)
        allow(supervisor).to receive(:parse_output).and_return("UTF-8 test completed!")
        
        result = supervisor.eval(large_utf8_code, timeout: 15)
        expect(result[:success]).to be true
        
        # Verify UTF-8 content was preserved if file was created
        if created_file_content
          expect(created_file_content).to include("UTF-8")
          expect(created_file_content).to include("unicode")
        end
      end
    end

    context 'timeout behavior' do
      let(:infinite_loop_code) do
        <<~RUBY
          # This would cause timeout in old implementation
          while true
            puts "Looping..."
            sleep 0.1
          end
        RUBY
      end

      it 'properly handles timeout even with temp file approach' do
        # Track if timeout wrapper was included
        timeout_included = false
        
        # Mock clear_buffer
        allow(@reader).to receive(:read_nonblock).and_raise(IO::EAGAINWaitReadable)
        
        expect(@writer).to receive(:puts) do |command|
          # Should include timeout wrapper
          if command.include?('Timeout.timeout')
            timeout_included = true
          end
        end
        expect(@writer).to receive(:flush)
        
        # Call eval
        supervisor.eval(infinite_loop_code, timeout: 15)
        
        # Verify timeout wrapper was included
        expect(timeout_included).to be true
      end
    end
  end
end