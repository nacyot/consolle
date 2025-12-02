# frozen_string_literal: true

require 'spec_helper'
require 'consolle/server/embedded_supervisor'
require 'consolle/server/supervisor_factory'

RSpec.describe Consolle::Server::EmbeddedSupervisor do
  describe '.supported?' do
    it 'returns true for Ruby 3.3+' do
      # Current Ruby is 3.4.1, so this should be true
      expect(described_class.supported?).to eq(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3.0'))
    end
  end

  describe '.check_support!' do
    context 'when Ruby version is supported' do
      it 'does not raise an error' do
        if described_class.supported?
          expect { described_class.check_support! }.not_to raise_error
        end
      end
    end
  end

  describe '#mode' do
    it 'returns :embedded' do
      # Skip - requires full Rails environment with bundled gems
      skip 'Requires complete Rails project with bundled gems'
    end
  end
end

RSpec.describe Consolle::Server::SupervisorFactory do
  let(:logger) { Logger.new(File.open(File::NULL, 'w')) }

  describe '.embedded_available?' do
    it 'returns boolean based on Ruby version' do
      result = described_class.embedded_available?
      expect(result).to eq(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3.0'))
    end
  end

  describe '.create' do
    let(:rails_root) { File.join(Dir.pwd, 'tmp/sample_app') }

    context 'with :pty mode' do
      it 'creates a ConsoleSupervisor', skip: 'Requires Rails project' do
        skip 'Requires Rails project' unless File.exist?(File.join(rails_root, 'config/environment.rb'))

        supervisor = described_class.create(
          rails_root: rails_root,
          mode: :pty,
          rails_env: 'test',
          logger: logger
        )

        expect(supervisor).to be_a(Consolle::Server::ConsoleSupervisor)
        expect(supervisor.mode).to eq(:pty)
        supervisor.stop
      end
    end

    context 'with :embed_rails mode' do
      it 'creates an EmbeddedSupervisor when supported', skip: 'Requires Rails project' do
        skip 'Ruby < 3.3' unless Consolle::Server::EmbeddedSupervisor.supported?
        skip 'Requires Rails project' unless File.exist?(File.join(rails_root, 'config/environment.rb'))

        supervisor = described_class.create(
          rails_root: rails_root,
          mode: :embed_rails,
          rails_env: 'test',
          logger: logger
        )

        expect(supervisor).to be_a(Consolle::Server::EmbeddedSupervisor)
        expect(supervisor.mode).to eq(:embed_rails)
        supervisor.stop
      end

      it 'raises error when Ruby < 3.3' do
        skip 'Ruby 3.3+ detected' if Consolle::Server::EmbeddedSupervisor.supported?

        expect {
          described_class.create(
            rails_root: rails_root,
            mode: :embed_rails,
            rails_env: 'test',
            logger: logger
          )
        }.to raise_error(Consolle::Errors::UnsupportedRubyVersion)
      end
    end

    context 'with legacy :embedded mode' do
      it 'normalizes to :embed_rails', skip: 'Requires Rails project' do
        skip 'Ruby < 3.3' unless Consolle::Server::EmbeddedSupervisor.supported?
        skip 'Requires Rails project' unless File.exist?(File.join(rails_root, 'config/environment.rb'))

        supervisor = described_class.create(
          rails_root: rails_root,
          mode: :embedded,
          rails_env: 'test',
          logger: logger
        )

        expect(supervisor).to be_a(Consolle::Server::EmbeddedSupervisor)
        expect(supervisor.mode).to eq(:embed_rails)
        supervisor.stop
      end
    end

    context 'with invalid mode' do
      it 'raises ArgumentError' do
        expect {
          described_class.create(rails_root: rails_root, mode: :invalid)
        }.to raise_error(ArgumentError, /Invalid mode/)
      end
    end
  end
end

RSpec.describe Consolle::Config do
  describe '#mode' do
    it 'defaults to :pty' do
      Dir.mktmpdir do |dir|
        config = described_class.new(dir)
        expect(config.mode).to eq(:pty)
      end
    end

    it 'parses embed-rails mode from config file' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, '.consolle.yml'), 'mode: embed-rails')
        config = described_class.new(dir)
        expect(config.mode).to eq(:embed_rails)
      end
    end

    it 'parses embed-irb mode from config file' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, '.consolle.yml'), 'mode: embed-irb')
        config = described_class.new(dir)
        expect(config.mode).to eq(:embed_irb)
      end
    end

    it 'normalizes legacy embedded mode to embed_rails' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, '.consolle.yml'), 'mode: embedded')
        config = described_class.new(dir)
        expect(config.mode).to eq(:embed_rails)
      end
    end

    it 'normalizes legacy auto mode to pty' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, '.consolle.yml'), 'mode: auto')
        config = described_class.new(dir)
        expect(config.mode).to eq(:pty)
      end
    end

    it 'warns and defaults to :pty for invalid mode' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, '.consolle.yml'), 'mode: invalid_mode')
        expect { described_class.new(dir) }.to output(/Invalid mode/).to_stderr
      end
    end
  end
end
