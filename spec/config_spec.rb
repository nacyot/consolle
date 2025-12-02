# frozen_string_literal: true

require 'spec_helper'
require 'consolle/config'
require 'tempfile'
require 'fileutils'

RSpec.describe Consolle::Config do
  let(:temp_dir) { Dir.mktmpdir }

  after do
    FileUtils.rm_rf(temp_dir)
  end

  describe '.load' do
    it 'returns a Config instance' do
      config = described_class.load(temp_dir)
      expect(config).to be_a(described_class)
    end
  end

  describe '#prompt_pattern' do
    context 'without config file' do
      it 'returns default prompt pattern' do
        config = described_class.load(temp_dir)
        expect(config.prompt_pattern).to eq(Consolle::Config::DEFAULT_PROMPT_PATTERN)
      end

      it 'is not custom' do
        config = described_class.load(temp_dir)
        expect(config.custom_prompt_pattern?).to be false
      end
    end

    context 'with valid config file' do
      before do
        File.write(File.join(temp_dir, '.consolle.yml'), config_content)
      end

      context 'with custom prompt_pattern' do
        let(:config_content) { "prompt_pattern: 'myapp\\(.*\\):\\d+>'" }

        it 'returns custom prompt pattern as Regexp' do
          config = described_class.load(temp_dir)
          expect(config.prompt_pattern).to be_a(Regexp)
          expect(config.prompt_pattern.source).to eq('myapp\(.*\):\d+>')
        end

        it 'is custom' do
          config = described_class.load(temp_dir)
          expect(config.custom_prompt_pattern?).to be true
        end

        it 'stores raw pattern' do
          config = described_class.load(temp_dir)
          expect(config.raw_prompt_pattern).to eq('myapp\(.*\):\d+>')
        end
      end

      context 'with simple prompt_pattern' do
        let(:config_content) { "prompt_pattern: '>'" }

        it 'matches simple prompts' do
          config = described_class.load(temp_dir)
          expect('>'.match?(config.prompt_pattern)).to be true
        end
      end

      context 'with Rails-style prompt_pattern' do
        let(:config_content) { "prompt_pattern: 'ehr\\(dev\\):\\d+>'" }

        it 'matches Rails console prompts with line numbers' do
          config = described_class.load(temp_dir)
          expect('ehr(dev):001>'.match?(config.prompt_pattern)).to be true
          expect('ehr(dev):123>'.match?(config.prompt_pattern)).to be true
        end
      end
    end

    context 'with invalid config file' do
      context 'invalid YAML syntax' do
        before do
          File.write(File.join(temp_dir, '.consolle.yml'), "invalid: yaml: content:")
        end

        it 'returns default prompt pattern' do
          config = described_class.load(temp_dir)
          expect(config.prompt_pattern).to eq(Consolle::Config::DEFAULT_PROMPT_PATTERN)
        end
      end

      context 'invalid regex pattern' do
        before do
          File.write(File.join(temp_dir, '.consolle.yml'), "prompt_pattern: '[invalid regex'")
        end

        it 'returns default prompt pattern' do
          config = described_class.load(temp_dir)
          expect(config.prompt_pattern).to eq(Consolle::Config::DEFAULT_PROMPT_PATTERN)
        end
      end
    end

    context 'with empty config file' do
      before do
        File.write(File.join(temp_dir, '.consolle.yml'), '')
      end

      it 'returns default prompt pattern' do
        config = described_class.load(temp_dir)
        expect(config.prompt_pattern).to eq(Consolle::Config::DEFAULT_PROMPT_PATTERN)
      end
    end
  end

  describe '#prompt_pattern_description' do
    context 'without custom pattern' do
      it 'returns default patterns description' do
        config = described_class.load(temp_dir)
        desc = config.prompt_pattern_description
        expect(desc).to include('Default patterns')
        expect(desc).to include('app(env)')
        expect(desc).to include('irb(main)')
      end
    end

    context 'with custom pattern' do
      before do
        File.write(File.join(temp_dir, '.consolle.yml'), "prompt_pattern: 'custom>'")
      end

      it 'returns custom pattern description' do
        config = described_class.load(temp_dir)
        desc = config.prompt_pattern_description
        expect(desc).to include('Custom pattern')
        expect(desc).to include('custom>')
      end
    end
  end

  describe 'DEFAULT_PROMPT_PATTERN' do
    let(:pattern) { Consolle::Config::DEFAULT_PROMPT_PATTERN }

    it 'matches standard IRB prompts' do
      expect('irb(main):001:0>'.match?(pattern)).to be true
      expect('irb(main):001>'.match?(pattern)).to be true
    end

    it 'matches Rails console prompts without line numbers' do
      expect('app(dev)>'.match?(pattern)).to be true
      expect('myapp(development)>'.match?(pattern)).to be true
    end

    it 'matches Rails console prompts with line numbers' do
      expect('app(dev):001>'.match?(pattern)).to be true
      expect('ehr(dev):001>'.match?(pattern)).to be true
      expect('myapp(production):123>'.match?(pattern)).to be true
    end

    it 'matches Consolle sentinel prompt' do
      sentinel = "\u001E\u001F<CONSOLLE>\u001F\u001E"
      expect(sentinel.match?(pattern)).to be true
    end

    it 'matches generic prompts' do
      expect('>>'.match?(pattern)).to be true
      expect('>'.match?(pattern)).to be true
    end

    it 'does not match non-prompt text' do
      expect('Hello World'.match?(pattern)).to be false
      expect('=> 42'.match?(pattern)).to be false
    end
  end
end
