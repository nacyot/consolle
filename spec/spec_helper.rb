# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'consolle'
require 'timeout'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.warnings = true

  config.default_formatter = 'doc' if config.files_to_run.one?

  config.order = :defined # Run tests in defined order for easier debugging
  # Kernel.srand config.seed

  # Add timeout for all tests to prevent hanging
  config.around(:each) do |example|
    Timeout.timeout(30) do # Increased timeout
      example.run
    end
  end

  # Clean up ConsoleSupervisor watchdog threads before RSpec clears doubles
  config.after(:each) do
    Thread.list
          .select { |t| t[:consolle_watchdog] }
          .each do |t|
      t.kill
      begin
        t.join(0.1)
      rescue StandardError
        nil
      end
    end
  end
end
