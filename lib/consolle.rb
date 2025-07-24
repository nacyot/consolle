# frozen_string_literal: true

require_relative 'consolle/version'
require_relative 'consolle/cli'

# Server components
require_relative 'consolle/server/console_socket_server'
require_relative 'consolle/server/console_supervisor'
require_relative 'consolle/server/request_broker'

module Consolle
  class Error < StandardError; end
end
