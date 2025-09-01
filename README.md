# Consolle

Consolle is a library that manages Rails console through PTY (Pseudo-Terminal). Moving away from the traditional eval-based execution method, it manages the actual Rails console process as a subprocess to provide a more stable and secure execution environment.

## Key Features

- **PTY-based Rails Console Management**: Manages the actual Rails console process through PTY
- **Socket Server Architecture**: Stable client-server communication through Unix socket
- **Automatic Restart (Watchdog)**: Automatic recovery on process failure
- **Environment-specific Execution**: Supports Rails environments (development, test, production)
- **Timeout Handling**: Automatic termination of long-running code with robust prompt recovery
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
# Start with specific environment (use RAILS_ENV)
RAILS_ENV=test cone start

# Restart with environment change (use RAILS_ENV)
RAILS_ENV=production cone restart

# Force full server restart
cone restart --force

# Set timeout (default: 60s; precedence: CONSOLLE_TIMEOUT > --timeout > defaults)
CONSOLLE_TIMEOUT=90 cone exec "long_running_task"   # env wins
cone exec "long_running_task" --timeout 120         # falls back when env not set

# Pre-exec Ctrl-C (prompt separation)
By default (development/production), cone sends Ctrl-C before each `exec` and waits for the IRB prompt (up to 3 seconds) to ensure a clean state and avoid hanging on partial input. If the prompt does not return within 3 seconds, the console subprocess is force-restarted and the request fails with `SERVER_UNHEALTHY`, so the caller can retry.

Timeout precedence
- `CONSOLLE_TIMEOUT` (if set and > 0) overrides all other sources on both client and server.
- Otherwise, CLI `--timeout` is used.
- Otherwise, default of 60s applies.

- Per‑call control (CLI):
  - Enable: `cone exec --pre-sigint 'code'`
  - Disable: `cone exec --no-pre-sigint 'code'`
- Global (server‑wide) control via environment when starting the server:
  - Disable: `CONSOLLE_DISABLE_PRE_SIGINT=1 cone start`
  - Note: this env var is read by the server process at start time, not by `cone exec`.

# Timeout and interrupt behavior during execution
- On execution timeout, cone sends Ctrl‑C to interrupt and attempts prompt recovery. For local consoles, it also sends an OS‑level `SIGINT` as a fallback.
- After recovery, subsequent `cone exec` requests continue normally.

# Error codes
- `EXECUTION_TIMEOUT`: The executed code exceeded its timeout.
- `SERVER_UNHEALTHY`: Pre‑exec prompt did not return within 3 seconds; the console subprocess was restarted and the request failed.

# Examples
- Force an execution timeout quickly and verify recovery:
  - `cone exec 'sleep 999' --timeout 2` → fails with `EXECUTION_TIMEOUT`
  - `cone exec 'puts :after_timeout; :ok'` → should succeed (`:ok`)

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
- Timeout handling and Ctrl-C support (pre-exec safety check + post-timeout recovery)

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

Additional environment variables

- `CONSOLLE_TIMEOUT`: Highest‑priority timeout (seconds). Overrides CLI `--timeout` and defaults on both client and server.
- `CONSOLLE_DISABLE_PRE_SIGINT=1`: Disable the pre‑exec Ctrl‑C prompt check at the server level (read when starting the server).

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
