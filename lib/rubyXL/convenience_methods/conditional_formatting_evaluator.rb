# frozen_string_literal: true

require 'date'
require 'rubyXL/convenience_methods/color' if defined?(RubyXL::Color)

module RubyXL
  class ConditionalFormattingError < StandardError
    SUPPORTED_RULE_TYPES = %w[
      cellIs expression duplicateValues uniqueValues top10 colorScale
    ].freeze

    SUPPORTED_FORMULA_FUNCTIONS = %w[
      AND OR NOT IF IFERROR ISBLANK ISERROR ISNUMBER ISTEXT ISLOGICAL NA
      SUM AVERAGE COUNT COUNTA COUNTBLANK MIN MAX LARGE SMALL MEDIAN PERCENTILE
      ABS INT TRUNC ROUND FLOOR CEILING SQRT MOD POWER LN LOG EXP
      LEN LEFT RIGHT MID UPPER LOWER CONCAT CONCATENATE DATE YEAR MONTH DAY
    ].freeze

    def self.unsupported_rule(type)
      new("Unsupported conditional formatting rule type #{type.inspect}. Supported types: #{SUPPORTED_RULE_TYPES.join(', ')}")
    end

    def self.unsupported_formula(detail)
      new("Formula is outside the supported conditional formatting subset: #{detail}")
    end
  end

  class FormulaError < StandardError
    attr_reader :code

    def initialize(code = '#VALUE!')
      @code = code
      super(code)
    end
  end

  class ConditionalFormattingEvaluation
    attr_accessor :style, :rules

    def initialize(style, rules)
      @style = style
      @rules = rules
    end
  end

  class ConditionalFormattingEvaluator
    def initialize(worksheet, value_provider = nil)
      @worksheet = worksheet
      @workbook = worksheet.workbook
      @value_provider = value_provider || method(:default_value)
      raise ArgumentError, 'value provider must respond to #call(row, column)' unless @value_provider.respond_to?(:call)
    end

    def evaluate(row, column = nil)
      row, column = extract_coordinates(row, column)
      raise ArgumentError, 'row and column must be non-negative integers' unless valid_coordinates?(row, column)

      target = RubyXL::Reference.new(row, column)
      merged_style = nil
      matched = []

      applicable_rules(target).each do |entry|
        rule = entry[:rule]
        range = entry[:range]
        matched_style = evaluate_rule(rule, range, row, column)
        next if matched_style.nil? || matched_style == false

        matched << rule
        merged_style = merge_dxf(merged_style, matched_style) if matched_style.is_a?(DXF)
        break if rule.stop_if_true && rule.type != 'colorScale'
      end

      ConditionalFormattingEvaluation.new(merged_style, matched)
    end

    private

    def default_value(row, column)
      cell = @worksheet.sheet_data&.rows&.[](row)&.cells&.[](column)
      cell&.value
    end

    def valid_coordinates?(row, column)
      row.is_a?(Integer) && column.is_a?(Integer) && row >= 0 && column >= 0
    end

    def extract_coordinates(row, column)
      return [row, column] unless column.nil?
      reference = Reference.new(row.to_s)
      raise ArgumentError, "Invalid cell reference: #{row}" unless reference.valid? && reference.single_cell?
      [reference.first_row, reference.first_col]
    end

    def applicable_rules(target)
      result = []
      seen = {}

      Array(@worksheet.conditional_formatting).each do |conditional_formatting|
        next if conditional_formatting.pivot
        sqref_segments(conditional_formatting.sqref).each do |range|
          next unless range.cover?(target)

          Array(conditional_formatting.cf_rule).each do |rule|
            next if seen[rule.object_id]
            seen[rule.object_id] = true
            result << { :rule => rule, :range => range }
          end
        end
      end

      result.each_with_index.sort_by { |entry, index| [entry[:rule].priority || Float::INFINITY, index] }.map(&:first)
    end

    def sqref_segments(sqref)
      return sqref if sqref.is_a?(Sqref)
      return Sqref.new(sqref) if sqref.is_a?(String)
      return sqref if sqref.is_a?(Array) && sqref.all? { |segment| segment.is_a?(Reference) }
      Sqref.new(Array(sqref).join(' '))
    end

    def evaluate_rule(rule, range, row, column)
      case rule.type
      when 'cellIs' then
        matched = cell_is?(rule, range, row, column)
        return false unless matched
        dxf_for_rule(rule) || :matched
      when 'expression' then
        matched = expression?(rule, range, row, column)
        return false unless matched
        dxf_for_rule(rule) || :matched
      when 'duplicateValues' then
        matched = duplicate_or_unique?(range, row, column, true)
        return false unless matched
        dxf_for_rule(rule) || :matched
      when 'uniqueValues' then
        matched = duplicate_or_unique?(range, row, column, false)
        return false unless matched
        dxf_for_rule(rule) || :matched
      when 'top10' then
        matched = top_ten?(rule, range, row, column)
        return false unless matched
        dxf_for_rule(rule) || :matched
      when 'colorScale' then
        color_scale(rule, range, row, column)
      when nil then
        raise ConditionalFormattingError, 'conditional formatting rule is missing a type'
      else
        raise ConditionalFormattingError.unsupported_rule(rule.type)
      end
    end

    def dxf_for_rule(rule)
      return nil if rule.dxf_id.nil?
      dxf = @workbook&.stylesheet&.dxfs && @workbook.stylesheet.dxfs[rule.dxf_id]
      raise ConditionalFormattingError, "dxfId #{rule.dxf_id.inspect} does not exist" if dxf.nil?
      deep_clone(dxf)
    end

    def cell_is?(rule, range, row, column)
      current = cell_value(row, column)
      formula_nodes = Array(rule.formulas)
      formula_count = %w[between notBetween].include?(rule.operator || 'equal') ? 2 : 1
      unless formula_nodes.size == formula_count
        raise ConditionalFormattingError, "cellIs rule #{rule.operator.inspect} must have #{formula_count} formulas"
      end
      values = formula_nodes.map { |formula| formula_value(formula.expression, range, row, column) }

      case rule.operator || 'equal'
      when 'lessThan' then compare(current, values.fetch(0)).negative?
      when 'lessThanOrEqual' then compare(current, values.fetch(0)) <= 0
      when 'equal' then compare(current, values.fetch(0)).zero?
      when 'notEqual' then !compare(current, values.fetch(0)).zero?
      when 'greaterThanOrEqual' then compare(current, values.fetch(0)) >= 0
      when 'greaterThan' then compare(current, values.fetch(0)).positive?
      when 'between' then range_compare?(current, values, true)
      when 'notBetween' then !range_compare?(current, values, false)
      else
        raise ConditionalFormattingError, "Unsupported cellIs operator #{rule.operator.inspect}"
      end
    end

    def range_compare?(current, values, _between)
      low = values.fetch(0)
      high = values.fetch(1)
      compare(current, low) >= 0 && compare(current, high) <= 0
    end

    def expression?(rule, range, row, column)
      formula = rule.formulas&.first
      raise ConditionalFormattingError, 'expression rule must have one formula' if formula.nil?
      truthy?(formula_value(formula.expression, range, row, column))
    end

    def duplicate_or_unique?(range, row, column, want_duplicate)
      current = cell_value(row, column)
      return false if blank?(current)
      count = segment_values(range).count { |value| values_equal?(value, current) }
      want_duplicate ? count > 1 : count == 1
    end

    def top_ten?(rule, range, row, column)
      rank = rule.rank || 10
      raise ConditionalFormattingError, 'top10 rank must be positive' unless rank.positive?
      if rule.rank.nil? && rule.percent
        raise ConditionalFormattingError, 'top10 percentage rule must specify rank'
      end
      current = numeric_cell(row, column)
      return false if current.nil?

      values = segment_numbers(range)
      selected_count = rule.percent ? [(values.size * rank / 100.0).floor, 1].max : [rank, values.size].min
      sorted = values.sort
      threshold = rule.bottom ? sorted[selected_count - 1] : sorted[-selected_count]
      rule.bottom ? current <= threshold : current >= threshold
    end

    def color_scale(rule, range, row, column)
      scale = rule.color_scale
      raise ConditionalFormattingError, 'colorScale rule has no colorScale element' if scale.nil?
      current = numeric_cell(row, column)
      return nil if current.nil?

      values = segment_numbers(range)
      thresholds = scale.cfvo.map { |endpoint| threshold(endpoint, range, row, column, values) }
      colors = scale.color
      raise ConditionalFormattingError, 'colorScale must contain at least two stops' if thresholds.size < 2 || colors.size < 2

      rgb = interpolated_rgb(current, thresholds, colors, values)
      fill = RubyXL::Fill.new(:pattern_fill => RubyXL::PatternFill.new(:bg_color => RubyXL::Color.new(:rgb => rgb)))
      RubyXL::DXF.new(:fill => fill)
    end

    def threshold(endpoint, range, row, column, values)
      case endpoint.type
      when 'min' then { :value => values.min, :gte => true }
      when 'max' then { :value => values.max, :gte => true }
      when 'num', 'percent' then
        number = formula_value(endpoint.val, range, row, column)
        raise ConditionalFormattingError, 'invalid numeric color scale threshold' unless number.is_a?(Numeric)
        number = values.min + ((values.max - values.min) * number / 100.0) if endpoint.type == 'percent'
        { :value => number, :gte => endpoint.gte.nil? ? true : endpoint.gte }
      when 'percentile' then
        percentile_rank = formula_value(endpoint.val, range, row, column)
        unless percentile_rank.is_a?(Numeric) && percentile_rank >= 0 && percentile_rank <= 100
          raise ConditionalFormattingError, 'invalid percentile color scale threshold'
        end
        { :value => percentile(values, percentile_rank), :gte => endpoint.gte.nil? ? true : endpoint.gte }
      when 'formula' then
        threshold = formula_value(endpoint.val, range, row, column)
        raise ConditionalFormattingError, 'invalid formula color scale threshold' unless threshold.is_a?(Numeric)
        { :value => threshold, :gte => endpoint.gte.nil? ? true : endpoint.gte }
      else
        raise ConditionalFormattingError, "Unsupported color scale endpoint type #{endpoint.type.inspect}"
      end
    end

    def interpolated_rgb(current, thresholds, colors, values)
      raise ConditionalFormattingError, 'colorScale cannot evaluate an empty numeric range' if values.empty?

      thresholds.each_cons(2).with_index do |(lower, upper), index|
        low = lower[:value]
        high = upper[:value]
        next if low == high
        fraction = ((current - low) / (high - low)).to_f
        lower_bound = lower[:gte].nil? || lower[:gte] ? low : nil
        if (lower_bound.nil? || current > lower_bound) && current <= high
          return blend_rgb(resolve_rgb(colors[index]), resolve_rgb(colors[index + 1]), fraction)
        end
      end

      low = thresholds.first[:value]
      high = thresholds.last[:value]
      fraction = high == low ? 0.0 : ((current - low) / (high - low)).to_f
      fraction = [[fraction, 0.0].max, 1.0].min
      blend_rgb(resolve_rgb(colors.first), resolve_rgb(colors.last), fraction)
    end

    def resolve_rgb(color)
      rgb = color.get_rgb(@workbook)
      raise ConditionalFormattingError, 'only RGB/theme colors are supported by colorScale evaluation' if rgb.nil?
      rgb = rgb.rjust(8, 'F') if rgb.size == 6
      raise ConditionalFormattingError, "invalid RGB color #{rgb.inspect}" unless rgb.match?(/\A[0-9a-fA-F]{8}\z/)
      rgb.upcase
    end

    def blend_rgb(low_rgb, high_rgb, fraction)
      low = low_rgb.scan(/../).map { |channel| channel.to_i(16) }
      high = high_rgb.scan(/../).map { |channel| channel.to_i(16) }
      low.zip(high).map { |low_value, high_value|
        value = low_value + ((high_value - low_value) * fraction)
        format('%02X', value.round.clamp(0, 255))
      }.join
    end

    def percentile(values, rank)
      sorted = values.sort
      position = (rank - 1) / 99.0 * (sorted.size - 1)
      low = position.floor
      high = position.ceil
      sorted[low] + ((sorted[high] - sorted[low]) * (position - low))
    end

    def formula_value(expression, range, row, column)
      translated = translate_formula(expression, range, row, column)
      FormulaParser.new(translated).evaluate(FormulaRuntime.new(@value_provider, @workbook))
    rescue ConditionalFormattingError
      raise
    end

    def translate_formula(expression, range, row, column)
      raise ConditionalFormattingError, 'conditional formatting formula is missing' if expression.nil?
      expression.gsub(ConditionalFormulaLexer::REFERENCE_WITH_SHEET) do
        match = Regexp.last_match
        next match[:string] if match[:string]
        raise ConditionalFormattingError.unsupported_formula("cross-sheet reference #{match[0]}") if match[:sheet]
        shift_reference(match[:reference], row, column)
      end
    end

    def shift_reference(reference, target_row, target_column)
      from_text, to_text = reference.split(':')
      shifted_from = shift_ref_part(from_text, target_row, target_column)
      return shifted_from if to_text.nil?
      shifted_to = shift_ref_part(to_text, target_row, target_column)
      "#{shifted_from}:#{shifted_to}"
    end

    def shift_ref_part(cell_reference, target_row, target_column)
      match = ConditionalFormulaLexer::CELL_PART.match(cell_reference)
      row_abs = match[:rabs] == '$'
      col_abs = match[:cabs] == '$'
      row_text = match[:row]
      col_text = match[:col]
      row = row_text.to_i - 1
      col = Reference.ref2ind(col_text.upcase + '1')[1]
      row += target_row unless row_abs == true
      col += target_column unless col_abs == true
      Reference.ind2ref(row, col, row_abs, col_abs)
    end

    def segment_values(range)
      values = []
      (range.first_row..range.last_row).each do |row|
        (range.first_col..range.last_col).each do |column|
          value = cell_value(row, column)
          values << value unless blank?(value)
        end
      end
      values
    end

    def segment_numbers(range)
      segment_values(range).each { |value| raise value if value.is_a?(FormulaError) }
                      .select { |value| numeric?(value) }
                      .map(&:to_f)
    end

    def cell_value(row, column)
      value = @value_provider.call(row, column)
      raise ConditionalFormattingError, "value provider returned invalid value at (#{row}, #{column})" unless valid_value?(value)
      value
    end

    def valid_value?(value)
      value.nil? || value.is_a?(Numeric) || value.is_a?(String) || value.is_a?(TrueClass) || value.is_a?(FalseClass) ||
        value.is_a?(Date) || value.is_a?(Time) || value.is_a?(FormulaError)
    end

    def numeric_cell(row, column)
      value = cell_value(row, column)
      native_number(value)
    end

    def native_number(value)
      return value.to_f if value.is_a?(Numeric)
      return @workbook.date_to_num(value) if (value.is_a?(Date) || value.is_a?(Time)) && @workbook.respond_to?(:date_to_num)
      nil
    end

    def numeric?(value)
      !native_number(value).nil?
    end

    def blank?(value)
      value.nil? || value == ''
    end

    def values_equal?(left, right)
      compare(left, right).zero?
    end

    def compare(left, right)
      raise left if left.is_a?(FormulaError)
      raise right if right.is_a?(FormulaError)
      return numeric_compare(to_number(left), to_number(right)) if numeric_comparable?(left) && numeric_comparable?(right)
      return to_text(left).casecmp(to_text(right)) if text_like?(left) && text_like?(right)
      type_rank(left) <=> type_rank(right)
    end

    def numeric_comparable?(value)
      blank?(value) || numeric?(value)
    end

    def numeric_compare(left, right)
      left <=> right
    end

    def to_number(value)
      return 0.0 if blank?(value)
      native_number(value)
    end

    def text_like?(value)
      value.is_a?(String)
    end

    def to_text(value)
      value.to_s
    end

    def type_rank(value)
      case value
      when nil then 0
      when Numeric then 1
      when String then 2
      when TrueClass, FalseClass then 3
      else 4
      end
    end

    def truthy?(value)
      case value
      when true then true
      when false then false
      else raise ConditionalFormattingError, "conditional formatting formula did not return a boolean: #{value.inspect}"
      end
    end

    def deep_clone(object)
      return object.dup if object.nil? || object.is_a?(Symbol) || object.is_a?(Numeric) ||
        object.is_a?(TrueClass) || object.is_a?(FalseClass)
      return object.dup if object.is_a?(String)
      copy = object.class.allocate
      copy.local_namespaces = object.local_namespaces
      object.class.class_variable_get(:@@ooxml_attributes).each_value do |attribute|
        copy.public_send("#{attribute[:accessor]}=", deep_clone(object.public_send(attribute[:accessor])))
      end
      object.class.class_variable_get(:@@ooxml_child_nodes).each_value do |child|
        value = object.public_send(child[:accessor])
        cloned = child[:is_array] ? Array(value).map { |item| deep_clone(item) } : deep_clone(value)
        copy.public_send("#{child[:accessor]}=", cloned)
      end
      copy
    end

    def merge_dxf(target, addition)
      return addition if target.nil?
      merge_style(target, addition)
      target
    end

    def merge_style(target, addition)
      reset_conflicting_fill(target, addition)
      merge_attributes(target, addition)
      addition.class.class_variable_get(:@@ooxml_child_nodes).each_value do |child|
        added_value = addition.public_send(child[:accessor])
        next if added_value.nil?
        current_value = target.public_send(child[:accessor])
        if child[:is_array]
          target.public_send("#{child[:accessor]}=", Array(current_value) + Array(added_value).map { |item| deep_clone(item) })
        elsif current_value.nil? || current_value.class != added_value.class
          target.public_send("#{child[:accessor]}=", deep_clone(added_value))
        else
          merge_style(current_value, added_value)
        end
      end
    end

    def reset_conflicting_fill(target, addition)
      return unless target.is_a?(Fill) && addition.is_a?(Fill)
      return unless (target.pattern_fill && addition.gradient_fill) || (target.gradient_fill && addition.pattern_fill)
      target.pattern_fill = nil
      target.gradient_fill = nil
    end

    def merge_attributes(target, addition)
      addition.class.class_variable_get(:@@ooxml_attributes).each_value do |attribute|
        value = addition.public_send(attribute[:accessor])
        target.public_send("#{attribute[:accessor]}=", deep_clone(value)) unless value.nil?
      end
    end
  end

  class ConditionalFormulaLexer
    CELL_PART = /(?<cabs>\$?)(?<col>[A-Za-z]{1,3})(?<rabs>\$?)(?<row>\d+)/.freeze
    REFERENCE = /\A#{CELL_PART}(?::(?<tocabs>\$?)(?<tocol>[A-Za-z]{1,3})(?<torabs>\$?)(?<torow>\d+))?\z/.freeze
    REFERENCE_WITH_SHEET = %r{
      (?<string>"(?:[^"]|"")*") |
      (?:(?<sheet>'[^']+'|[^\s!:#<>=+\-*/%^&(),\d]+)!)?(?<reference>(?:\$?)[A-Za-z]{1,3}(?:\$?)\d+(?::(?:\$?)[A-Za-z]{1,3}(?:\$?)\d+)?)
    }x.freeze
  end

  FormulaToken = Struct.new(:type, :value, :position)

  class FormulaParser
    TOKEN_PATTERN = %r{
      \s+ |
      "(?:[^"]|"")*" |
      \#[A-Z0-9./]+ |
      (?:\$?[A-Za-z]{1,3}\$?\d+)(?::(?:\$?[A-Za-z]{1,3}\$?\d+))? |
      \d+(?:\.\d+)?(?:[eE][+-]?\d+)? |
      [A-Za-z_][A-Za-z0-9_.]*(?![A-Za-z0-9_]) |
      <>|<=|>=|!=|[+\-*/%^&=<>(),;]
    }x.freeze

    def self.parse(expression)
      parser = new(expression)
      ast = parser.parse_expression
      parser.send(:expect_end)
      ast
    end

    attr_reader :tokens, :index

    def initialize(expression)
      raise ConditionalFormattingError, 'conditional formatting formula is missing' if expression.nil?
      @expression = expression.start_with?('=') ? expression[1..] : expression
      @tokens = tokenize
      @index = 0
    end

    def evaluate(runtime)
      value = runtime.evaluate(parse_expression)
      expect_end
      value
    end

    def parse_expression
      parse_comparison
    end

    private

    def tokenize
      tokens = []
      position = 0
      while position < @expression.size
        match = TOKEN_PATTERN.match(@expression, position)
        if match.nil? || match.begin(0) != position
          raise ConditionalFormattingError.unsupported_formula(@expression.inspect)
        end
        value = match[0]
        tokens << FormulaToken.new(token_type(value), value, position) unless value.match?(/\A\s+\z/)
        position = match.end(0)
      end
      tokens
    end

    def token_type(value)
      case value
      when /\A"/ then :string
      when /\A#/ then :error
      when /\A\$?[A-Za-z]{1,3}\$?\d/ then :reference
      when /\A\d/ then :number
      when /\A[A-Za-z_]/ then :name
      else :operator
      end
    end

    def parse_comparison
      left = parse_concat
      operators = ['=', '<>', '!=', '<', '>', '<=', '>=']
      return left unless operators.any? { |operator| operator?(operator) }
      operator = take.value
      operator = '<>' if operator == '!='
      [:comparison, operator, left, parse_comparison]
    end

    def parse_concat
      parse_binary(:parse_additive, '&')
    end

    def parse_additive
      parse_binary(:parse_multiplicative, '+', '-')
    end

    def parse_multiplicative
      parse_binary(:parse_exponent, '*', '/')
    end

    def parse_binary(child_method, *operators)
      left = method(child_method).call
      while operators.any? { |operator| operator?(operator) }
        operator = take.value
        left = [:binary, operator, left, method(child_method).call]
      end
      left
    end

    def parse_exponent
      left = parse_unary
      return left unless operator?('^')
      take
      [:binary, '^', left, parse_exponent]
    end

    def parse_unary
      if operator?('+') || operator?('-')
        operator = take.value
        [:unary, operator == '-' ? :negative : :positive, parse_unary]
      else
        parse_percent
      end
    end

    def parse_percent
      value = parse_primary
      while operator?('%')
        take
        value = [:percent, value]
      end
      value
    end

    def parse_primary
      token = take
      case token.type
      when :number then [:number, numeric_value(token.value)]
      when :string then [:string, unescape(token.value)]
      when :error then [:error, token.value]
      when :reference then parse_reference(token)
      when :name then parse_name(token)
      else
        raise ConditionalFormattingError.unsupported_formula(@expression.inspect) unless token.value == '('
        value = parse_expression
        expect_operator(')')
        value
      end
    end

    def parse_reference(token)
      if token.value.include?(':')
        from, to = token.value.split(':')
        return [:range, from, to]
      end
      if operator?(':')
        take
        ending = take
        raise ConditionalFormattingError.unsupported_formula(@expression.inspect) unless ending.type == :reference
        [:range, token.value, ending.value]
      else
        [:reference, token.value]
      end
    end

    def parse_name(token)
      name = token.value.upcase
      return [:boolean, true] if name == 'TRUE'
      return [:boolean, false] if name == 'FALSE'
      raise ConditionalFormattingError.unsupported_formula("name or named range #{name}") unless operator?('(')
      take
      arguments = parse_arguments
      expect_operator(')')
      unless ConditionalFormattingError::SUPPORTED_FORMULA_FUNCTIONS.include?(name)
        raise ConditionalFormattingError.unsupported_formula("function #{name}")
      end
      [:function, name, arguments]
    end

    def parse_arguments
      return [] if operator?(')')
      arguments = [parse_expression]
      while operator?(',') || operator?(';')
        take
        arguments << parse_expression
      end
      arguments
    end

    def numeric_value(value)
      value.include?('.') || value =~ /e/i ? Float(value) : Integer(value)
    end

    def unescape(value)
      value[1...-1].gsub('""', '"')
    end

    def operator?(value)
      tokens[index]&.value == value
    end

    def take
      token = tokens[index]
      raise ConditionalFormattingError.unsupported_formula(@expression.inspect) if token.nil?
      @index += 1
      token
    end

    def expect_operator(value)
      token = take
      return if token.type == :operator && token.value == value
      raise ConditionalFormattingError.unsupported_formula(@expression.inspect)
    end

    def expect_end
      raise ConditionalFormattingError.unsupported_formula(@expression.inspect) unless index == tokens.size
    end
  end

  class FormulaRuntime
    ReferenceValues = Struct.new(:values)

    def initialize(value_provider, workbook = nil)
      @value_provider = value_provider
      @workbook = workbook
    end

    def evaluate(node)
      type = node.first
      case type
      when :number, :string, :boolean then node[1]
      when :error then raise FormulaError.new(node[1])
      when :reference then evaluate_reference(node[1])
      when :range then ReferenceValues.new(range_values(node[1], node[2]))
      when :unary then evaluate_unary(node)
      when :percent then scalar(evaluate(node[1])) / 100.0
      when :binary then evaluate_binary(node)
      when :comparison then evaluate_comparison(node)
      when :function then evaluate_function(node)
      else raise ConditionalFormattingError.unsupported_formula(node.inspect)
      end
    end

    private

    def evaluate_reference(reference)
      row, column = Reference.ref2ind(strip_absolute_marks(reference).upcase)
      if row.negative? || column.negative? || row > Reference::ROW_MAX || column > Reference::COL_MAX
        raise ConditionalFormattingError.unsupported_formula("reference #{reference}")
      end
      @value_provider.call(row, column)
    end

    def strip_absolute_marks(reference)
      reference.delete('$')
    end

    def range_values(from, to)
      first = Reference.ref2ind(strip_absolute_marks(from).upcase)
      last = Reference.ref2ind(strip_absolute_marks(to).upcase)
      if first[0] > last[0] || first[1] > last[1]
        raise ConditionalFormattingError.unsupported_formula("#{from}:#{to}")
      end
      (first[0]..last[0]).flat_map do |row|
        (first[1]..last[1]).map { |column| @value_provider.call(row, column) }
      end
    end

    def evaluate_unary(node)
      value = scalar(evaluate(node[2]))
      node[1] == :negative ? -value : value
    end

    def evaluate_binary(node)
      operator = node[1]
      return evaluate_concat(node) if operator == '&'
      left = scalar(evaluate(node[2]))
      right = scalar(evaluate(node[3]))
      case operator
      when '+' then left + right
      when '-' then left - right
      when '*' then left * right
      when '/' then raise FormulaError.new('#DIV/0!') if right.zero?; left / right
      when '^' then left ** right
      else raise ConditionalFormattingError.unsupported_formula(operator)
      end
    end

    def evaluate_concat(node)
      text(evaluate(node[2])) + text(evaluate(node[3]))
    end

    def evaluate_comparison(node)
      operator = node[1]
      left = unwrap(evaluate(node[2]))
      right = unwrap(evaluate(node[3]))
      result = excel_compare(left, right)
      case operator
      when '=' then result.zero?
      when '<>' then !result.zero?
      when '<' then result.negative?
      when '<=' then result <= 0
      when '>' then result.positive?
      when '>=' then result >= 0
      end
    end

    def excel_compare(left, right)
      if numeric?(left) && numeric?(right)
        scalar(left) <=> scalar(right)
      elsif left.is_a?(String) && right.is_a?(String)
        left.casecmp(right)
      else
        type_rank(left) <=> type_rank(right)
      end
    end

    def scalar(value)
      raise FormulaError.new('#VALUE!') if value.is_a?(ReferenceValues)
      return value if value.is_a?(Numeric)
      return 1 if value == true
      return 0 if value == false
      return nil.to_f if value.nil? || value == ''
      return Float(value) if value.is_a?(String) && numeric?(value)
      return @workbook.date_to_num(value) if (value.is_a?(Date) || value.is_a?(Time)) && @workbook.respond_to?(:date_to_num)
      raise FormulaError.new('#VALUE!')
    end

    def text(value)
      unwrap(value).to_s
    end

    def unwrap(value)
      raise FormulaError.new('#VALUE!') if value.is_a?(ReferenceValues) && value.values.size != 1
      value.is_a?(ReferenceValues) ? value.values.first : value
    end

    def numeric?(value)
      value.is_a?(Numeric) || (value.is_a?(String) && value.match?(/\A-?\d+(?:\.\d+)?(?:e[+-]?\d+)?\z/i))
    end

    def type_rank(value)
      case value
      when nil then 0
      when Numeric then 1
      when String then 2
      when TrueClass, FalseClass then 3
      else 4
      end
    end

    def evaluate_function(node)
      name = node[1]
      arguments = node[2]
      case name
      when 'IF' then boolean(evaluate(arguments.fetch(0))) ? evaluate(arguments.fetch(1)) : evaluate(arguments.fetch(2))
      when 'IFERROR'
        begin
          evaluate(arguments.fetch(0))
        rescue FormulaError
          evaluate(arguments.fetch(1))
        end
      when 'AND' then flat_arguments(arguments).all? { |value| boolean(value) }
      when 'OR' then flat_arguments(arguments).any? { |value| boolean(value) }
      when 'NOT' then !boolean(evaluate(arguments.fetch(0)))
      when 'NA' then raise FormulaError.new('#N/A')
      when 'ISBLANK' then [nil, ''].include?(evaluate(arguments.fetch(0)))
      when 'ISERROR' then
        begin
          value = evaluate(arguments.fetch(0))
          value.is_a?(ReferenceValues) ? value.values.any? { |item| item.is_a?(FormulaError) } : value.is_a?(FormulaError)
        rescue FormulaError
          true
        end
      when 'ISNUMBER' then numeric?(evaluate(arguments.fetch(0)))
      when 'ISTEXT' then evaluate(arguments.fetch(0)).is_a?(String)
      when 'ISLOGICAL' then [true, false].include?(evaluate(arguments.fetch(0)))
      when 'SUM' then numbers(arguments).sum
      when 'AVERAGE'
        values = numbers(arguments)
        raise FormulaError.new('#DIV/0!') if values.empty?
        values.sum / values.size.to_f
      when 'COUNT' then numbers(arguments).size
      when 'COUNTA' then flat_arguments(arguments).reject { |value| value.nil? || value == '' }.size
      when 'COUNTBLANK' then flat_arguments(arguments).count { |value| value.nil? || value == '' }
      when 'MIN' then rank_number(arguments, :min)
      when 'MAX' then rank_number(arguments, :max)
      when 'LARGE' then ranked(arguments, -1)
      when 'SMALL' then ranked(arguments, 1)
      when 'MEDIAN' then median(numbers(arguments))
      when 'PERCENTILE' then percentile(numbers(arguments), scalar(evaluate(arguments.fetch(1))))
      when 'ABS' then scalar(evaluate(arguments.fetch(0))).abs
      when 'INT' then scalar(evaluate(arguments.fetch(0))).floor
      when 'TRUNC' then scalar(evaluate(arguments.fetch(0))).truncate
      when 'ROUND' then scalar(evaluate(arguments.fetch(0))).round(scalar(evaluate(arguments.fetch(1))))
      when 'FLOOR' then floor_multiple(arguments)
      when 'CEILING' then ceiling_multiple(arguments)
      when 'SQRT' then sqrt_value(scalar(evaluate(arguments.fetch(0))))
      when 'MOD' then mod_value(arguments)
      when 'POWER' then scalar(evaluate(arguments.fetch(0))) ** scalar(evaluate(arguments.fetch(1)))
      when 'LN' then Math.log(scalar(evaluate(arguments.fetch(0))))
      when 'LOG'
        number = scalar(evaluate(arguments.fetch(0)))
        base = arguments.size > 1 ? scalar(evaluate(arguments.fetch(1))) : 10
        Math.log(number, base)
      when 'EXP' then Math.exp(scalar(evaluate(arguments.fetch(0))))
      when 'LEN' then text(evaluate(arguments.fetch(0))).size
      when 'LEFT' then left_text(arguments)
      when 'RIGHT' then right_text(arguments)
      when 'MID' then text(evaluate(arguments.fetch(0)))[scalar(evaluate(arguments.fetch(1))) - 1, scalar(evaluate(arguments.fetch(2)))]
      when 'UPPER' then text(evaluate(arguments.fetch(0))).upcase
      when 'LOWER' then text(evaluate(arguments.fetch(0))).downcase
      when 'CONCAT', 'CONCATENATE' then arguments.map { |argument| text(evaluate(argument)) }.join
      when 'DATE' then
        Date.new(scalar(evaluate(arguments.fetch(0))),
                 scalar(evaluate(arguments.fetch(1))),
                 scalar(evaluate(arguments.fetch(2))))
      when 'YEAR' then date_part(arguments, :year)
      when 'MONTH' then date_part(arguments, :month)
      when 'DAY' then date_part(arguments, :day)
      else raise ConditionalFormattingError.unsupported_formula("function #{name}")
      end
    rescue IndexError
      raise FormulaError.new('#VALUE!')
    end

    def flat_arguments(arguments)
      arguments.flat_map { |argument| flatten(evaluate(argument)) }
    end

    def flatten(value)
      return value.values if value.is_a?(ReferenceValues)
      raise value if value.is_a?(FormulaError)
      [value]
    end

    def numbers(arguments)
      flat_arguments(arguments).select { |value| numeric?(value) }.map { |value| scalar(value) }
    end

    def boolean(value)
      raise FormulaError.new('#VALUE!') unless value == true || value == false
      value
    end

    def ranked(arguments, direction)
      values = numbers([arguments.fetch(0)]).sort
      rank = scalar(evaluate(arguments.fetch(1))).to_i
      raise FormulaError.new('#NUM!') unless rank.between?(1, values.size)
      direction.negative? ? values[-rank] : values[rank - 1]
    end

    def rank_number(arguments, method)
      values = numbers(arguments)
      raise FormulaError.new('#NUM!') if values.empty?
      values.public_send(method)
    end

    def median(values)
      sorted = values.sort
      return 0 if sorted.empty?
      middle = sorted.size / 2
      sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    def percentile(values, rank)
      sorted = values.sort
      position = rank * (sorted.size - 1)
      low = position.floor
      high = position.ceil
      sorted[low] + ((sorted[high] - sorted[low]) * (position - low))
    end

    def floor_multiple(arguments)
      number = scalar(evaluate(arguments.fetch(0)))
      multiple = arguments.size > 1 ? scalar(evaluate(arguments.fetch(1))) : 1
      (number / multiple).floor * multiple
    end

    def ceiling_multiple(arguments)
      number = scalar(evaluate(arguments.fetch(0)))
      multiple = arguments.size > 1 ? scalar(evaluate(arguments.fetch(1))) : 1
      (number / multiple).ceil * multiple
    end

    def sqrt_value(number)
      raise FormulaError.new('#NUM!') if number.negative?
      Math.sqrt(number)
    end

    def mod_value(arguments)
      number = scalar(evaluate(arguments.fetch(0)))
      divisor = scalar(evaluate(arguments.fetch(1)))
      raise FormulaError.new('#DIV/0!') if divisor.zero?
      number % divisor
    end

    def left_text(arguments)
      string = text(evaluate(arguments.fetch(0)))
      length = arguments.size > 1 ? scalar(evaluate(arguments.fetch(1))).to_i : 1
      string[0, length]
    end

    def right_text(arguments)
      string = text(evaluate(arguments.fetch(0)))
      length = arguments.size > 1 ? scalar(evaluate(arguments.fetch(1))).to_i : 1
      string[-length, length] || string
    end

    def date_part(arguments, method)
      value = evaluate(arguments.fetch(0))
      raise FormulaError.new('#VALUE!') unless value.respond_to?(method)
      value.public_send(method)
    end
  end

  module LegacyWorksheet
    def evaluate_conditional_formatting(row, column = nil, value_provider = nil, &block)
      if value_provider.nil? && column.respond_to?(:call)
        value_provider = column
        column = nil
      end
      value_provider ||= block
      ConditionalFormattingEvaluator.new(self, value_provider).evaluate(row, column)
    end
  end
end
