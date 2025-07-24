# frozen_string_literal: true

require 'spec_helper'
require 'consolle/server/console_supervisor'
require 'base64'

RSpec.describe Consolle::Server::ConsoleSupervisor do
  let(:logger) { Logger.new(nil) }
  let(:supervisor) { described_class.allocate } # Create instance without initializing

  before do
    # Setup minimal instance variables needed for parse_output
    supervisor.instance_variable_set(:@logger, logger)
  end

  describe '#parse_output' do
    def parse_output(output, code)
      # Call the private method for testing
      supervisor.send(:parse_output, output, code)
    end

    def mock_console_output(code, result)
      # Mock typical IRB output format with Base64 eval command
      encoded_code = Base64.strict_encode64(code)
      eval_cmd = "eval(Base64.decode64('#{encoded_code}'), IRB.CurrentContext.workspace.binding)"
      "#{eval_cmd}\n=> #{result}\n\u001E\u001F<CONSOLLE>\u001F\u001E "
    end

    context 'basic Ruby types' do
      it 'parses string output correctly' do
        output = mock_console_output('code', '"hello world"')
        result = parse_output(output, 'eval(...)')
        expect(result).to eq('=> "hello world"')
      end

      it 'parses integer output correctly' do
        output = mock_console_output('code', '42')
        result = parse_output(output, 'eval(...)')
        expect(result).to eq('=> 42')
      end

      it 'parses float output correctly' do
        output = mock_console_output('code', '3.14159')
        result = parse_output(output, 'eval(...)')
        expect(result).to eq('=> 3.14159')
      end

      it 'parses symbol output correctly' do
        output = mock_console_output('code', ':symbol')
        result = parse_output(output, 'eval(...)')
        expect(result).to eq('=> :symbol')
      end

      it 'parses true boolean correctly' do
        output = mock_console_output('code', 'true')
        result = parse_output(output, 'eval(...)')
        expect(result).to eq('=> true')
      end

      it 'parses false boolean correctly' do
        output = mock_console_output('code', 'false')
        result = parse_output(output, 'eval(...)')
        expect(result).to eq('=> false')
      end

      it 'parses nil correctly' do
        output = mock_console_output('code', 'nil')
        result = parse_output(output, 'eval(...)')
        expect(result).to eq('=> nil')
      end
    end

    context 'collection types' do
      it 'parses array output correctly' do
        output = mock_console_output('code', '[1, 2, 3, "four"]')
        result = parse_output(output, 'eval(...)')
        expect(result).to eq('=> [1, 2, 3, "four"]')
      end

      it 'parses hash output correctly' do
        output = mock_console_output('code', '{a: 1, b: "two", c: :three}')
        result = parse_output(output, 'eval(...)')
        expect(result).to eq('=> {a: 1, b: "two", c: :three}')
      end

      it 'parses nested collections correctly' do
        output = mock_console_output('code', '[{a: 1}, {b: [2, 3]}]')
        result = parse_output(output, 'eval(...)')
        expect(result).to eq('=> [{a: 1}, {b: [2, 3]}]')
      end
    end

    context 'object inspection' do
      it 'parses custom object output correctly' do
        output = mock_console_output('code', '#<TestClass:0x00007f8b8c0a1b20 @name="test">')
        result = parse_output(output, 'eval(...)')
        expect(result).to eq('=> #<TestClass:0x00007f8b8c0a1b20 @name="test">')
      end

      it 'parses Time object output correctly' do
        output = mock_console_output('code', '2025-07-17 12:00:00 +0900')
        result = parse_output(output, 'eval(...)')
        expect(result).to eq('=> 2025-07-17 12:00:00 +0900')
      end

      it 'parses Date object output correctly' do
        output = mock_console_output('code', '#<Date: 2025-07-17 ((2460877j,0s,0n),+0s,2299161j)>')
        result = parse_output(output, 'eval(...)')
        expect(result).to eq('=> #<Date: 2025-07-17 ((2460877j,0s,0n),+0s,2299161j)>')
      end
    end

    context 'multiline output' do
      it 'parses multiline string output correctly' do
        multiline_result = '"line1\\nline2\\nline3"'
        output = mock_console_output('code', multiline_result)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{multiline_result}")
      end

      it 'parses object with multiline inspect correctly' do
        multiline_object = "#<ComplexObject:0x00007f8b8c0a1b20\n  @attr1=\"value1\",\n  @attr2=\"value2\">"
        output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n=> #{multiline_object}\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(output, 'eval(...)')
        # Now properly handles multiline objects
        expect(result).to eq("=> #{multiline_object}")
      end
    end

    context 'output with side effects' do
      it 'handles puts with return value correctly' do
        # When code includes puts, the output includes both the puts output and the return value
        output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\nHello from puts\n=> nil\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(output, 'eval(...)')
        # Now includes both side effect and return value
        expect(result).to eq("Hello from puts\n=> nil")
      end

      it 'handles print with return value correctly' do
        output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\nHello from print=> nil\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(output, 'eval(...)')
        # print doesn't add newline, so => appears right after the output
        expect(result).to eq('Hello from print=> nil')
      end

      it 'handles p with return value correctly' do
        # p returns the value it prints
        output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n\"inspected value\"\n=> \"inspected value\"\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(output, 'eval(...)')
        # Now includes both printed value and return value
        expect(result).to eq("\"inspected value\"\n=> \"inspected value\"")
      end
    end

    context 'error handling' do
      it 'parses NameError correctly' do
        error_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n(rails8-sample):8:in 'Kernel#eval': uninitialized constant TestClass (NameError)\nDid you mean?  TrueClass\n\tfrom (rails8-sample):8:in '<main>'\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(error_output, 'eval(...)')
        expect(result).to include('uninitialized constant TestClass')
        expect(result).to include('NameError')
      end

      it 'parses SyntaxError correctly' do
        error_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n(rails8-sample):1: syntax errors found (SyntaxError)\n> 1 | def foo\n    |        ^ unexpected end-of-input\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(error_output, 'eval(...)')
        expect(result).to include('syntax errors found')
        expect(result).to include('SyntaxError')
      end

      it 'parses NoMethodError correctly' do
        error_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n(rails8-sample):8:in '<main>': undefined method `foo' for nil:NilClass (NoMethodError)\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(error_output, 'eval(...)')
        expect(result).to include('undefined method')
        expect(result).to include('NoMethodError')
      end
    end

    context 'edge cases' do
      it 'handles empty output correctly' do
        output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(output, 'eval(...)')
        expect(result).to eq('')
      end

      it 'handles output with ANSI escape codes' do
        # Simulate colored output
        ansi_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n\e[32m=> \"green text\"\e[0m\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(ansi_output, 'eval(...)')
        expect(result).to eq('=> "green text"')
      end

      it 'handles very large object inspection' do
        large_array = '[' + (1..100).map(&:to_s).join(', ') + ']'
        output = mock_console_output('code', large_array)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{large_array}")
      end

      it 'handles output with special characters' do
        special_output = '"string with \n newline and \t tab"'
        output = mock_console_output('code', special_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{special_output}")
      end

      it 'handles output that looks like a prompt' do
        # Output that contains text that might match prompt pattern
        tricky_output = '"irb(main):001> this is not a prompt"'
        output = mock_console_output('code', tricky_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{tricky_output}")
      end
    end

    context 'Rails-specific objects' do
      it 'parses ActiveRecord model inspection' do
        ar_output = '#<User id: 1, email: "test@example.com", created_at: "2025-07-17 12:00:00", updated_at: "2025-07-17 12:00:00">'
        output = mock_console_output('code', ar_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{ar_output}")
      end

      it 'parses ActiveRecord relation output' do
        relation_output = '#<User::ActiveRecord_Relation:0x00007f8b8c0a1b20>'
        output = mock_console_output('code', relation_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{relation_output}")
      end

      it 'parses Rails configuration object' do
        config_output = '#<Rails::Application::Configuration:0x00007f8b8c0a1b20 ...>'
        output = mock_console_output('code', config_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{config_output}")
      end
    end

    context 'Ruby built-in types' do
      it 'parses Regexp output correctly' do
        regexp_output = '/pattern/i'
        output = mock_console_output('code', regexp_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{regexp_output}")
      end

      it 'parses Range output correctly' do
        range_output = '1..10'
        output = mock_console_output('code', range_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{range_output}")
      end

      it 'parses exclusive Range output correctly' do
        range_output = '1...10'
        output = mock_console_output('code', range_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{range_output}")
      end

      it 'parses Proc output correctly' do
        proc_output = '#<Proc:0x00007f8b8c0a1b20@(eval):1>'
        output = mock_console_output('code', proc_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{proc_output}")
      end

      it 'parses lambda output correctly' do
        lambda_output = '#<Proc:0x00007f8b8c0a1b20@(eval):1 (lambda)>'
        output = mock_console_output('code', lambda_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{lambda_output}")
      end

      it 'parses Method object output correctly' do
        method_output = '#<Method: String#upcase>'
        output = mock_console_output('code', method_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{method_output}")
      end

      it 'parses File output correctly' do
        file_output = '#<File:/tmp/test.txt>'
        output = mock_console_output('code', file_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{file_output}")
      end

      it 'parses IO output correctly' do
        io_output = '#<IO:fd 1>'
        output = mock_console_output('code', io_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{io_output}")
      end

      it 'parses Thread output correctly' do
        thread_output = '#<Thread:0x00007f8b8c0a1b20@(eval):1 run>'
        output = mock_console_output('code', thread_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{thread_output}")
      end

      it 'parses Struct output correctly' do
        struct_output = '#<struct Point x=1, y=2>'
        output = mock_console_output('code', struct_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{struct_output}")
      end

      it 'parses OpenStruct output correctly' do
        ostruct_output = '#<OpenStruct x=1, y=2>'
        output = mock_console_output('code', ostruct_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{ostruct_output}")
      end

      it 'parses Set output correctly' do
        set_output = '#<Set: {1, 2, 3}>'
        output = mock_console_output('code', set_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{set_output}")
      end

      it 'parses Complex number output correctly' do
        complex_output = '(1+2i)'
        output = mock_console_output('code', complex_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{complex_output}")
      end

      it 'parses Rational number output correctly' do
        rational_output = '(1/2)'
        output = mock_console_output('code', rational_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{rational_output}")
      end

      it 'parses BigDecimal output correctly' do
        decimal_output = '#<BigDecimal:0x00007f8b8c0a1b20,\'0.314159E1\',18(27)>'
        output = mock_console_output('code', decimal_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{decimal_output}")
      end
    end

    context 'method chaining and complex expressions' do
      it 'parses method chaining result correctly' do
        chain_output = '"HELLO WORLD"'
        output = mock_console_output('code', chain_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{chain_output}")
      end

      it 'parses array method chaining result correctly' do
        chain_output = '[2, 4, 6]'
        output = mock_console_output('code', chain_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{chain_output}")
      end

      it 'parses hash method chaining result correctly' do
        chain_output = '{a: 1, b: 2}'
        output = mock_console_output('code', chain_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{chain_output}")
      end

      it 'parses enumerator output correctly' do
        enum_output = '#<Enumerator: [1, 2, 3]:each>'
        output = mock_console_output('code', enum_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{enum_output}")
      end

      it 'parses lazy enumerator output correctly' do
        lazy_output = '#<Enumerator::Lazy: #<Enumerator: [1, 2, 3]:each>:map>'
        output = mock_console_output('code', lazy_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{lazy_output}")
      end
    end

    context 'exception and error cases' do
      it 'parses RuntimeError correctly' do
        error_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n(rails8-sample):1:in '<main>': Something went wrong (RuntimeError)\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(error_output, 'eval(...)')
        expect(result).to include('Something went wrong')
        expect(result).to include('RuntimeError')
      end

      it 'parses ArgumentError correctly' do
        error_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n(rails8-sample):1:in '<main>': wrong number of arguments (given 1, expected 0) (ArgumentError)\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(error_output, 'eval(...)')
        expect(result).to include('wrong number of arguments')
        expect(result).to include('ArgumentError')
      end

      it 'parses TypeError correctly' do
        error_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n(rails8-sample):1:in '<main>': no implicit conversion of String into Integer (TypeError)\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(error_output, 'eval(...)')
        expect(result).to include('no implicit conversion')
        expect(result).to include('TypeError')
      end

      it 'parses LoadError correctly' do
        error_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n(rails8-sample):1:in 'require': cannot load such file -- nonexistent (LoadError)\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(error_output, 'eval(...)')
        expect(result).to include('cannot load such file')
        expect(result).to include('LoadError')
      end

      it 'parses StandardError with backtrace correctly' do
        error_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n(rails8-sample):3:in 'bar': error in bar (StandardError)\n\tfrom (rails8-sample):6:in 'foo'\n\tfrom (rails8-sample):9:in '<main>'\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(error_output, 'eval(...)')
        expect(result).to include('error in bar')
        expect(result).to include('StandardError')
        expect(result).to include("from (rails8-sample):6:in 'foo'")
      end

      it 'parses SystemExit correctly' do
        error_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n(rails8-sample):1:in 'exit': exit (SystemExit)\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(error_output, 'eval(...)')
        expect(result).to include('exit')
        expect(result).to include('SystemExit')
      end
    end

    context 'special strings and encodings' do
      it 'handles Unicode strings correctly' do
        unicode_output = '"Hello 🌍 World 안녕하세요"'
        output = mock_console_output('code', unicode_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{unicode_output}")
      end

      it 'handles strings with escape sequences correctly' do
        escaped_output = '"Hello\\nWorld\\t\\\"Quote\\\"\\\\Backslash"'
        output = mock_console_output('code', escaped_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{escaped_output}")
      end

      it 'handles binary strings correctly' do
        binary_output = '"\\x00\\x01\\x02\\xFF"'
        output = mock_console_output('code', binary_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{binary_output}")
      end

      it 'handles strings with different encodings' do
        encoding_output = '"UTF-8 string".force_encoding("ASCII-8BIT")'
        output = mock_console_output('code', encoding_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{encoding_output}")
      end

      it 'handles very long strings correctly' do
        long_string = '"' + 'x' * 1000 + '"'
        output = mock_console_output('code', long_string)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{long_string}")
      end

      it 'handles strings with regex-like content' do
        regex_like_output = '"This looks like /a regex/ but is string"'
        output = mock_console_output('code', regex_like_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{regex_like_output}")
      end
    end

    context 'class and module definitions' do
      it 'parses class definition output correctly' do
        class_output = 'TestClass'
        output = mock_console_output('code', class_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{class_output}")
      end

      it 'parses module definition output correctly' do
        module_output = 'TestModule'
        output = mock_console_output('code', module_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{module_output}")
      end

      it 'parses constant definition output correctly' do
        constant_output = '42'
        output = mock_console_output('code', constant_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{constant_output}")
      end

      it 'parses method definition output correctly' do
        method_output = ':test_method'
        output = mock_console_output('code', method_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{method_output}")
      end

      it 'parses Class object output correctly' do
        class_obj_output = 'String'
        output = mock_console_output('code', class_obj_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{class_obj_output}")
      end

      it 'parses Module object output correctly' do
        module_obj_output = 'Enumerable'
        output = mock_console_output('code', module_obj_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{module_obj_output}")
      end
    end

    context 'large and complex data structures' do
      it 'parses large arrays correctly' do
        large_array = '[' + (1..50).map(&:to_s).join(', ') + ']'
        output = mock_console_output('code', large_array)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{large_array}")
      end

      it 'parses large hashes correctly' do
        large_hash = '{' + (1..20).map { |i| "key#{i}: \"value#{i}\"" }.join(', ') + '}'
        output = mock_console_output('code', large_hash)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{large_hash}")
      end

      it 'parses deeply nested arrays correctly' do
        nested_array = '[[[[[1]]]]]'
        output = mock_console_output('code', nested_array)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{nested_array}")
      end

      it 'parses deeply nested hashes correctly' do
        nested_hash = '{a: {b: {c: {d: {e: "deep"}}}}}'
        output = mock_console_output('code', nested_hash)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{nested_hash}")
      end

      it 'parses mixed nested structures correctly' do
        mixed_output = '[{a: [1, {b: 2}]}, {c: [{d: 3}]}]'
        output = mock_console_output('code', mixed_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{mixed_output}")
      end

      it 'parses circular reference indication correctly' do
        circular_output = '[1, 2, [...]]'
        output = mock_console_output('code', circular_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{circular_output}")
      end
    end

    context 'Rails-specific complex outputs' do
      it 'parses SQL query logs correctly' do
        sql_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n  User Load (0.5ms)  SELECT `users`.* FROM `users` WHERE `users`.`id` = 1 LIMIT 1\n=> #<User id: 1, name: \"John\">\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(sql_output, 'eval(...)')
        expect(result).to include('User Load')
        expect(result).to include('SELECT')
        expect(result).to include('#<User id: 1')
        expect(result).to include('=> #<User id: 1, name: "John">')
      end

      it 'parses ActiveRecord query with multiple logs correctly' do
        multi_sql_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n  User Load (0.3ms)  SELECT `users`.* FROM `users` WHERE `users`.`active` = 1\n  Post Load (0.2ms)  SELECT `posts`.* FROM `posts` WHERE `posts`.`user_id` IN (1, 2)\n=> #<ActiveRecord::AssociationRelation [#<Post id: 1>, #<Post id: 2>]>\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(multi_sql_output, 'eval(...)')
        expect(result).to include('User Load')
        expect(result).to include('Post Load')
        expect(result).to include('AssociationRelation')
        expect(result).to include('=> #<ActiveRecord::AssociationRelation')
      end

      it 'parses transaction logs correctly' do
        transaction_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n  TRANSACTION (0.1ms)  BEGIN\n  User Create (0.3ms)  INSERT INTO `users` (`name`) VALUES ('Test')\n  TRANSACTION (0.2ms)  COMMIT\n=> #<User id: 123, name: \"Test\">\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(transaction_output, 'eval(...)')
        expect(result).to include('TRANSACTION')
        expect(result).to include('BEGIN')
        expect(result).to include('INSERT')
        expect(result).to include('COMMIT')
        expect(result).to include('=> #<User id: 123, name: "Test">')
      end

      it 'parses Rails migration output correctly' do
        migration_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n== 20250717000000 CreateUsers: migrating ======================================\n-- create_table(:users)\n   -> 0.0023s\n== 20250717000000 CreateUsers: migrated (0.0024s) =============================\n=> nil\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(migration_output, 'eval(...)')
        expect(result).to include('CreateUsers: migrating')
        expect(result).to include('create_table')
        expect(result).to include('migrated')
        expect(result).to include('=> nil')
      end

      it 'parses Rails cache logs correctly' do
        cache_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n  Cache read: views/users/1-20250717120000000000 (0.1ms)\n  Cache miss: views/users/1-20250717120000000000\n=> \"cached content\"\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(cache_output, 'eval(...)')
        expect(result).to include('Cache read')
        expect(result).to include('Cache miss')
        expect(result).to include('"cached content"')
        expect(result).to include('=> "cached content"')
      end

      it 'parses Rails routing output correctly' do
        routes_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n                    Prefix Verb   URI Pattern                    Controller#Action\n                     users GET    /users(.:format)               users#index\n                           POST   /users(.:format)               users#create\n=> nil\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(routes_output, 'eval(...)')
        expect(result).to include('Prefix Verb')
        expect(result).to include('users GET')
        expect(result).to include('Controller#Action')
        expect(result).to include('=> nil')
      end

      it 'parses ActionMailer delivery logs correctly' do
        mailer_output = "eval(File.read('/tmp/consolle_eval.rb'), IRB.CurrentContext.workspace.binding)\n  Rendered user_mailer/welcome.html.erb (Duration: 2.3ms | Allocations: 1234)\n  UserMailer#welcome: processed outbound mail in 15.2ms\n  Delivered mail 60d1c2f0-abc123 (envelope-from \"no-reply@example.com\")\n=> #<Mail::Message:0x00007f8b8c0a1b20>\n\u001E\u001F<CONSOLLE>\u001F\u001E "
        result = parse_output(mailer_output, 'eval(...)')
        expect(result).to include('Rendered user_mailer')
        expect(result).to include('processed outbound mail')
        expect(result).to include('Delivered mail')
        expect(result).to include('=> #<Mail::Message:0x00007f8b8c0a1b20>')
      end

      it 'parses JSON API response correctly' do
        json_output = '{\"data\":[{\"id\":1,\"type\":\"users\",\"attributes\":{\"name\":\"John\",\"email\":\"john@example.com\"}}],\"meta\":{\"total\":1}}'
        output = mock_console_output('code', json_output)
        result = parse_output(output, 'eval(...)')
        expect(result).to eq("=> #{json_output}")
      end
    end
  end
end
