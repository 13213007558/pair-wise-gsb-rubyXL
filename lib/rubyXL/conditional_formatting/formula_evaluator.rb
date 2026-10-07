# frozen_string_literal: true

require 'strscan'

module RubyXL
  module ConditionalFormatRules
    # Raised when a formula falls outside of the supported subset
    # (numbers, comparisons, boolean combinations and cell references).
    #
    # An unevaluable formula is NOT the same as +FALSE+: a conditional
    # formatting rule whose condition cannot be evaluated must not be applied.
    class UnevaluableFormula < StandardError; end

    # Tokenizer + recursive-descent evaluator for the deliberately small
    # spreadsheet-formula subset understood by the conditional formatting
    # engine:
    #
    #   expr     := or_expr
    #   or_expr  := and_expr (OR(and_expr, ...))*
    #   and_expr := not_expr (AND(not_expr, ...))*
    #   not_expr := NOT(expr) | compare
    #   compare  := add (('=' | '<>' | '<' | '<=' | '>' | '>=') add)?
    #   add      := mul (('+' | '-') mul)*
    #   mul      := unary (('*' | '/') unary)*
    #   unary    := ('+' | '-') unary | percent
    #   percent  := primary '%'*
    #   primary  := number | string | TRUE | FALSE | cell_ref
    #             | AND(...) | OR(...) | NOT(...) | '(' expr ')'
    #
    # Only the AND, OR and NOT functions are supported; any other function
    # call, range/cross-sheet reference, error literal or unrecognised token
    # makes the whole formula unevaluable.
    class FormulaEvaluator
      NUMBER = /\A\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\Z/.freeze

      BOOLEAN_FUNCTIONS = { 'AND' => :and, 'OR' => :or, 'NOT' => :not }.freeze
      COMPARATOR_TOKENS = { '=' => :eq, '<>' => :ne, '<' => :lt,
                             '<=' => :le, '>' => :gt, '>=' => :ge }.freeze

      # +worksheet+ resolves references; +row_offset+ and +column_offset+ are
      # zero-based deltas from a rule's anchor (the top-left cell of the
      # sqref area currently being evaluated) to the evaluated cell.
      def initialize(worksheet, row_offset, column_offset)
        @worksheet = worksheet
        @row_offset = row_offset
        @column_offset = column_offset
      end

      # Returns a Numeric for arithmetic formulas or +true+/+false+ for
      # boolean formulas. Raises +UnevaluableFormula+ when the formula is
      # outside of the supported subset.
      def evaluate(expression)
        raise UnevaluableFormula, 'empty formula' if expression.nil? || expression.strip.empty?

        expression = expression.strip
        expression = expression[1..] if expression.start_with?('=')
        raise UnevaluableFormula, 'empty formula' if expression.strip.empty?

        @tokens = tokenize(expression)
        @pos = 0
        value = parse_or
        raise UnevaluableFormula, "trailing tokens in #{expression.inspect}" unless at_end?
        value
      end

      # Spreadsheet truthiness: 0, FALSE and blank are false; non-empty text
      # and non-zero numbers are true.
      def self.truthy?(value)
        case value
        when nil, false then false
        when Numeric    then !value.zero?
        when String     then !value.empty?
        else true
        end
      end

      private

      def tokenize(expression)
        tokens = []
        scanner = StringScanner.new(expression)

        until scanner.eos?
          scanner.skip(/\s+/)
          break if scanner.eos?

          if (text = scanner.scan(/"(?:[^"]|"")*"?/))
            raise UnevaluableFormula, "unterminated string in #{expression.inspect}" unless text.end_with?('"')
            tokens << [:string, text[1..-2].gsub('""', '"')]
          elsif (num = scanner.scan(/\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?/))
            tokens << [:number, num =~ /[.eE]/ ? Float(num) : Integer(num, 10)]
          elsif (op = scanner.scan(/<>|<=|>=|=|<|>/))
            tokens << [COMPARATOR_TOKENS.fetch(op) { raise UnevaluableFormula, "bad comparator #{op}" }]
          elsif (op = scanner.scan(/[+\-*\/%()]/))
            tokens << [op.to_sym]
          elsif (sep = scanner.scan(/[,;]/))
            tokens << [:comma]
          elsif (ref = scanner.scan(/\$?[A-Za-z]{1,3}\$?\d+/))
            tokens << reference_token(ref, scanner, expression)
          elsif (name = scanner.scan(/[A-Za-z_][A-Za-z0-9_.]*/))
            tokens << name_token(name, scanner, expression)
          else
            raise UnevaluableFormula, "unrecognised token near #{scanner.rest.inspect} in #{expression.inspect}"
          end
        end

        tokens
      end

      def reference_token(ref, scanner, expression)
        col_part = ref[/[A-Za-z]+/]
        row_part = ref[/\d+/]
        raise UnevaluableFormula, "bad cell reference #{ref.inspect}" if col_part.nil? || row_part.nil?

        upcoming = scanner.rest.lstrip
        if upcoming.start_with?(':')
          raise UnevaluableFormula, "range references are not supported in #{expression.inspect}"
        elsif upcoming.start_with?('!')
          raise UnevaluableFormula, "cross-sheet references are not supported in #{expression.inspect}"
        end

        col = col_part.each_byte.inject(0) do |acc, byte|
          upper = byte >= 'a'.ord ? byte - 32 : byte
          acc * 26 + (upper - 64)
        end - 1
        row = row_part.to_i - 1
        col_absolute = ref.start_with?('$')
        row_absolute = !!(ref =~ /[A-Za-z]\$\d+\Z/)
        [:ref, ref, row, col, col_absolute, row_absolute]
      end

      def name_token(name, scanner, expression)
        upcased = name.upcase
        if upcased == 'TRUE' || upcased == 'FALSE'
          [:bool, upcased == 'TRUE']
        elsif BOOLEAN_FUNCTIONS.key?(upcased)
          scanner.skip(/\s*/)
          raise UnevaluableFormula, "expected ( after #{name} in #{expression.inspect}" unless scanner.peek(1) == '('
          [:func, BOOLEAN_FUNCTIONS[upcased]]
        else
          raise UnevaluableFormula, "unsupported name or function #{name.inspect} in #{expression.inspect}"
        end
      end

      def current
        @tokens[@pos]
      end

      def advance
        token = @tokens[@pos]
        @pos += 1
        token
      end

      def at_end?
        @pos >= @tokens.size
      end

      def parse_or
        value = parse_and
        while current == [:func, :or]
          advance
          args = parse_call_arguments
          value = ([value] + args).any? { |arg| self.class.truthy?(arg) }
        end
        value
      end

      def parse_and
        value = parse_not
        while current == [:func, :and]
          advance
          args = parse_call_arguments
          value = ([value] + args).all? { |arg| self.class.truthy?(arg) }
        end
        value
      end

      def parse_not
        if current == [:func, :not]
          advance
          args = parse_call_arguments
          raise UnevaluableFormula, 'NOT() takes exactly one argument' unless args.size == 1
          !self.class.truthy?(args.first)
        else
          parse_comparison
        end
      end

      def parse_call_arguments
        raise UnevaluableFormula, 'expected opening parenthesis' unless advance == [:'(']
        return [] if current == [:')'] && advance

        # Each argument is a full expression, but parsing restarts at the
        # comparison/addition level so that the trailing ')' of the outer
        # comparison does not get swallowed as part of an operand.
        args = [parse_or]
        while current == [:comma]
          advance
          args << parse_or
        end
        raise UnevaluableFormula, 'expected closing parenthesis' unless advance == [:')']
        args
      end

      def parse_comparison
        left = parse_addition
        if current && current.size == 1 && COMPARATOR_TOKENS.values.include?(current[0])
          operator = advance[0]
          right = parse_addition
          compare(left, operator, right)
        else
          left
        end
      end

      def parse_addition
        value = parse_multiplication
        while current == [:+] || current == [:-]
          operator = advance.first
          value = arithmetic(value, operator, parse_multiplication)
        end
        value
      end

      def parse_multiplication
        value = parse_unary
        while current == [:*] || current == [:/]
          operator = advance.first
          value = arithmetic(value, operator, parse_unary)
        end
        value
      end

      def parse_unary
        if current == [:-] || current == [:+]
          operator = advance.first
          value = parse_unary
          return -as_number(value) if operator == :-
          return as_number(value)
        end
        parse_percent
      end

      def parse_percent
        value = parse_primary
        while current == [:%]
          advance
          value = as_number(value) / 100.0
        end
        value
      end

      def parse_primary
        token = advance
        raise UnevaluableFormula, 'unexpected end of formula' if token.nil?

        case token.first
        when :number then token.last
        when :string then token.last
        when :bool   then token.last
        when :ref    then resolve_reference(token)
        when :func
          # AND/OR reached as the first token of an expression.
          args = parse_call_arguments
          combine_boolean_function(token.last, args)
        when :'(' then
          value = parse_or
          raise UnevaluableFormula, 'expected closing parenthesis' unless advance == [:')']
          value
        else raise UnevaluableFormula, "unexpected token #{token.inspect}"
        end
      end

      def combine_boolean_function(kind, args)
        raise UnevaluableFormula, 'AND() requires arguments' if kind == :and && args.empty?
        raise UnevaluableFormula, 'OR() requires arguments' if kind == :or && args.empty?
        case kind
        when :and then args.all? { |arg| self.class.truthy?(arg) }
        when :or  then args.any? { |arg| self.class.truthy?(arg) }
        when :not
          raise UnevaluableFormula, 'NOT() takes exactly one argument' unless args.size == 1
          !self.class.truthy?(args.first)
        end
      end

      def resolve_reference(token)
        _tag, _raw, row, col, col_absolute, row_absolute = token
        col += @column_offset unless col_absolute
        row += @row_offset unless row_absolute
        return nil if row.negative? || col.negative?

        cell = @worksheet.cell_at(RubyXL::Reference.new(row, col).to_s) rescue nil
        return nil if cell.nil? || cell.formula
        cell.value
      end

      def arithmetic(left, operator, right)
        l = as_number(left)
        r = as_number(right)
        case operator
        when :+ then l + r
        when :- then l - r
        when :* then l * r
        when :/
          raise UnevaluableFormula, 'division by zero' if r.zero?
          l.to_f / r
        end
      end

      def as_number(value)
        case value
        when Numeric then value
        when true    then 1
        when false   then 0
        when nil     then 0
        when String
          raise UnevaluableFormula, "cannot use text #{value.inspect} as a number" unless value =~ NUMBER
          value =~ /[.eE]/ ? Float(value) : Integer(value, 10)
        else raise UnevaluableFormula, "cannot convert #{value.inspect} to a number"
        end
      end

      def compare(left, operator, right)
        left = 0 if left.nil?
        right = 0 if right.nil?

        comparable = if (left.is_a?(String) || right.is_a?(String))
                        unless left.is_a?(String) && right.is_a?(String)
                          raise UnevaluableFormula, "cannot compare #{left.inspect} with #{right.inspect}"
                        end
                        [left, right]
                      elsif left.is_a?(Numeric) && right.is_a?(Numeric)
                        [left, right]
                      elsif boolean_like?(left) && boolean_like?(right)
                        [left == true, right == true]
                      else
                        raise UnevaluableFormula, "cannot compare #{left.inspect} with #{right.inspect}"
                      end

        result = comparable[0] <=> comparable[1]
        raise UnevaluableFormula, "cannot compare #{left.inspect} with #{right.inspect}" if result.nil?

        case operator
        when :eq then result.zero?
        when :ne then !result.zero?
        when :lt then result.negative?
        when :le then result <= 0
        when :gt then result.positive?
        when :ge then result >= 0
        end
      end

      def boolean_like?(value)
        value == true || value == false
      end
    end
  end
end
