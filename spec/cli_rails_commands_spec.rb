# frozen_string_literal: true

require 'spec_helper'
require 'consolle/cli'

RSpec.describe Consolle::RailsCommands do
  describe '#reload' do
    let(:commands) { described_class.new }

    before do
      commands.options = { target: 'cone', verbose: false }
    end

    it 'executes reload! code' do
      cli_double = instance_double(Consolle::CLI)
      allow(Consolle::CLI).to receive(:new).and_return(cli_double)
      allow(cli_double).to receive(:options=)
      allow(cli_double).to receive(:exec).with('reload!')

      commands.reload

      expect(cli_double).to have_received(:exec).with('reload!')
    end
  end

  describe '#env' do
    let(:commands) { described_class.new }

    before do
      commands.options = { target: 'cone', verbose: false }
    end

    it 'executes Rails.env code' do
      cli_double = instance_double(Consolle::CLI)
      allow(Consolle::CLI).to receive(:new).and_return(cli_double)
      allow(cli_double).to receive(:options=)
      allow(cli_double).to receive(:exec).with('Rails.env')

      commands.env

      expect(cli_double).to have_received(:exec).with('Rails.env')
    end
  end

  describe '#db' do
    let(:commands) { described_class.new }

    before do
      commands.options = { target: 'cone', verbose: false }
    end

    it 'executes database info code' do
      cli_double = instance_double(Consolle::CLI)
      allow(Consolle::CLI).to receive(:new).and_return(cli_double)
      allow(cli_double).to receive(:options=)
      allow(cli_double).to receive(:exec)

      commands.db

      expect(cli_double).to have_received(:exec) do |code|
        expect(code).to include('ActiveRecord::Base.connection_db_config')
        expect(code).to include('Adapter:')
        expect(code).to include('Database:')
        expect(code).to include('Connected:')
      end
    end
  end
end
