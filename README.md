# Consolle

Consolle is a library that manages Rails console through PTY (Pseudo-Terminal). Moving away from the traditional eval-based execution method, it manages the actual Rails console process as a subprocess to provide a more stable and secure execution environment.

## Key Features

- **PTY-based Rails Console Management**: Manages the actual Rails console process through PTY
- **Socket Server Architecture**: Stable client-server communication through Unix socket
- **Automatic Restart (Watchdog)**: Automatic recovery on process failure
- **Environment-specific Execution**: Supports Rails environments (development, test, production)
- **Timeout Handling**: Automatic termination of infinite loops and long-running code
- **Log Management**: Automatic management of execution history and session logs

## Installation

### 1. Install the Library
```bash
# From Rails project root
gem install consolle
```

### 2. Rails Project Configuration
```bash
# Add to Gemfile
gem 'consolle'
```

## Usage

### Basic Usage

```bash
# Start Rails console server
cone start

# Check status
cone status

# Execute code
cone exec "User.count"
cone -m "2 + 2"

# Stop server
cone stop

# Restart server
cone restart
```

### Advanced Usage

```bash
# Start with specific environment
cone start -e test

# Restart with environment change
cone restart -e production

# Force full server restart
cone restart --force

# Set timeout
cone exec "sleep 10" --timeout 5

# Verbose log output
cone -v exec "User.all"
```

## Architecture

Consolle consists of the following structure:

```
┌─────────────────────┐
│      CLI Tool       │
│      (cone)         │
└─────────┬───────────┘
          │ Unix Socket
          │
┌─────────▼───────────┐
│  ConsoleSocketServer│
│   (Socket Listener) │
└─────────┬───────────┘
          │
┌─────────▼───────────┐
│   RequestBroker     │
│  (Serial Queue)     │
└─────────┬───────────┘
          │
┌─────────▼───────────┐
│  ConsoleSupervisor  │
│   (PTY Manager)     │
└─────────┬───────────┘
          │ PTY
          │
┌─────────▼───────────┐
│   Rails Console     │
│   (Subprocess)      │
└─────────────────────┘
```

## Key Components

### CLI (Command Line Interface)
- `cone start`: Start Rails console server
- `cone stop`: Stop Rails console server
- `cone restart`: Restart Rails console server
- `cone status`: Check server status
- `cone exec`: Execute code
- `cone version`: Version information

### Server Components

#### ConsoleSocketServer
- Manages client connections through Unix socket
- Handles requests/responses through JSON protocol
- Supports multiple client connections

#### ConsoleSupervisor
- Manages Rails console process through PTY
- Automatic restart (Watchdog) feature
- Environment variable settings and IRB automation configuration
- Timeout handling and Ctrl-C support

#### RequestBroker
- Ensures request order through serial queue
- Prevents concurrent execution and safe multi-client handling
- Asynchronous response handling through Future pattern

## Environment Configuration

Consolle automatically sets the following environment variables when running Rails console:

```ruby
env = {
  "RAILS_ENV" => rails_env,
  "IRBRC" => "skip",              # Skip IRB configuration file
  "PAGER" => "cat",               # Immediate output
  "NO_PAGER" => "1",              # Disable pager
  "TERM" => "dumb",               # Simple terminal setting
  "FORCE_COLOR" => "0",           # Disable colors
  "NO_COLOR" => "1",              # Completely disable color output
  "COLUMNS" => "120",             # Fixed column count
  "LINES" => "24"                 # Fixed line count
}
```

## File Locations

- **Socket file**: `{Rails.root}/tmp/cone/cone.socket`
- **PID file**: `{Rails.root}/tmp/cone/cone.pid`
- **Log file**: `{Rails.root}/tmp/cone/cone.log`
- **Session file**: `{Rails.root}/tmp/cone/session.json`
- **User session logs**: `~/.cone/sessions/{project_hash}/session_YYYYMMDD_pid{pid}.log`

## Development Guide

### Running Tests

```bash
# From library directory
cd lib/consolle
bundle install
bundle exec rspec
```

### Debugging

```bash
# Verbose log output
cone -v exec "your_code"

# Check server logs
tail -f tmp/cone/cone.log

# Check session logs
ls ~/.cone/sessions/
```

## Limitations

- Only available in Rails projects
- Only works on Unix-like systems (PTY dependency)
- Only one console server can run per Rails project

## Version Information

- **Current version**: 0.1.0
- **Ruby version**: 3.0 or higher
- **Rails version**: 7.0 or higher