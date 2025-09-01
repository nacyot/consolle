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

You can start cone with the `start` command and specify the execution environment with `-e`.

```bash
$ cone start # Start server
$ RAILS_ENV=test cone start # Start console in test environment
```

It also provides stop and restart commands.

Cone provides only one session at a time, and to change the execution environment, you must stop and restart.

```bash
$ cone stop # Stop server
```

Always terminate when you finish your work.

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

A `-v` option (Verbose output) is provided for debugging.

```bash
$ cone exec -v 'puts "hello, world"'
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
