# frozen_string_literal: true

require 'nokogiri'

module RubyXL
  module DynamicArray
    SPILL_ERROR = '#SPILL!'.freeze
    CYCLE_ERROR = '#CYCLE!'.freeze
    CALC_ERROR = '#CALC!'.freeze
    VALUE_ERROR = '#VALUE!'.freeze
    DIV0_ERROR = '#DIV/0!'.freeze
    NAME_ERROR = '#NAME?'.freeze
    REF_ERROR = '#REF!'.freeze

    ERROR_VALUES = [
      SPILL_ERROR, CYCLE_ERROR, CALC_ERROR, VALUE_ERROR,
      DIV0_ERROR, NAME_ERROR, REF_ERROR
    ].freeze

    MAX_ROWS = 1_048_576
    MAX_COLUMNS = 16_384

    def self.recalculate_workbook(workbook)
      Engine.new(workbook).recalculate
    end

    class Matrix
      attr_reader :rows, :row_count, :column_count

      def initialize(rows)
        rows = rows.map { |row| Array(row) }
        if rows.empty?
          @rows = []
          @row_count = 0
          @column_count = 0
        else
          widths = rows.map(&:size).uniq
          raise ArgumentError, 'matrix rows must have equal width' unless widths.size == 1

          @rows = rows
          @row_count = rows.size
          @column_count = widths.first
        end
      end

      def self.empty
        new([])
      end

      def self.scalar(value)
        new([[value]])
      end

      def scalar?
        row_count == 1 && column_count == 1
      end

      def empty?
        row_count.zero? || column_count.zero?
      end

      def same_dimensions?(other)
        row_count == other.row_count && column_count == other.column_count
      end

      def value
        rows.dig(0, 0)
      end

      def [](row_index, column_index)
        rows.dig(row_index, column_index)
      end

      def map
        Matrix.new(rows.each_with_index.map { |row, row_index|
          row.each_with_index.map { |value, column_index| yield(value, row_index, column_index) }
        })
      end

      def to_a
        rows.map(&:dup)
      end

      def ==(other)
        other.is_a?(Matrix) && rows == other.rows
      end
    end

    class ParseError < StandardError; end

    Token = Struct.new(:type, :value, :position)

    class Lexer
      PATTERNS = [
        [:whitespace, /\A[ \t\r\n]+/],
        [:number, /\A(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?/i],
        [:sheet, /\A'(?:[^']|'')+'!/],
        [:sheet, /\A[A-Za-z_][A-Za-z0-9_.]*!/],
        [:reference, /\A\$?[A-Za-z]{1,3}\$?\d+/],
        [:identifier, /\A[A-Za-z_][A-Za-z0-9_.]*/],
        [:comparison, /\A(?:>=|<=|<>|=|>|<)/],
        [:operator, /\A[+\-*\/^&%]/]
      ].freeze

      def self.tokenize(formula)
        tokens = []
        position = 0

        while position < formula.size
          matched = false

          PATTERNS.each do |type, pattern|
            match = pattern.match(formula[position..])
            next unless match

            tokens << Token.new(type, match[0], position) unless type == :whitespace
            position += match[0].size
            matched = true
            break
          end

          next if matched

          character = formula[position]
          if character == '"'
            closing = formula.index('"', position + 1)
            raise ParseError, 'unterminated string' unless closing

            tokens << Token.new(:string, formula[position..closing], position)
            position = closing + 1
          elsif '(){},;#:'.include?(character)
            token_type = character == '#' ? :spill : :punctuation
            tokens << Token.new(token_type, character, position)
            position += 1
          else
            raise ParseError, "unexpected character #{character.inspect}"
          end
        end

        tokens
      end
    end

    class Parser
      attr_reader :references

      def self.parse(formula)
        parser = new(formula)
        ast = parser.parse_expression
        parser.expect_end
        ast
      end

      def initialize(formula)
        @tokens = Lexer.tokenize(formula.to_s.sub(/\A=/, ''))
        @position = 0
        @references = []
      end

      def expect_end
        raise ParseError, 'unexpected trailing tokens' unless @position == @tokens.size
      end

      def parse_expression
        parse_comparison
      end

      def parse_comparison
        left = parse_additive
        while take(:comparison)
          operator = previous.value
          right = parse_additive
          left = { :type => :comparison, :operator => operator, :left => left, :right => right }
        end
        left
      end

      def parse_additive
        parse_binary(:parse_multiplicative, '+', '-')
      end

      def parse_multiplicative
        parse_binary(:parse_unary, '*', '/')
      end

      def parse_binary(child_parser, *operators)
        left = public_send(child_parser)
        while take(:operator, *operators)
          operator = previous.value
          right = public_send(child_parser)
          left = { :type => :arithmetic, :operator => operator, :left => left, :right => right }
        end
        left
      end

      def parse_unary
        if take(:operator, '-', '+')
          { :type => :unary, :operator => previous.value, :value => parse_unary }
        else
          parse_primary
        end
      end

      def parse_primary
        if take(:number)
          number = previous.value
          return { :type => :number, :value => number.include?('.') ? Float(number) : Integer(number) }
        end

        if take(:string)
          return { :type => :string, :value => unescape_string(previous.value[1...-1]) }
        end

        if take(:identifier, 'TRUE', 'FALSE')
          return { :type => :boolean, :value => previous.value.upcase == 'TRUE' }
        end

        sheet_name = nil
        if take(:sheet)
          sheet_name = normalize_sheet(previous.value)
          raise ParseError, 'expected cell reference' unless take(:reference)
        elsif take(:reference)
          # Reference token is already consumed.
        elsif take(:identifier)
          name = previous.value
          if take(:punctuation, '(')
            return parse_function(name)
          end
          raise ParseError, "unknown identifier #{name}"
        elsif take(:punctuation, '(')
          expression = parse_expression
          expect(:punctuation, ')')
          return expression
        elsif take(:punctuation, '{')
          return parse_constant_matrix
        else
          raise ParseError, 'unexpected token'
        end

        reference = parse_reference(sheet_name)
        if take(:punctuation, ':')
          expect(:reference)
          ending = coordinates(previous.value)
          reference.merge!(
            :row_to => ending[:row],
            :column_to => ending[:column],
            :spill => false
          )
        end
        @references << reference
        { :type => :reference, :reference => reference }
      end

      def parse_reference(sheet_name)
        start = coordinates(previous.value)
        spill = take(:spill)
        reference = {
          :sheet_name => sheet_name,
          :row_from => start[:row],
          :row_to => start[:row],
          :column_from => start[:column],
          :column_to => start[:column],
          :spill => spill
        }
        raise ParseError, 'A1# cannot include a range' if spill && take(:punctuation, ':')
        reference
      end

      def parse_constant_matrix
        rows = []
        current_row = []

        loop do
          current_row << parse_unary
          if take(:punctuation, ',')
            next
          elsif take(:punctuation, ';')
            rows << current_row
            current_row = []
          else
            expect(:punctuation, '}')
            rows << current_row
            break
          end
        end

        { :type => :matrix, :rows => rows }
      end

      def parse_function(name)
        arguments = []
        unless take(:punctuation, ')')
          loop do
            arguments << parse_expression
            break if take(:punctuation, ')')
            expect(:punctuation, ',')
          end
        end
        { :type => :function, :name => name.upcase, :arguments => arguments }
      end

      def coordinates(reference)
        match = /\A\$?([A-Za-z]{1,3})\$?(\d+)\z/.match(reference)
        raise ParseError, "invalid reference #{reference}" unless match
        {
          :row => Integer(match[2]) - 1,
          :column => column_index(match[1].upcase)
        }
      end

      def column_index(letters)
        letters.each_char.reduce(0) { |result, letter| (result * 26) + letter.ord - 'A'.ord + 1 } - 1
      end

      def normalize_sheet(token)
        token[0...-1].then { |name|
          name.start_with?("'") ? name[1...-1].gsub("''", "'") : name
        }
      end

      def unescape_string(value)
        value.gsub('""', '"')
      end

      def take(type, *values)
        token = @tokens[@position]
        return false unless token&.type == type
        return false unless values.empty? || values.map(&:upcase).include?(token.value.upcase)

        @position += 1
        true
      end

      def previous
        @tokens[@position - 1]
      end

      def expect(type, value = nil)
        raise ParseError, "expected #{value || type}" unless take(type, *Array(value))
      end
    end

    class Evaluator
      def initialize(engine, key)
        @engine = engine
        @key = key
      end

      def evaluate(ast)
        case ast[:type]
        when :number then Matrix.scalar(ast[:value])
        when :boolean then Matrix.scalar(ast[:value])
        when :string then Matrix.scalar(ast[:value])
        when :nil then Matrix.scalar(nil)
        when :matrix then evaluate_constant_matrix(ast)
        when :unary then apply_unary(evaluate(ast[:value]), ast[:operator])
        when :arithmetic then apply_arithmetic(ast[:operator], evaluate(ast[:left]), evaluate(ast[:right]))
        when :comparison then apply_comparison(ast[:operator], evaluate(ast[:left]), evaluate(ast[:right]))
        when :reference then resolve_reference(ast[:reference])
        when :function then evaluate_function(ast)
        else error_matrix(NAME_ERROR)
        end
      rescue ParseError, ArgumentError, ZeroDivisionError
        error_matrix(VALUE_ERROR)
      end

      private

      def evaluate_constant_matrix(ast)
        Matrix.new(ast[:rows].map { |row| row.map { |node| scalar_value(evaluate(node)) } })
      end

      def apply_unary(matrix, operator)
        return matrix if error?(matrix.value)
        matrix.map { |value| operator == '-' ? -numeric(value) : numeric(value) }
      end

      def apply_arithmetic(operator, left, right)
        return left if error?(left.value)
        return right if error?(right.value)

        combine(left, right) do |left_value, right_value|
          left_number = numeric(left_value)
          right_number = numeric(right_value)
          raise ZeroDivisionError if operator == '/' && right_number.zero?

          left_number.public_send(operator, right_number)
        end
      rescue ZeroDivisionError
        error_matrix(DIV0_ERROR)
      end

      def apply_comparison(operator, left, right)
        return left if error?(left.value)
        return right if error?(right.value)

        combine(left, right) { |left_value, right_value|
          compare(left_value, right_value, operator)
        }
      end

      def compare(left, right, operator)
        left_number = numeric?(left) ? numeric(left) : left.to_s
        right_number = numeric?(right) ? numeric(right) : right.to_s
        ruby_operator = { '=' => :==, '<>' => :!= }.fetch(operator, operator.to_sym)
        left_number.public_send(ruby_operator, right_number)
      rescue ArgumentError
        false
      end

      def combine(left, right)
        rows, columns = combined_shape(left, right)
        Matrix.new(Array.new(rows) { |row_index|
          Array.new(columns) { |column_index|
            yield(value_at(left, row_index, column_index), value_at(right, row_index, column_index))
          }
        })
      end

      def combined_shape(left, right)
        if left.scalar?
          [right.row_count, right.column_count]
        elsif right.scalar?
          [left.row_count, left.column_count]
        else
          raise ArgumentError, 'matrix shapes do not match' unless same_shape?(left, right)
          [left.row_count, left.column_count]
        end
      end

      def value_at(matrix, row_index, column_index)
        matrix.scalar? ? matrix.value : matrix[row_index, column_index]
      end

      def same_shape?(left, right)
        left.row_count == right.row_count && left.column_count == right.column_count
      end

      def evaluate_function(ast)
        arguments = ast[:arguments].map { |argument| evaluate(argument) }
        return arguments.find { |argument| error?(argument.value) } if arguments.any? { |argument| error?(argument.value) }

        case ast[:name]
        when 'SEQUENCE' then sequence(arguments)
        when 'FILTER' then filter(arguments)
        when 'TRANSPOSE' then transpose(arguments)
        else error_matrix(NAME_ERROR)
        end
      end

      def sequence(arguments)
        rows = integer_argument(arguments, 0, 1)
        columns = integer_argument(arguments, 1, 1)
        start = scalar_argument(arguments, 2, 1)
        step = scalar_argument(arguments, 3, 1)
        raise ArgumentError if rows <= 0 || columns <= 0

        Matrix.new(Array.new(rows) { |row_index|
          Array.new(columns) { |column_index|
            start + ((row_index * columns) + column_index) * step
          }
        })
      end

      def filter(arguments)
        array = arguments[0]
        mask = arguments[1]
        empty_value = arguments[2]
        raise ArgumentError if array.nil? || mask.nil? || array.empty?

        selected = if mask.column_count == 1 && mask.row_count == array.row_count
                     array.rows.each_with_index.filter_map { |row, index|
                       row if mask.rows[index].all? { |value| truthy?(value) }
                     }
                   elsif mask.row_count == 1 && mask.column_count == array.column_count
                     selected_columns = mask.rows.first.each_index.select { |index| truthy?(mask[0, index]) }
                     array.rows.map { |row| row.values_at(*selected_columns) }
                   elsif mask.scalar?
                     truthy?(mask.value) ? array.rows : []
                   elsif mask.same_dimensions?(array)
                     array.rows.each_with_index.filter_map { |row, index|
                       row if mask.rows[index].any? { |value| truthy?(value) }
                     }
                   else
                     raise ArgumentError
                   end

        return Matrix.new(selected) unless selected.empty?
        return empty_value if empty_value

        error_matrix(CALC_ERROR)
      end

      def transpose(arguments)
        array = arguments.first
        raise ArgumentError unless arguments.size == 1 && array

        Matrix.new(Array.new(array.column_count) { |row_index|
          Array.new(array.row_count) { |column_index| array[column_index, row_index] }
        })
      end

      def integer_argument(arguments, index, default)
        value = scalar_argument(arguments, index, default)
        numeric(value).to_i
      end

      def scalar_argument(arguments, index, default)
        value = arguments[index]&.value || default
        numeric(value)
      end

      def resolve_reference(reference)
        @engine.resolve_reference(reference, @key)
      end

      def scalar_value(matrix)
        raise ArgumentError, 'scalar value required' unless matrix.scalar?
        matrix.value
      end

      def numeric(value)
        return 0 if value.nil?
        return value if value.is_a?(Numeric)
        return 1 if value == true
        return 0 if value == false
        raise ArgumentError, "#{value.inspect} is not numeric"
      end

      def numeric?(value)
        value.nil? || value.is_a?(Numeric) || value == true || value == false
      end

      def truthy?(value)
        numeric(value) != 0
      end

      def error?(value)
        ERROR_VALUES.include?(value)
      end

      def error_matrix(value)
        Matrix.scalar(value)
      end
    end

    class Engine
      def initialize(workbook)
        @workbook = workbook
        @anchors = []
        @anchor_by_key = {}
        @states = {}
        @results = {}
        @cyclic = {}
      end

      def recalculate
        collect_anchors
        evaluate_anchors
        validate_spill_areas
        commit
        results_summary
      end

      def resolve_reference(reference, requesting_key)
        sheet = sheet_for_reference(reference, requesting_key)
        return Matrix.scalar(REF_ERROR) unless sheet

        if reference[:spill]
          resolve_spill_reference(reference, sheet, requesting_key)
        else
          resolve_range_reference(reference, sheet, requesting_key)
        end
      end

      private

      def collect_anchors
        @workbook.worksheets.each_with_index do |sheet, sheet_index|
          each_cell(sheet) do |cell, row_index, column_index|
            next unless dynamic_anchor?(cell)

            key = [sheet_index, row_index, column_index]
            anchor = {
              :key => key,
              :sheet => sheet,
              :sheet_index => sheet_index,
              :row => row_index,
              :column => column_index,
              :cell => cell,
              :formula => cell.formula&.expression.to_s.sub(/\A=/, '')
            }
            @anchors << anchor
            @anchor_by_key[key] = anchor
          end
        end
      end

      def evaluate_anchors
        @anchors.each { |anchor| evaluate_anchor(anchor[:key]) }
      end

      def evaluate_anchor(key)
        return @results[key] if @states[key] == :done

        if @states[key] == :visiting
          @cyclic[key] = true
          return @results[key] = Matrix.scalar(CYCLE_ERROR)
        end

        anchor = @anchor_by_key[key]
        @states[key] = :visiting

        ast = Parser.parse(anchor[:formula])
        formula_dependencies(ast, key).each { |dependency_key| evaluate_dependency(dependency_key, key) }
        result = Evaluator.new(self, key).evaluate(ast)
        result = Matrix.scalar(CYCLE_ERROR) if @cyclic[key]
        @results[key] = result
        @states[key] = :done
        result
      rescue ParseError
        finish_with_error(key, NAME_ERROR)
      rescue StandardError
        finish_with_error(key, VALUE_ERROR)
      end

      def evaluate_dependency(dependency_key, requesting_key)
        return unless @anchor_by_key.key?(dependency_key)

        if @states[dependency_key] == :visiting
          @cyclic[dependency_key] = true
          @cyclic[requesting_key] = true
          return @results[dependency_key] = Matrix.scalar(CYCLE_ERROR)
        end

        result = evaluate_anchor(dependency_key)
        @cyclic[requesting_key] = true if @cyclic[dependency_key]
        result
      end

      def finish_with_error(key, value)
        @results[key] = Matrix.scalar(value)
        @states[key] = :done
        @results[key]
      end

      def formula_dependencies(ast, requesting_key)
        references(ast).filter_map { |reference|
          sheet_index = sheet_index_for_reference(reference)
          sheet_index = requesting_key.first if sheet_index.nil?
          anchor_key = [sheet_index, reference[:row_from], reference[:column_from]]
          @anchor_by_key.key?(anchor_key) ? anchor_key : nil
        }
      end

      def references(node)
        return [] unless node.is_a?(Hash)
        own = node[:type] == :reference ? [node[:reference]] : []
        child_nodes = node.values.select { |value| value.is_a?(Hash) || value.is_a?(Array) }
        own + child_nodes.flat_map { |value|
          if value.is_a?(Array)
            value.flat_map { |item| item.is_a?(Hash) ? references(item) : [] }
          else
            references(value)
          end
        }
      end

      def validate_spill_areas
        @anchors.each do |anchor|
          key = anchor[:key]
          result = @results[key]
          next unless placeable_result?(result)

          set_spill_error(anchor) unless valid_target_area?(anchor, result)
        end

        detect_overlapping_spills
      end

      def placeable_result?(result)
        result && !result.empty? && !error_value?(result.value)
      end

      def valid_target_area?(anchor, result)
        row_from = anchor[:row]
        column_from = anchor[:column]
        row_to = row_from + result.row_count - 1
        column_to = column_from + result.column_count - 1
        return false if row_to >= MAX_ROWS || column_to >= MAX_COLUMNS
        return false if overlaps_merged_cell?(anchor[:sheet], row_from, row_to, column_from, column_to)

        each_target_cell(anchor[:sheet], row_from, row_to, column_from, column_to) do |cell, row_index, column_index|
          next if row_index == row_from && column_index == column_from
          next if spill_cell?(cell)
          next unless occupied?(cell)
          return false
        end
        true
      end

      def detect_overlapping_spills
        successful_anchors = @anchors.select { |anchor|
          placeable_result?(@results[anchor[:key]])
        }

        successful_anchors.each do |anchor|
          rectangle = spill_rectangle(anchor, @results[anchor[:key]])
          overlapping = successful_anchors.any? do |other|
            next false if other.equal?(anchor)
            rectangles_overlap?(rectangle, spill_rectangle(other, @results[other[:key]]))
          end
          set_spill_error(anchor) if overlapping
        end
      end

      def spill_rectangle(anchor, result)
        {
          :sheet_index => anchor[:sheet_index],
          :row_from => anchor[:row],
          :row_to => anchor[:row] + result.row_count - 1,
          :column_from => anchor[:column],
          :column_to => anchor[:column] + result.column_count - 1
        }
      end

      def rectangles_overlap?(left, right)
        left[:sheet_index] == right[:sheet_index] &&
          left[:row_from] <= right[:row_to] && right[:row_from] <= left[:row_to] &&
          left[:column_from] <= right[:column_to] && right[:column_from] <= left[:column_to]
      end

      def set_spill_error(anchor)
        @results[anchor[:key]] = Matrix.scalar(SPILL_ERROR)
      end

      def commit
        clear_previous_spills
        write_metadata

        @anchors.each do |anchor|
          result = @results[anchor[:key]]
          write_anchor(anchor, result)
        end
      end

      def clear_previous_spills
        @workbook.worksheets.each_with_index do |sheet, sheet_index|
          each_cell(sheet) do |cell, row_index, column_index|
            next unless cell
            sheet.sheet_data.rows[row_index].cells[column_index] = nil if spill_cell?(cell)
          end
        end
      end

      def write_anchor(anchor, result)
        cell = anchor[:cell]
        cell.formula ||= Formula.new
        cell.formula.expression = anchor[:formula]
        cell.formula.t = 'array'
        cell.formula.ca = true

        if placeable_result?(result)
          cell.cm = 0
          write_result(anchor, result)
        else
          cell.cm = 1
          write_scalar_cell(cell, result.value)
          cell.formula.ref = Reference.new(anchor[:row], anchor[:column])
        end
      end

      def write_result(anchor, result)
        anchor[:cell].formula.ref = Reference.new(
          anchor[:row], anchor[:row] + result.row_count - 1,
          anchor[:column], anchor[:column] + result.column_count - 1
        )
        write_scalar_cell(anchor[:cell], result[0, 0])

        (1...result.row_count * result.column_count).each do |offset|
          row_offset = offset / result.column_count
          column_offset = offset % result.column_count
          row_index = anchor[:row] + row_offset
          column_index = anchor[:column] + column_offset
          sheet = anchor[:sheet]
          sheet.sheet_data.rows[row_index] ||= Row.new(:worksheet => sheet)
          cell = sheet.sheet_data.rows[row_index].cells[column_index] ||= Cell.new
          cell.worksheet = sheet
          cell.row = row_index
          cell.column = column_index
          cell.cm = nil
          cell.vm = 1
          cell.formula = nil
          write_scalar_cell(cell, result[row_offset, column_offset])
        end
      end

      def write_scalar_cell(cell, value)
        case value
        when Numeric
          cell.datatype = DataType::NUMBER
          cell.raw_value = value
        when true, false
          cell.datatype = DataType::BOOLEAN
          cell.raw_value = value ? 1 : 0
        when NilClass
          cell.datatype = DataType::NUMBER
          cell.raw_value = 0
        when String
          if error_value?(value)
            cell.datatype = DataType::ERROR
          else
            cell.datatype = DataType::RAW_STRING
          end
          cell.raw_value = value
        else
          cell.datatype = DataType::RAW_STRING
          cell.raw_value = value.to_s
        end
      end

      def write_metadata
        @workbook.sheet_metadata = RubyXL::SheetMetadata.new(
          RubyXL::SheetMetadata.default_path,
          RubyXL::SheetMetadata.default_xml
        )
      end

      def resolve_spill_reference(reference, sheet, requesting_key)
        key = [@workbook.worksheets.index(sheet), reference[:row_from], reference[:column_from]]
        result = evaluate_dependency(key, requesting_key)
        return Matrix.scalar(REF_ERROR) unless result
        return result if reference[:column_to] == reference[:column_from] && reference[:row_to] == reference[:row_from]
        result
      end

      def resolve_range_reference(reference, sheet, requesting_key)
        rows = reference[:row_from]..reference[:row_to]
        columns = reference[:column_from]..reference[:column_to]
        return Matrix.scalar(REF_ERROR) if rows.first > rows.last || columns.first > columns.last

        matrix = Matrix.new(rows.map { |row_index|
          columns.map { |column_index|
            resolve_grid_value(sheet, row_index, column_index, requesting_key)
          }
        })
        matrix.scalar? ? matrix : matrix
      end

      def resolve_grid_value(sheet, row_index, column_index, requesting_key)
        sheet_index = @workbook.worksheets.index(sheet)
        anchor_key = anchor_at(sheet_index, row_index, column_index)
        if anchor_key
          result = evaluate_dependency(anchor_key, requesting_key)
          relative_row = row_index - anchor_key[1]
          relative_column = column_index - anchor_key[2]
          return SPILL_ERROR if result.scalar? && error_value?(result.value) && (relative_row != 0 || relative_column != 0)
          return result[relative_row, relative_column] if relative_row < result.row_count && relative_column < result.column_count
        end
        cell_value(sheet.sheet_data.rows[row_index]&.cells&.[](column_index))
      end

      def anchor_at(sheet_index, row_index, column_index)
        @anchors.find do |anchor|
          next false unless anchor[:sheet_index] == sheet_index
          result = @results[anchor[:key]]
          row_range, column_range = old_or_new_range(anchor, result)
          row_range.cover?(row_index) && column_range.cover?(column_index)
        end&.dig(:key)
      end

      def old_or_new_range(anchor, result)
        formula_reference = anchor[:cell].formula&.ref
        if result&.is_a?(Matrix) && !result.empty?
          [anchor[:row]...(anchor[:row] + result.row_count),
           anchor[:column]...(anchor[:column] + result.column_count)]
        elsif formula_reference
          [formula_reference.row_range, formula_reference.col_range]
        else
          [anchor[:row]..anchor[:row], anchor[:column]..anchor[:column]]
        end
      end

      def sheet_for_reference(reference, requesting_key)
        sheet_index = sheet_index_for_reference(reference)
        if sheet_index.nil?
          @workbook.worksheets[requesting_key.first]
        else
          @workbook.worksheets[sheet_index]
        end
      end

      def sheet_index_for_reference(reference)
        return nil unless reference[:sheet_name]
        @workbook.worksheets.index { |sheet| sheet.sheet_name == reference[:sheet_name] }
      end

      def each_target_cell(sheet, row_from, row_to, column_from, column_to)
        (row_from..row_to).each do |row_index|
          (column_from..column_to).each do |column_index|
            yield(sheet.sheet_data.rows[row_index]&.cells&.[](column_index), row_index, column_index)
          end
        end
      end

      def overlaps_merged_cell?(sheet, row_from, row_to, column_from, column_to)
        return false unless sheet.merged_cells
        sheet.merged_cells.any? do |merged|
          merged.ref.row_range.begin <= row_to && row_from <= merged.ref.row_range.end &&
            merged.ref.col_range.begin <= column_to && column_from <= merged.ref.col_range.end
        end
      end

      def occupied?(cell)
        return false if cell.nil?
        return true if cell.formula
        return true if dynamic_anchor?(cell)
        return false if cell.value.nil? && cell.raw_value.nil?
        true
      end

      def spill_cell?(cell)
        cell && cell.vm.to_i == 1 && !dynamic_anchor?(cell)
      end

      def dynamic_anchor?(cell)
        return false unless cell&.formula
        cell.formula.t == 'array' && (cell.formula.ca == true || cell.formula.ca.to_s == '1' ||
                                      cell.cm.to_i == 1)
      end

      def cell_value(cell)
        return cell.raw_value if cell&.datatype == DataType::ERROR
        cell&.value
      end

      def error_value?(value)
        ERROR_VALUES.include?(value)
      end

      def each_cell(sheet)
        sheet.sheet_data&.rows&.each_with_index do |row, row_index|
          next unless row
          row.cells.each_with_index do |cell, column_index|
            yield(cell, row_index, column_index)
          end
        end
      end

      def results_summary
        @anchors.map { |anchor|
          result = @results[anchor[:key]]
          {
            :anchor => anchor[:key],
            :rows => result.row_count,
            :columns => result.column_count,
            :value => result.scalar? ? result.value : nil,
            :error? => result.scalar? && error_value?(result.value)
          }
        }
      end
    end

    module WorksheetMethods
      def set_dynamic_formula(row, column, formula)
        add_cell(row, column, nil, formula.sub(/\A=/, ''))
        cell = sheet_data.rows[row].cells[column]
        cell.formula.t = 'array'
        cell.formula.ca = true
        cell.formula.ref = RubyXL::Reference.new(row, column)
        cell
      end

      def recalculate_dynamic_arrays
        RubyXL::DynamicArray.recalculate_workbook(workbook)
      end

      def dynamic_array_anchor?(row, column)
        cell = sheet_data.rows[row]&.cells&.[](column)
        return false unless cell&.formula
        cell.formula.t == 'array' && (cell.formula.ca == true || cell.formula.ca.to_s == '1' ||
                                      cell.cm.to_i == 1)
      end

      def dynamic_array_anchor_at(cell_row, cell_column)
        each_dynamic_array_anchor.find do |anchor|
          reference = anchor[:cell].formula.ref
          reference.row_range.cover?(cell_row) && reference.col_range.cover?(cell_column)
        end
      end

      def each_dynamic_array_anchor
        return enum_for(:each_dynamic_array_anchor) unless block_given?

        sheet_data&.rows&.each_with_index do |row, row_index|
          next unless row
          row.cells.each_with_index do |cell, column_index|
            next unless dynamic_array_anchor?(row_index, column_index)
            yield({ :row => row_index, :column => column_index, :cell => cell })
          end
        end
      end
    end

  end

  class SheetMetadata < GenericStorageObject
    DEFAULT_PATH = OOXMLTopLevelObject::ROOT.join('xl', 'metadata.xml').freeze

    def initialize(file_path = DEFAULT_PATH, data = nil)
      super
    end

    def self.default_path
      DEFAULT_PATH
    end

    def self.default_xml
      Nokogiri::XML::Builder.new(:encoding => 'UTF-8') do |xml|
        xml.metadata(:xmlns => 'http://schemas.openxmlformats.org/spreadsheetml/2006/main',
                      'xmlns:xda' => 'http://schemas.microsoft.com/office/spreadsheetml/2017/dynamicarray') do
          xml.metadataTypes(:count => 1) do
            xml.metadataType(
              :name => 'XLDAPR',
              :minSupportedVersion => 120000,
              :copy => 1,
              :pasteAll => 1,
              :pasteValues => 1,
              :merge => 1,
              :splitFirst => 1,
              :rowColShift => 1,
              :clearFormats => 1,
              :clearComments => 1,
              :coerce => 1,
              :erase => 1,
              :threadedComment => 1
            )
          end
          xml.futureMetadata(:count => 2, :name => 'XLDAPR') do
            xml.bk do
              xml['xda'].dynamicArrayProperties(:fCollapsed => 0, :fDynamic => 1, :bc => 1, :ca => 1)
            end
            xml.bk do
              xml['xda'].dynamicArrayProperties(:fCollapsed => 1, :fDynamic => 0, :bc => 1, :ca => 1)
            end
          end
          xml.cellMetadata(:count => 2) do
            xml.bk { xml.rc(:t => 1, :v => 0) }
            xml.bk { xml.rc(:t => 1, :v => 1) }
          end
          xml.valueMetadata(:count => 1) do
            xml.bk { xml.v(:t => 3) }
          end
        end
      end.to_xml
    end
  end

  Worksheet.include(DynamicArray::WorksheetMethods)
end
