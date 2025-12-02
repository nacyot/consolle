# frozen_string_literal: true

require 'spec_helper'
require 'consolle/errors'

RSpec.describe Consolle::Errors::PromptDetectionError do
  describe '#message' do
    let(:error) do
      described_class.new(
        timeout: 25,
        received_output: received_output,
        expected_patterns: expected_patterns,
        config_path: '/path/to/.consolle.yml'
      )
    end

    let(:received_output) { "Loading development environment (Rails 8.1.0)\nehr(dev):001>" }
    let(:expected_patterns) { "Default patterns:\n  - app(env)>" }

    it 'includes timeout information' do
      expect(error.message).to include('25 seconds')
    end

    it 'includes received output' do
      expect(error.message).to include('Received output')
      expect(error.message).to include('ehr(dev):001>')
    end

    it 'includes potential prompt' do
      expect(error.message).to include('Potential prompt found')
      expect(error.message).to include('ehr(dev):001>')
    end

    it 'includes expected patterns' do
      expect(error.message).to include('Default patterns')
    end

    it 'includes config file path' do
      expect(error.message).to include('/path/to/.consolle.yml')
    end

    it 'includes fix instructions' do
      expect(error.message).to include('prompt_pattern:')
      expect(error.message).to include('CONSOLLE_PROMPT_PATTERN')
    end

    context 'with empty output' do
      let(:received_output) { '' }

      it 'handles empty output gracefully' do
        expect { error.message }.not_to raise_error
      end
    end

    context 'with ANSI codes in output' do
      let(:received_output) { "\e[32mLoading\e[0m dev\napp(dev):001>" }

      it 'strips ANSI codes from potential prompt suggestion' do
        # The escape_for_yaml method should clean up ANSI codes
        expect(error.message).not_to include('\e[')
      end
    end

    context 'with nil output' do
      let(:received_output) { nil }

      it 'handles nil output gracefully' do
        expect { error.message }.not_to raise_error
      end
    end
  end

  describe 'attributes' do
    let(:error) do
      described_class.new(
        timeout: 25,
        received_output: 'test output',
        expected_patterns: 'test patterns',
        config_path: '/test/path'
      )
    end

    it 'exposes received_output' do
      expect(error.received_output).to eq('test output')
    end

    it 'exposes expected_patterns' do
      expect(error.expected_patterns).to eq('test patterns')
    end

    it 'exposes config_path' do
      expect(error.config_path).to eq('/test/path')
    end
  end
end

RSpec.describe Consolle::Errors::ErrorClassifier do
  describe '.to_code' do
    it 'classifies PromptDetectionError' do
      error = Consolle::Errors::PromptDetectionError.new(
        timeout: 25,
        received_output: 'test',
        expected_patterns: 'test',
        config_path: '/test'
      )
      expect(described_class.to_code(error)).to eq('PROMPT_DETECTION_ERROR')
    end
  end
end
