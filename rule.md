# Cone Command Guide

consolle provides the `cone` command, a wrapper that serves Rails Console as a server.

Using the `cone` command, you can start a Rails console session and execute code in Rails.

Similar to Rails console, results executed within the session are maintained and only disappear when explicitly terminated.

Before use, check the status with `status`, and after finishing work, you should `stop` it.

## Purpose of Cone

Cone is used for debugging, data exploration, and as a development assistant tool.

When using it as a development assistant tool, you must always be aware of whether modified code has been reflected.

When code is modified, you need to restart the server or use `reload!` to reflect the latest code.

Existing objects also reference old code, so you need to create new ones to use the latest code.

## Starting and Stopping Cone Server

You can start cone with the `start` command. To select the Rails environment, set the `RAILS_ENV` environment variable.

```bash
$ cone start # Start server (uses RAILS_ENV or defaults to development)
$ RAILS_ENV=test cone start # Start console in test environment
```

It also provides stop and restart commands.

Cone provides only one session at a time, and to change the execution environment, you must stop and restart.

```bash
$ cone stop # Stop server
```

Always terminate when you finish your work.

## Execution Modes

Cone supports three execution modes. You can specify the mode with the `--mode` option.

| Mode | Description | Ruby Requirement | Execution Speed |
|------|-------------|-----------------|-----------------|
| `pty` | PTY-based, supports custom commands (default) | All versions | ~0.6s |
| `embed-rails` | Rails console embedding | Ruby 3.3+ | ~0.001s |
| `embed-irb` | Pure IRB embedding (no Rails) | Ruby 3.3+ | ~0.001s |

```bash
$ cone start                      # PTY mode (default)
$ cone start --mode embed-rails   # Rails console embedding (200x faster)
$ cone start --mode embed-irb     # Pure IRB embedding (without Rails)
```

### Mode Selection Guide

- **`pty`**: For remote environments (SSH, Docker, Kamal) or when custom commands are needed
- **`embed-rails`**: For local Rails development when fast execution is required
- **`embed-irb`**: When running pure Ruby code without Rails

### Custom Commands (PTY Mode Only)

In PTY mode, you can specify a custom console command with the `--command` option.

```bash
$ cone start --command "docker exec -it app bin/rails console"
$ cone start --command "kamal console" --wait-timeout 60
```

### Configuration File

You can set the default mode in a `.consolle.yml` file at the project root. CLI options take precedence over the configuration file.

```yaml
mode: embed-rails
# command: "bin/rails console"  # PTY mode only
```

## Checking Cone Server Status

```bash
$ cone status
✓ Rails console is running
  PID: 36384
  Environment: test
  Session: /Users/ben/syncthing/workspace/karrot-inhouse/ehr/tmp/cone/cone.socket
  Ready for input: Yes
```

## Executing Code

The evaluated and output results of code are returned. The evaluation result is output with the `=> ` prefix.

```bash
$ cone exec 'User.count'
=> 1
```

Example using variables (session is maintained):

```bash
$ cone exec 'u = User.last'
=> #<User id: 1, email: "user@example.com", created_at: "2025-07-17 15:16:34.685972000 +0900", updated_at: "2025-07-17 15:16:34.685972000 +0900">

$ cone exec 'puts u'
#<User:0x00000001104bbd18>
=> nil
```

You can also execute Ruby files directly using the `-f` option. Unlike Rails Runner, this is executed in an IRB session.

```bash
$ cone exec -f example.rb
```

A `-v` option (Verbose output) is provided for debugging. It shows execution time and additional details.

```bash
$ cone exec -v 'puts "hello, world"'
hello, world
=> nil
Execution time: 0.001s
```

## Best Practices for Code Input

### Using Single Quotes (Strongly Recommended)

**Always use single quotes** when passing code to `cone exec`. This is the recommended practice for all cone users:

```bash
$ cone exec 'User.where(active: true).count'
$ cone exec 'puts "Hello, world!"'
```

### Using the --raw Option

**Note for Claude Code users: DO NOT use the --raw option.** This option is not needed in Claude Code environments.

### Multi-line Code Support

Cone fully supports multi-line code execution. There are several ways to execute multi-line code:

#### Method 1: Multi-line String with Single Quotes
```bash
$ cone exec '
users = User.active
puts "Active users: #{users.count}"
users.first
'
```

#### Method 2: Using a File
For complex multi-line code, save it in a file:
```bash
$ cone exec -f complex_task.rb
```

All methods maintain the session state, so variables and objects persist between executions.

## Execution Safety & Timeouts

- Default timeout: 60s
- Timeout precedence: `CONSOLLE_TIMEOUT` (if set and > 0) > CLI `--timeout` > default (60s)
- Pre-exec Ctrl-C (prompt separation):
  - Before each `exec`, cone sends Ctrl-C and waits up to 3 seconds for the IRB prompt to ensure a clean state.
  - If the prompt does not return in 3 seconds, the console subprocess is restarted and the request fails with `SERVER_UNHEALTHY`.
  - Disable globally for the server: `CONSOLLE_DISABLE_PRE_SIGINT=1 cone start`
  - Per-call control: `--pre-sigint` / `--no-pre-sigint`

### Examples

```bash
# Set timeout via CLI (fallback when CONSOLLE_TIMEOUT is not set)
cone exec 'heavy_task' --timeout 120

# Highest priority timeout (applies on client and server)
CONSOLLE_TIMEOUT=90 cone exec 'heavy_task'

# Verify recovery after a timeout
cone exec 'sleep 999' --timeout 2      # -> fails with EXECUTION_TIMEOUT
cone exec "puts :after_timeout; :ok"   # -> should succeed (prompt recovered)

# Disable pre-exec Ctrl-C for a single call
cone exec --no-pre-sigint 'code'
```

### Error Codes
- `EXECUTION_TIMEOUT`: The executed code exceeded its timeout.
- `SERVER_UNHEALTHY`: The pre-exec prompt did not return within 3 seconds; the console subprocess was restarted and the request failed.
