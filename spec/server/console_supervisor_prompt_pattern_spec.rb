# frozen_string_literal: true

require 'spec_helper'
require 'consolle/server/console_supervisor'
require 'consolle/config'
require 'tempfile'
require 'fileutils'

RSpec.describe Consolle::Server::ConsoleSupervisor do
  describe '#prompt_pattern' do
    let(:temp_dir) { Dir.mktmpdir }
    let(:supervisor) do
      instance = described_class.allocate
      instance.instance_variable_set(:@rails_root, temp_dir)
      instance.instance_variable_set(:@logger, Logger.new(nil))
      instance.instance_variable_set(:@config, Consolle::Config.load(temp_dir))
      instance
    end

    after do
      FileUtils.rm_rf(temp_dir)
    end

    context 'without config file' do
      it 'returns default prompt pattern' do
        expect(supervisor.prompt_pattern).to eq(Consolle::Config::DEFAULT_PROMPT_PATTERN)
      end
    end

    context 'with custom prompt pattern in config file' do
      before do
        File.write(File.join(temp_dir, '.consolle.yml'), "prompt_pattern: 'custom\\(env\\):\\d+>'")
      end

      it 'returns custom prompt pattern' do
        config = Consolle::Config.load(temp_dir)
        supervisor.instance_variable_set(:@config, config)

        expect(supervisor.prompt_pattern).to be_a(Regexp)
        expect('custom(env):001>'.match?(supervisor.prompt_pattern)).to be true
      end
    end

    context 'with nil config' do
      it 'returns default prompt pattern' do
        supervisor.instance_variable_set(:@config, nil)
        expect(supervisor.prompt_pattern).to eq(Consolle::Config::DEFAULT_PROMPT_PATTERN)
      end
    end
  end

  describe 'prompt pattern matching in parse_output' do
    let(:temp_dir) { Dir.mktmpdir }
    let(:supervisor) do
      instance = described_class.allocate
      instance.instance_variable_set(:@rails_root, temp_dir)
      instance.instance_variable_set(:@logger, Logger.new(nil))
      instance.instance_variable_set(:@config, Consolle::Config.load(temp_dir))
      instance
    end

    after do
      FileUtils.rm_rf(temp_dir)
    end

    def parse_output(output, code = 'eval(...)')
      supervisor.send(:parse_output, output, code)
    end

    context 'with custom prompt pattern' do
      before do
        File.write(File.join(temp_dir, '.consolle.yml'), "prompt_pattern: 'custom>'")
        config = Consolle::Config.load(temp_dir)
        supervisor.instance_variable_set(:@config, config)
      end

      it 'filters out custom prompts from output' do
        output = "=> 42\ncustom>"
        result = parse_output(output)
        expect(result).to eq('=> 42')
      end
    end

    context 'with Rails-style custom prompt' do
      before do
        File.write(File.join(temp_dir, '.consolle.yml'), "prompt_pattern: 'ehr\\(dev\\):\\d+>'")
        config = Consolle::Config.load(temp_dir)
        supervisor.instance_variable_set(:@config, config)
      end

      it 'filters out Rails-style prompts' do
        output = "=> \"hello\"\nehr(dev):001>"
        result = parse_output(output)
        expect(result).to eq('=> "hello"')
      end
    end
  end
end
