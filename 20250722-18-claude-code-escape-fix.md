# Fix: RSpec Stopping After 'exec with target option' Test

## Issue
When running the full RSpec test suite with `bundle exec rspec`, the tests would stop executing after the "exec with target option" test in `spec/integration/multi_session_spec.rb`. Only 63 out of 191 tests would run, with no visible errors or failures.

## Root Cause
The test was calling the real `exec` method without mocking all necessary dependencies. The exec method has logic to auto-start the server if it's not running. During this process, if something goes wrong, it calls `exit(1)` which terminates the entire RSpec process.

Specifically:
1. The test mocked `send_code_to_socket` but not `load_session_info`
2. The exec method loads session info and checks if the server is running
3. When it can't connect to the socket (because it's just test data), it tries to auto-start
4. During auto-start, it invokes `start` without passing the target option
5. This creates a session for "cone" instead of "dev"
6. When it reloads session info for "dev", it gets nil
7. This triggers `exit(1)` on line 347 of cli.rb

## Solution
Added proper mocks to the test:
1. Mock `load_session_info` to return the session data
2. Mock the UNIXSocket connection check to indicate the server is running

This prevents the exec method from attempting to auto-start and hitting the exit call.

## Lessons Learned
- Always mock all dependencies when testing methods that have side effects
- Be careful with `exit` calls in library code - they can terminate the test runner
- Integration tests need careful setup to avoid triggering real system behavior
- When RSpec stops without error, check for `exit` calls in the code being tested