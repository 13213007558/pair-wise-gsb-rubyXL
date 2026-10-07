# frozen_string_literal: true

require 'rubyXL/objects/worksheet'
require 'rubyXL/objects/stylesheet'

module RubyXL
  # Range-level evaluation of worksheet conditional formatting.
  #
  # For every cell in a given range the evaluator determines which conditional
  # formatting rules match and merges the matching differential styles (dxf)
  # on top of the cell's base style, producing the effective style Excel
  # would render. This is mainly useful when exporting a workbook to formats
  # that have no notion of conditional formatting.
  #
  # Supported rule types: +cellIs+, +expression+, +duplicateValues+, +top10+
  # and +colorScale+. Formulas are limited to numbers, string and boolean
  # literals, comparisons, arithmetic, boolean combinations (AND/OR/NOT) and
  # cell references. Anything outside that subset (other functions, ranges,
  # references to other sheets, ...) is reported as unevaluatable and is
  # never silently treated as +false+.
  module ConditionalFormattingEvaluation
    # Raised when a formula or a rule cannot be evaluated with the supported subset.
    class UnevaluatableError < StandardError; end

    # Value coercion and comparison helpers shared by the formula evaluator
    # and the rule matchers. Follows Excel semantics: blanks coerce to the
    # counterpart's type (0, "" or FALSE); ordering is number < text < logical.
    module Helpers
      module_function

      def to_number(value)
        case value
        when Numeric then value
        when nil then 0
        when true then 1
        when false then 0
        when String then
          stripped = value.strip
          unless stripped.match?(%r{^[+-]?([0-9]+([.][0-9]+)?|[.][0-9]+)([eE][+-]?[0-9]+)?$})
            raise UnevaluatableError, "cannot convert #{value.inspect} to a number"
          end

          stripped.match?(%r{[.eE]}) ? stripped.to_f : stripped.to_i
        else
          raise UnevaluatableError, "cannot convert #{value.inspect} to a number"
        end
      end

      def truthy?(value)
        case value
        when true, false then value
        when Numeric then !value.zero?
        when nil then false
        when String then
          case value.strip.upcase
          when 'TRUE' then true
          when 'FALSE' then false
          else raise UnevaluatableError, "cannot interpret #{value.inspect} as a boolean"
          end
        else
          raise UnevaluatableError, "cannot interpret #{value.inspect} as a boolean"
        end
      end

      # Excel-style three-way comparison. Returns -1, 0 or 1.
      def excel_compare(left, right)
        left = coerce_blank(left, right)
        right = coerce_blank(right, left)
        return 0 if left.nil? && right.nil?

        left_rank = type_rank(left)
        right_rank = type_rank(right)
        return left_rank <=> right_rank unless left_rank == right_rank

        case left
        when Numeric then left <=> right
        when String then left.downcase <=> right.downcase
        else (left ? 1 : 0) <=> (right ? 1 : 0)
        end
      end

      def coerce_blank(value, counterpart)
        return value unless value.nil?

        case counterpart
        when Numeric then 0
        when String then ''
        when true, false then false
        end
      end

      def type_rank(value)
        case value
        when Numeric then 0
        when String then 1
        when true, false then 2
        else 3
        end
      end
    end

    # Recursive-descent parser for the supported formula subset:
    # numbers, "strings", TRUE/FALSE, cell references (A1, $A$1, Sheet!A1),
    # arithmetic (+ - * / ^), postfix %, comparisons (= <> < <= > >=),
    # parentheses and AND/OR/NOT boolean combinations.
    module FormulaParser
      Token = Struct.new(:type, :value)

      TOKENIZER = %r{[ ]*(?:(?<num>[0-9]+(?:[.][0-9]+)?(?:[eE][+-]?[0-9]+)?|[.][0-9]+(?:[eE][+-]?[0-9]+)?)|(?<str>"(?:[^"]|"")*")|(?:(?<sheet>'(?:[^']|'')+'|[A-Za-z_][A-Za-z0-9_.]*)!)?(?<ref>[$]?[A-Za-z]{1,3}[$]?[0-9]+)(?![0-9A-Za-z_(])|(?<ident>[A-Za-z_][A-Za-z0-9_.]*)|(?<op><=|>=|<>|[=<>+*/^&%(),:-]))}.freeze

      COMPARISON_OPERATORS = %w{= <> < <= > >=}.freeze

      def self.parse(expression)
        str = expression.to_s.strip
        str = str[1..-1].to_s.strip if str.start_with?('=')
        raise UnevaluatableError, 'formula is empty' if str.empty?

        Parser.new(tokenize(str)).parse
      end

      def self.tokenize(str)
        tokens = []
        pos = 0
        while pos < str.length
          match = TOKENIZER.match(str, pos)
          if match.nil? || match.begin(0) != pos
            raise UnevaluatableError, "cannot tokenize formula near #{str[pos..-1].inspect}"
          end

          pos = match.end(0)
          if match[:num]
            text = match[:num]
            tokens << Token.new(:num, text.match?(%r{[.eE]}) ? text.to_f : text.to_i)
          elsif match[:str]
            tokens << Token.new(:str, match[:str][1..-2].gsub('""', '"'))
          elsif match[:ref]
            tokens << Token.new(:ref, parse_ref(match[:ref], match[:sheet]))
          elsif match[:ident]
            tokens << Token.new(:ident, match[:ident].upcase)
          else
            tokens << Token.new(:op, match[:op])
          end
        end
        tokens
      end

      def self.parse_ref(ref_str, sheet)
        match = ref_str.match(%r{^([$]?)([A-Za-z]{1,3})([$]?)([0-9]+)$})
        raise UnevaluatableError, "unsupported reference #{ref_str.inspect}" if match.nil?

        sheet_name = nil
        if sheet
          sheet_name = sheet.start_with?("'") ? sheet[1..-2].gsub("''", "'") : sheet
        end
        {
          :sheet => sheet_name,
          :row => match[4].to_i - 1,
          :col => column_index(match[2]),
          :row_abs => match[3] == '$',
          :col_abs => match[1] == '$'
        }
      end

      def self.column_index(letters)
        letters.upcase.each_byte.reduce(0) { |acc, byte| acc * 26 + (byte - 64) } - 1
      end

      # LL parser over the token stream produced by FormulaParser.tokenize.
      class Parser
        def initialize(tokens)
          @tokens = tokens
          @pos = 0
        end

        def parse
          node = parse_comparison
          unless @pos == @tokens.length
            raise UnevaluatableError, "unsupported or misplaced token #{@tokens[@pos].value.inspect}"
          end

          node
        end

        private

        def current
          @tokens[@pos]
        end

        def current_op
          token = current
          token && token.type == :op ? token.value : nil
        end

        def advance
          token = @tokens[@pos]
          @pos += 1
          token
        end

        def expect_op(op)
          raise UnevaluatableError, "expected #{op.inspect}" unless current_op == op

          advance
        end

        def parse_comparison
          left = parse_additive
          while COMPARISON_OPERATORS.include?(current_op)
            op = advance.value
            left = [:cmp, op, left, parse_additive]
          end
          left
        end

        def parse_additive
          left = parse_multiplicative
          while %w{+ -}.include?(current_op)
            op = advance.value
            left = [:arith, op, left, parse_multiplicative]
          end
          left
        end

        def parse_multiplicative
          left = parse_unary
          while %w{* / ^}.include?(current_op)
            op = advance.value
            left = [:arith, op, left, parse_unary]
          end
          left
        end

        def parse_unary
          case current_op
          when '-'
            advance
            [:neg, parse_unary]
          when '+'
            advance
            parse_unary
          else
            parse_postfix
          end
        end

        def parse_postfix
          node = parse_primary
          while current_op == '%'
            advance
            node = [:percent, node]
          end
          node
        end

        def parse_primary
          token = current
          raise UnevaluatableError, 'unexpected end of formula' if token.nil?

          case token.type
          when :num
            advance
            [:num, token.value]
          when :str
            advance
            [:str, token.value]
          when :ref
            advance
            [:ref, token.value]
          when :ident
            parse_ident
          else
            if token.type == :op && token.value == '('
              advance
              node = parse_comparison
              expect_op(')')
              node
            else
              raise UnevaluatableError, "unexpected token #{token.value.inspect}"
            end
          end
        end

        def parse_ident
          name = advance.value
          unless current_op == '('
            case name
            when 'TRUE' then return [:bool, true]
            when 'FALSE' then return [:bool, false]
            else
              raise UnevaluatableError, "unsupported name #{name.inspect} (named ranges are not supported)"
            end
          end

          advance # consume '('
          args = []
          unless current_op == ')'
            loop do
              args << parse_comparison
              break unless current_op == ','

              advance
            end
          end
          expect_op(')')
          [:call, name, args]
        end
      end
    end

    # Evaluates a parsed formula AST against a context object that responds
    # to +cell_value(row, col)+ and +sheet_name+. Relative references are
    # shifted by (+d_row+, +d_col+) - the offset of the evaluated cell from
    # the top-left cell (anchor) of its conditional formatting range.
    class FormulaEvaluator
      def initialize(context)
        @context = context
      end

      def evaluate(node, d_row = 0, d_col = 0)
        case node[0]
        when :num, :str, :bool then node[1]
        when :ref then evaluate_ref(node[1], d_row, d_col)
        when :neg then -Helpers.to_number(evaluate(node[1], d_row, d_col))
        when :percent then Helpers.to_number(evaluate(node[1], d_row, d_col)) / 100.0
        when :arith then evaluate_arith(node[1], node[2], node[3], d_row, d_col)
        when :cmp then evaluate_comparison(node[1], node[2], node[3], d_row, d_col)
        when :call then evaluate_call(node[1], node[2], d_row, d_col)
        else raise UnevaluatableError, "unsupported formula construct #{node[0].inspect}"
        end
      end

      private

      def evaluate_ref(ref, d_row, d_col)
        sheet = ref[:sheet]
        context_sheet = @context.sheet_name
        if sheet && context_sheet && sheet.casecmp(context_sheet.to_s) != 0
          raise UnevaluatableError, "reference to another sheet #{sheet.inspect} is not supported"
        end

        row = ref[:row_abs] ? ref[:row] : ref[:row] + d_row
        col = ref[:col_abs] ? ref[:col] : ref[:col] + d_col
        return nil if row.negative? || col.negative?
        return nil if row >= RubyXL::Reference::ROW_MAX || col >= RubyXL::Reference::COL_MAX

        @context.cell_value(row, col)
      end

      def evaluate_arith(op, left_node, right_node, d_row, d_col)
        left = Helpers.to_number(evaluate(left_node, d_row, d_col))
        right = Helpers.to_number(evaluate(right_node, d_row, d_col))
        case op
        when '+' then left + right
        when '-' then left - right
        when '*' then left * right
        when '/'
          raise UnevaluatableError, 'division by zero' if right.zero?

          left.to_f / right
        when '^' then left**right
        else raise UnevaluatableError, "unsupported operator #{op.inspect}"
        end
      end

      def evaluate_comparison(op, left_node, right_node, d_row, d_col)
        cmp = Helpers.excel_compare(evaluate(left_node, d_row, d_col), evaluate(right_node, d_row, d_col))
        case op
        when '=' then cmp.zero?
        when '<>' then !cmp.zero?
        when '<' then cmp.negative?
        when '<=' then cmp <= 0
        when '>' then cmp.positive?
        when '>=' then cmp >= 0
        else raise UnevaluatableError, "unsupported comparison #{op.inspect}"
        end
      end

      def evaluate_call(name, args, d_row, d_col)
        case name
        when 'AND'
          raise UnevaluatableError, 'AND requires at least one argument' if args.empty?

          args.all? { |arg| Helpers.truthy?(evaluate(arg, d_row, d_col)) }
        when 'OR'
          raise UnevaluatableError, 'OR requires at least one argument' if args.empty?

          args.any? { |arg| Helpers.truthy?(evaluate(arg, d_row, d_col)) }
        when 'NOT'
          raise UnevaluatableError, 'NOT requires exactly one argument' unless args.size == 1

          !Helpers.truthy?(evaluate(args.first, d_row, d_col))
        else
          raise UnevaluatableError, "unsupported function #{name}"
        end
      end
    end

    # The effective style of a single cell: the base style resolved from the
    # cell's xf record, merged with the differential styles of all matching
    # rules (higher-priority rules win per property). Also explains which
    # rules matched, which properties each of them actually contributed, and
    # which rules could not be evaluated.
    class EffectiveStyle
      FONT_ATTRIBUTES = %i{name charset family b i strike outline shadow condense extend color sz u vert_align scheme}.freeze
      ALIGNMENT_ATTRIBUTES = %i{horizontal vertical text_rotation wrap_text indent relative_indent justify_last_line shrink_to_fit reading_order}.freeze
      PROTECTION_ATTRIBUTES = %i{locked hidden}.freeze

      attr_accessor :num_fmt_id, :font, :fill, :border, :alignment, :protection
      attr_reader :base_style_index, :applied_rules, :unevaluatable_rules

      def initialize(base_style_index:, num_fmt_id:, font:, fill:, border:, alignment:, protection:)
        @base_style_index = base_style_index
        @num_fmt_id = num_fmt_id
        @font = font
        @fill = fill
        @border = border
        @alignment = alignment
        @protection = protection
        @applied_rules = []
        @unevaluatable_rules = []
        @writable_components = {}
      end

      # Rules that actually contributed at least one style property.
      def contributing_rules
        applied_rules.select { |entry| entry[:properties].any? }
      end

      def font_color
        font && font.color && font.color.rgb
      end

      def fill_color
        pattern = fill && fill.pattern_fill
        pattern && pattern.fg_color && pattern.fg_color.rgb
      end

      def to_h
        {
          :base_style_index => base_style_index,
          :num_fmt_id => num_fmt_id,
          :font => font_summary,
          :fill => fill_summary,
          :applied_rules => applied_rules.map(&:dup),
          :unevaluatable_rules => unevaluatable_rules.map(&:dup)
        }
      end

      # Returns a writable (unshared) copy of the given style component,
      # duplicating the base object on first access so shared stylesheet
      # objects are never mutated.
      def ensure_writable(component, klass)
        unless @writable_components[component]
          current = send(component)
          send(:"#{component}=", current ? current.dup : klass.new)
          @writable_components[component] = true
        end
        send(component)
      end

      private

      def font_summary
        return nil if font.nil?

        {
          :name => font.name && font.name.val,
          :size => font.sz && font.sz.val,
          :bold => !!(font.b && font.b.val),
          :italic => !!(font.i && font.i.val),
          :underline => font.u && font.u.val,
          :strikethrough => !!(font.strike && font.strike.val),
          :color => font_color
        }
      end

      def fill_summary
        pattern = fill && fill.pattern_fill
        return nil if pattern.nil?

        {
          :pattern_type => pattern.pattern_type,
          :fg_color => pattern.fg_color && pattern.fg_color.rgb,
          :bg_color => pattern.bg_color && pattern.bg_color.rgb
        }
      end
    end

    # Maps cell addresses ("A1") to their EffectiveStyle.
    class Result
      include Enumerable

      def initialize
        @cells = {}
      end

      def []=(address, style)
        @cells[address] = style
      end

      def [](address)
        case address
        when String then @cells[address.upcase]
        when Array then @cells[self.class.address(address[0], address[1])]
        when RubyXL::Reference then @cells[self.class.address(address.first_row, address.first_col)]
        end
      end

      def each(&block)
        @cells.each(&block)
      end

      def cells
        @cells.dup
      end

      def to_h
        @cells.transform_values(&:to_h)
      end

      def self.address(row, col)
        "#{col_name(col)}#{row + 1}"
      end

      def self.col_name(index)
        name = +''
        current = index
        loop do
          name.prepend((65 + (current % 26)).chr)
          current = (current / 26) - 1
          break if current.negative?
        end
        name
      end
    end

    # Evaluates the conditional formatting rules of one worksheet over a
    # range of cells. Use Worksheet#evaluate_conditional_formatting rather
    # than instantiating this class directly.
    class Evaluator
      def initialize(worksheet)
        @worksheet = worksheet
        @workbook = worksheet.workbook
        @stylesheet = @workbook && @workbook.stylesheet
        @formula_cache = {}
        @domain_cache = {}
      end

      def sheet_name
        @worksheet.sheet_name
      end

      def cell_value(row, col)
        cell = cell_at(row, col)
        cell.nil? ? nil : cell.value
      rescue StandardError
        nil
      end

      # Evaluates all conditional formatting rules over +range+ (nil = every
      # range covered by conditional formatting) and returns a Result.
      def evaluate(range = nil)
        blocks = conditional_formatting_blocks
        result = Result.new
        normalize_ranges(range, blocks).each do |ref|
          ref.row_range.each do |row|
            ref.col_range.each do |col|
              result[Result.address(row, col)] = evaluate_cell(row, col, blocks)
            end
          end
        end
        result
      end

      private

      def cell_at(row, col)
        sheet_data = @worksheet.sheet_data
        row_obj = sheet_data && sheet_data.rows[row]
        cell = row_obj && row_obj.cells && row_obj.cells[col]
        cell.is_a?(RubyXL::Cell) ? cell : nil
      end

      def conditional_formatting_blocks
        blocks = @worksheet.conditional_formatting
        blocks ? blocks.to_a : []
      end

      def block_ranges(cf)
        sqref = cf.sqref
        sqref = RubyXL::Sqref.new(sqref) if sqref.is_a?(String)
        sqref ? sqref.to_a : []
      end

      def normalize_ranges(range, blocks)
        case range
        when nil then blocks.flat_map { |cf| block_ranges(cf) }
        when RubyXL::Reference then [range]
        when String then [RubyXL::Reference.new(range)]
        when Array then range.flat_map { |item| normalize_ranges(item, blocks) }
        else raise ArgumentError, "unsupported range #{range.inspect}"
        end
      end

      def evaluate_cell(row, col, blocks)
        style = build_base_style(row, col)
        claimed = {}
        applications_for(row, col, blocks).each do |app|
          matched = apply_rule(style, app, row, col, claimed)
          break if matched && app[:rule].stop_if_true
        end
        style
      end

      # All (rule, anchor range) pairs covering the given cell, sorted by
      # rule priority (ascending = highest priority first, ties keep the
      # document order).
      def applications_for(row, col, blocks)
        applications = []
        blocks.each do |cf|
          rules = cf.cf_rule || []
          next if rules.empty?

          block_ranges(cf).each do |ref|
            next unless ref.row_range.cover?(row) && ref.col_range.cover?(col)

            rules.each do |rule|
              applications << {
                :cf => cf, :rule => rule,
                :anchor_row => ref.first_row, :anchor_col => ref.first_col
              }
            end
          end
        end
        applications.each_with_index.sort_by { |app, idx| [app[:rule].priority || 0, idx] }.map(&:first)
      end

      # Returns true when the rule matched (only dxf-based rules can stop
      # evaluation via stopIfTrue).
      def apply_rule(style, app, row, col, claimed)
        rule = app[:rule]
        return apply_color_scale(style, app, row, col, claimed) if rule.type == 'colorScale'

        unless %w{cellIs expression duplicateValues top10}.include?(rule.type)
          style.unevaluatable_rules << {
            :priority => rule.priority, :type => rule.type,
            :reason => "unsupported rule type #{rule.type.inspect}"
          }
          return false
        end

        return false unless rule_matches?(app, row, col)

        style.applied_rules << {
          :priority => rule.priority,
          :type => rule.type,
          :dxf_id => rule.dxf_id,
          :properties => merge_dxf(style, rule, claimed),
          :stop_if_true => !!rule.stop_if_true
        }
        true
      rescue UnevaluatableError => e
        style.unevaluatable_rules << {
          :priority => rule.priority, :type => rule.type, :reason => e.message
        }
        false
      end

      def rule_matches?(app, row, col)
        rule = app[:rule]
        d_row = row - app[:anchor_row]
        d_col = col - app[:anchor_col]
        case rule.type
        when 'cellIs' then cell_is_matches?(rule, row, col, d_row, d_col)
        when 'expression' then expression_matches?(rule, d_row, d_col)
        when 'duplicateValues' then duplicate_matches?(app, row, col)
        when 'top10' then top10_matches?(app, row, col)
        else false
        end
      end

      def cell_is_matches?(rule, row, col, d_row, d_col)
        formulas = rule.formulas || []
        raise UnevaluatableError, 'cellIs rule has no formula' if formulas.empty?

        values = formulas.map { |f| evaluate_formula(f.expression, d_row, d_col) }
        target = cell_value(row, col)
        case rule.operator
        when 'lessThan' then Helpers.excel_compare(target, values[0]) < 0
        when 'lessThanOrEqual' then Helpers.excel_compare(target, values[0]) <= 0
        when 'equal' then Helpers.excel_compare(target, values[0]).zero?
        when 'notEqual' then !Helpers.excel_compare(target, values[0]).zero?
        when 'greaterThanOrEqual' then Helpers.excel_compare(target, values[0]) >= 0
        when 'greaterThan' then Helpers.excel_compare(target, values[0]) > 0
        when 'between', 'notBetween'
          if values.size < 2
            raise UnevaluatableError, "operator #{rule.operator} requires two formulas"
          end

          inside = Helpers.excel_compare(target, values[0]) >= 0 &&
                   Helpers.excel_compare(target, values[1]) <= 0
          rule.operator == 'between' ? inside : !inside
        else
          raise UnevaluatableError, "unsupported cellIs operator #{rule.operator.inspect}"
        end
      end

      def expression_matches?(rule, d_row, d_col)
        formulas = rule.formulas || []
        raise UnevaluatableError, 'expression rule has no formula' if formulas.empty?

        Helpers.truthy?(evaluate_formula(formulas.first.expression, d_row, d_col))
      end

      def duplicate_matches?(app, row, col)
        key = duplicate_key(cell_value(row, col))
        !key.nil? && domain_for(app[:cf])[:counts][key] > 1
      end

      def top10_matches?(app, row, col)
        value = cell_value(row, col)
        return false unless value.is_a?(Numeric)

        rule = app[:rule]
        numerics = domain_for(app[:cf])[:numerics]
        limit = rule.rank || 10
        limit = (numerics.size * limit / 100.0).ceil if rule.percent
        return false if limit <= 0

        rank = if rule.bottom
                 1 + numerics.count { |v| v < value }
               else
                 1 + numerics.count { |v| v > value }
               end
        rank <= limit
      end

      def apply_color_scale(style, app, row, col, claimed)
        rule = app[:rule]
        scale = rule.color_scale
        raise UnevaluatableError, 'colorScale rule has no colorScale definition' if scale.nil?

        value = cell_value(row, col)
        return false unless value.is_a?(Numeric)

        cfvos = scale.cfvo || []
        colors = (scale.color || []).map { |c| color_to_rgb(c) }
        if cfvos.size < 2 || colors.size < cfvos.size
          raise UnevaluatableError, 'colorScale requires at least two thresholds with matching colors'
        end

        numerics = domain_for(app[:cf])[:numerics]
        thresholds = cfvos.map { |cfvo| cfvo_threshold(cfvo, numerics, app, row, col) }
        if thresholds.any?(&:nil?)
          raise UnevaluatableError, 'colorScale thresholds could not be determined'
        end

        hex = interpolate_color(thresholds, colors, value)
        properties = []
        unless claimed[:fill]
          claimed[:fill] = true
          style.fill = solid_fill(hex)
          properties << :fill
        end
        style.applied_rules << {
          :priority => rule.priority,
          :type => rule.type,
          :dxf_id => rule.dxf_id,
          :properties => properties,
          :stop_if_true => false,
          :color => hex
        }
        false
      end

      def cfvo_threshold(cfvo, numerics, app, row, col)
        case cfvo.type
        when 'min', 'autoMin' then numerics.min
        when 'max', 'autoMax' then numerics.max
        when 'num' then Float(cfvo.val.to_s)
        when 'percent'
          min = numerics.min
          max = numerics.max
          return nil if min.nil? || max.nil?

          min + (max - min) * Float(cfvo.val.to_s) / 100.0
        when 'percentile'
          return nil if numerics.empty?

          percentile(numerics.sort, Float(cfvo.val.to_s))
        when 'formula'
          Helpers.to_number(evaluate_formula(cfvo.val.to_s, row - app[:anchor_row], col - app[:anchor_col]))
        else
          raise UnevaluatableError, "unsupported colorScale threshold type #{cfvo.type.inspect}"
        end
      rescue ArgumentError, TypeError
        raise UnevaluatableError, "invalid colorScale threshold value #{cfvo.val.inspect}"
      end

      def percentile(sorted_values, pct)
        return nil if sorted_values.empty?
        return sorted_values.first.to_f if sorted_values.size == 1

        rank = pct / 100.0 * (sorted_values.size - 1)
        lower = sorted_values[rank.floor]
        upper = sorted_values[rank.ceil]
        lower + (upper - lower) * (rank - rank.floor)
      end

      def color_to_rgb(color)
        rgb = color && color.rgb
        raise UnevaluatableError, 'only rgb colors are supported in colorScale' if rgb.nil?

        hex = rgb.is_a?(Integer) ? format('%08X', rgb) : rgb.to_s.upcase
        hex = hex[-6, 6] || hex
        [hex[0, 2], hex[2, 2], hex[4, 2]].map { |pair| pair.to_i(16) }
      end

      def interpolate_color(thresholds, colors, value)
        rgb =
          if value <= thresholds.first then colors.first
          elsif value >= thresholds.last then colors.last
          else
            found = colors.last
            (0...(thresholds.size - 1)).each do |i|
              low = thresholds[i]
              high = thresholds[i + 1]
              next unless value <= high

              t = high == low ? 0.0 : (value - low).to_f / (high - low)
              found = blend_colors(colors[i], colors[i + 1], t)
              break
            end
            found
          end
        format('FF%02X%02X%02X', *rgb)
      end

      def blend_colors(rgb1, rgb2, t)
        (0..2).map { |i| (rgb1[i] + (rgb2[i] - rgb1[i]) * t).round.clamp(0, 255) }
      end

      def solid_fill(hex)
        RubyXL::Fill.new(
          :pattern_fill => RubyXL::PatternFill.new(
            :pattern_type => 'solid',
            :fg_color => RubyXL::Color.new(:rgb => hex),
            :bg_color => RubyXL::Color.new(:rgb => hex)
          )
        )
      end

      def evaluate_formula(expression, d_row, d_col)
        ast = @formula_cache[expression]
        if ast.nil?
          ast = FormulaParser.parse(expression.to_s)
          @formula_cache[expression] = ast
        end
        FormulaEvaluator.new(self).evaluate(ast, d_row, d_col)
      rescue UnevaluatableError => e
        raise UnevaluatableError, "cannot evaluate formula #{expression.inspect}: #{e.message}"
      end

      # Values of all cells covered by the block's sqref, shared by the
      # duplicateValues, top10 and colorScale computations.
      def domain_for(cf)
        @domain_cache[cf.object_id] ||= begin
          values = []
          block_ranges(cf).each do |ref|
            ref.row_range.each do |row|
              ref.col_range.each do |col|
                values << cell_value(row, col)
              end
            end
          end
          counts = Hash.new(0)
          values.each do |value|
            key = duplicate_key(value)
            counts[key] += 1 unless key.nil?
          end
          {
            :numerics => values.select { |v| v.is_a?(Numeric) },
            :counts => counts
          }
        end
      end

      def duplicate_key(value)
        case value
        when nil then nil
        when String then value.empty? ? nil : [:text, value.downcase]
        when Numeric then [:number, value.to_f]
        when true, false then [:bool, value]
        end
      end

      # Merges the dxf of a matched rule into the effective style. Only the
      # properties the dxf declares are applied, and only if no higher
      # priority rule has claimed them yet. Returns the list of property
      # keys that were actually contributed.
      def merge_dxf(style, rule, claimed)
        dxf = dxf_for(rule)
        return [] if dxf.nil?

        contributed = []

        num_fmt = dxf.num_fmt
        if num_fmt && !claimed[:num_fmt]
          claimed[:num_fmt] = true
          style.num_fmt_id = num_fmt.num_fmt_id
          contributed << :num_fmt
        end

        if dxf.font
          EffectiveStyle::FONT_ATTRIBUTES.each do |attr|
            value = dxf.font.send(attr)
            next if value.nil?

            key = :"font.#{attr}"
            next if claimed[key]

            claimed[key] = true
            style.ensure_writable(:font, RubyXL::Font).send(:"#{attr}=", value)
            contributed << key
          end
        end

        if dxf.fill && !claimed[:fill]
          claimed[:fill] = true
          style.fill = dxf.fill
          contributed << :fill
        end

        if dxf.border && !claimed[:border]
          claimed[:border] = true
          style.border = dxf.border
          contributed << :border
        end

        if dxf.alignment
          EffectiveStyle::ALIGNMENT_ATTRIBUTES.each do |attr|
            value = dxf.alignment.send(attr)
            next if value.nil?

            key = :"alignment.#{attr}"
            next if claimed[key]

            claimed[key] = true
            style.ensure_writable(:alignment, RubyXL::Alignment).send(:"#{attr}=", value)
            contributed << key
          end
        end

        if dxf.protection
          EffectiveStyle::PROTECTION_ATTRIBUTES.each do |attr|
            value = dxf.protection.send(attr)
            next if value.nil?

            key = :"protection.#{attr}"
            next if claimed[key]

            claimed[key] = true
            style.ensure_writable(:protection, RubyXL::Protection).send(:"#{attr}=", value)
            contributed << key
          end
        end

        contributed
      end

      def dxf_for(rule)
        return nil if rule.dxf_id.nil?

        dxfs = @stylesheet && @stylesheet.dxfs
        dxfs && dxfs[rule.dxf_id]
      end

      def build_base_style(row, col)
        cell = cell_at(row, col)
        style_index = cell ? (cell.style_index || 0) : 0
        xf = @stylesheet && @stylesheet.cell_xfs && @stylesheet.cell_xfs[style_index]
        EffectiveStyle.new(
          :base_style_index => style_index,
          :num_fmt_id => xf && xf.num_fmt_id,
          :font => resolve_style(@stylesheet && @stylesheet.fonts, xf && xf.font_id),
          :fill => resolve_style(@stylesheet && @stylesheet.fills, xf && xf.fill_id),
          :border => resolve_style(@stylesheet && @stylesheet.borders, xf && xf.border_id),
          :alignment => xf && xf.alignment,
          :protection => xf && xf.protection
        )
      end

      def resolve_style(collection, id)
        return nil if collection.nil? || id.nil?

        collection[id]
      end
    end
  end
end

module RubyXL
  class Worksheet
    # Evaluates conditional formatting over +range+ (a reference string like
    # "A1:C10", a RubyXL::Reference, an Array of those, or +nil+ for every
    # range covered by conditional formatting on this worksheet) and returns
    # a RubyXL::ConditionalFormattingEvaluation::Result mapping each cell
    # address to its EffectiveStyle.
    def evaluate_conditional_formatting(range = nil)
      RubyXL::ConditionalFormattingEvaluation::Evaluator.new(self).evaluate(range)
    end
  end
end
