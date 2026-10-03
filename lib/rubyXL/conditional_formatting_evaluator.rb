# frozen_string_literal: true

module RubyXL
  # Read-only evaluator for worksheet conditional formatting.
  #
  # Given a cell coordinate and a read-only value provider, computes the
  # effective conditional format for that cell: which rules match and the
  # merged differential style they produce. Nothing is written back to the
  # workbook; the worksheet, stylesheet and cells are only ever read.
  #
  # Supported rule types (+SUPPORTED_RULE_TYPES+):
  # * +cellIs+ (operators: lessThan, lessThanOrEqual, equal, notEqual,
  #   greaterThanOrEqual, greaterThan, between, notBetween)
  # * +expression+
  # * +duplicateValues+ / +uniqueValues+ (blank cells are ignored)
  # * +top10+ (including +bottom+ and +percent+ variants; tied values at the
  #   threshold are all included)
  # * +colorScale+ (cfvo types: min, max, autoMin, autoMax, num, percent,
  #   percentile, formula; colors must use explicit +rgb+)
  #
  # Any other rule type (+dataBar+, +iconSet+, +aboveAverage+, text/date and
  # blank/error rules, ...) is unsupported and raises +UnsupportedRuleError+
  # instead of silently evaluating to +false+.
  #
  # Formula subset (+SUPPORTED_FUNCTIONS+, +SUPPORTED_OPERATORS+):
  # numeric and string literals, TRUE/FALSE, single-cell A1 references with
  # optional $ anchors, arithmetic (+, -, *, /, ^), concatenation (&),
  # comparisons (=, <>, <, <=, >, >=), percent postfix, parentheses, and the
  # functions AND, OR, NOT, ISBLANK, ISNUMBER, ISTEXT. Ranges, sheet-qualified
  # references, defined names and any other function raise
  # +UnsupportedRuleError+ or +FormulaError+.
  #
  # Relative references in formulas are resolved against the top-left cell
  # of the first range of the rule's sqref (as if the formula were copied
  # from that anchor cell to each evaluated cell) -- never against the
  # evaluated cell itself, which matters for multi-range sqrefs.
  #
  # Value provider protocol: any object responding to +value_at(row, col)+,
  # +call(row, col)+ or +[](row, col)+, returning the cell's value
  # (Numeric, String, true/false) or +nil+ for blank.
  # +WorksheetValueProvider+ reads values straight from a worksheet.
  #
  #   provider = RubyXL::ConditionalFormattingEvaluator::WorksheetValueProvider.new(worksheet)
  #   result = RubyXL::ConditionalFormattingEvaluator.new(worksheet, provider).evaluate('B5')
  #   result.matched?       # => true/false
  #   result.matched_rules  # => [RuleMatch, ...] in application (priority) order
  #   result.style          # => merged dxf properties, e.g.
  #                         #     { 'font' => { 'b' => true, 'color' => 'FFFF0000' },
  #                         #       'fill' => { 'rgb' => 'FF800080' } }
  class ConditionalFormattingEvaluator
    # Base error for conditional formatting evaluation failures.
    class Error < StandardError; end
    # Raised when a rule type, formula construct or style element is outside
    # the supported subset. Never swallowed: rules that cannot be computed
    # must not silently evaluate to false.
    class UnsupportedRuleError < Error; end
    # Raised when a formula cannot be parsed or evaluated.
    class FormulaError < Error; end

    SUPPORTED_RULE_TYPES = %w{cellIs expression duplicateValues uniqueValues top10 colorScale}.freeze
    UNSUPPORTED_RULE_TYPES = (RubyXL::ST_CfType - SUPPORTED_RULE_TYPES).freeze

    SUPPORTED_FUNCTIONS = %w{AND OR NOT ISBLANK ISNUMBER ISTEXT}.freeze
    SUPPORTED_OPERATORS = %w{= <> < <= > >= + - * / ^ & %}.freeze
    CELL_IS_OPERATORS = %w{lessThan lessThanOrEqual equal notEqual
                           greaterThanOrEqual greaterThan between notBetween}.freeze

    # Safety net against iterating degenerate ranges (e.g. entire columns).
    MAX_DOMAIN_CELLS = 2_000_000

    # Read-only value provider backed by a worksheet's current cell values.
    class WorksheetValueProvider
      def initialize(worksheet)
        @worksheet = worksheet
      end

      def value_at(row, col)
        row_obj = @worksheet.sheet_data[row]
        cell = row_obj && row_obj.cells[col]
        cell && cell.value
      end
    end

    # Information about a single rule that matched the evaluated cell.
    class RuleMatch
      attr_reader :rule, :range, :fill_color

      def initialize(rule, range, fill_color = nil)
        @rule = rule             # RubyXL::ConditionalFormattingRule
        @range = range           # RubyXL::Reference: the sqref range containing the cell
        @fill_color = fill_color # 'AARRGGBB' hex, colorScale rules only
      end

      def priority
        rule.priority
      end

      def stop_if_true?
        !!rule.stop_if_true
      end
    end

    # Outcome of evaluating one cell.
    class EvaluationResult
      attr_reader :row, :col, :matched_rules, :style

      def initialize(row, col, matched_rules, style)
        @row = row
        @col = col
        @matched_rules = matched_rules
        @style = style
      end

      def matched?
        !matched_rules.empty?
      end
    end

    def self.evaluate(worksheet, row_or_ref, col, value_provider)
      new(worksheet, value_provider).evaluate(row_or_ref, col)
    end

    def initialize(worksheet, value_provider)
      @worksheet = worksheet
      @fetch =
        if value_provider.respond_to?(:value_at) then value_provider.method(:value_at)
        elsif value_provider.respond_to?(:call) then value_provider
        elsif value_provider.respond_to?(:[]) then value_provider.method(:[])
        else
          raise ArgumentError,
                'value provider must respond to value_at(row, col), call(row, col) or [](row, col)'
        end
    end

    # Evaluate the conditional formats applying to the given cell.
    # Accepts zero-based (row, col) indices or an A1-style reference string.
    def evaluate(row_or_ref, col = nil)
      row, col =
        if row_or_ref.is_a?(String) then RubyXL::Reference.ref2ind(row_or_ref)[0, 2]
        else [row_or_ref, col]
        end

      matched_rules = []
      style = {}

      applicable_rules(row, col).each do |item|
        outcome = evaluate_rule(item, row, col)
        next unless outcome

        fill_color = outcome.is_a?(Hash) ? outcome[:fill_color] : nil
        matched_rules << RuleMatch.new(item[:rule], item[:range], fill_color)
        merge_rule_style(style, item[:rule], fill_color)
        break if item[:rule].stop_if_true
      end

      EvaluationResult.new(row, col, matched_rules, style)
    end

    private

    def fetch_value(row, col)
      @fetch.call(row, col)
    end

    # All (rule, containing range) pairs for the cell, in application order:
    # ascending priority, document order for ties.
    def applicable_rules(row, col)
      items = []
      (@worksheet.conditional_formatting || []).each do |cf|
        next if cf.sqref.nil?
        (cf.cf_rule || []).each do |rule|
          range = cf.sqref.find { |r| r.row_range.cover?(row) && r.col_range.cover?(col) }
          items << { :rule => rule, :range => range, :sqref => cf.sqref,
                     :anchor => cf.sqref.first } if range
        end
      end
      items.sort_by.with_index { |item, i| [item[:rule].priority || 0, i] }
    end

    # Returns false/nil when the rule does not match, true when it matches,
    # or { :fill_color => hex } for a matching colorScale rule.
    def evaluate_rule(item, row, col)
      case item[:rule].type
      when 'cellIs'                          then evaluate_cell_is(item, row, col)
      when 'expression'                      then evaluate_expression(item, row, col)
      when 'duplicateValues', 'uniqueValues' then evaluate_duplicates(item, row, col)
      when 'top10'                           then evaluate_top10(item, row, col)
      when 'colorScale'                      then evaluate_color_scale(item, row, col)
      else
        raise UnsupportedRuleError,
              "unsupported conditional formatting rule type #{item[:rule].type.inspect} " \
              "(supported: #{SUPPORTED_RULE_TYPES.join(', ')}; " \
              "unsupported: #{UNSUPPORTED_RULE_TYPES.join(', ')})"
      end
    end

    def evaluate_cell_is(item, row, col)
      rule = item[:rule]
      value = fetch_value(row, col)
      return false if value.nil? # Excel does not apply cellIs rules to blank cells

      operator = rule.operator
      unless CELL_IS_OPERATORS.include?(operator)
        raise UnsupportedRuleError, "unsupported cellIs operator #{operator.inspect} " \
                                    "(supported: #{CELL_IS_OPERATORS.join(', ')})"
      end

      operands = rule.formulas.map { |f| eval_formula(formula_text(f, rule), item[:anchor], row, col) }
      low = operands[0]
      cmp = compare_values(value, low)

      case operator
      when 'lessThan'           then cmp < 0
      when 'lessThanOrEqual'    then cmp <= 0
      when 'equal'              then cmp == 0
      when 'notEqual'           then cmp != 0
      when 'greaterThanOrEqual' then cmp >= 0
      when 'greaterThan'        then cmp > 0
      when 'between', 'notBetween'
        high = operands[1]
        raise UnsupportedRuleError, "cellIs #{operator} rule requires two formulas" if high.nil?
        inside = compare_values(value, low) >= 0 && compare_values(value, high) <= 0
        operator == 'between' ? inside : !inside
      end
    end

    def evaluate_expression(item, row, col)
      rule = item[:rule]
      to_bool(eval_formula(formula_text(rule.formulas.first, rule), item[:anchor], row, col))
    end

    def evaluate_duplicates(item, row, col)
      value = fetch_value(row, col)
      return false if value.nil? # blank cells are ignored by duplicate/unique rules

      key = duplicate_key(value)
      count = domain_values(item[:sqref]).count { |v| !v.nil? && duplicate_key(v) == key }
      item[:rule].type == 'duplicateValues' ? count > 1 : count == 1
    end

    def evaluate_top10(item, row, col)
      rule = item[:rule]
      value = fetch_value(row, col)
      return false unless value.is_a?(Numeric)

      numbers = domain_values(item[:sqref]).select { |v| v.is_a?(Numeric) }
      return false if numbers.empty?

      rank = rule.rank || 10
      count = rule.percent ? (numbers.size * rank / 100.0).ceil : rank
      count = 1 if count < 1
      count = numbers.size if count > numbers.size

      sorted = numbers.sort
      if rule.bottom then value <= sorted[count - 1]
      else value >= sorted[-count]
      end
    end

    def evaluate_color_scale(item, row, col)
      rule = item[:rule]
      value = fetch_value(row, col)
      return false unless value.is_a?(Numeric)

      scale = rule.color_scale
      raise UnsupportedRuleError, 'colorScale rule is missing its colorScale element' if scale.nil?

      cfvos = scale.cfvo
      colors = scale.color
      if cfvos.nil? || colors.nil? || cfvos.size < 2 || cfvos.size != colors.size
        raise UnsupportedRuleError,
              'colorScale requires at least two cfvo stops and an equal number of colors'
      end

      numbers = domain_values(item[:sqref]).select { |v| v.is_a?(Numeric) }
      stops = cfvos.map { |cfvo| cfvo_value(cfvo, numbers, item[:anchor], row, col) }
      rgb_colors = colors.map { |c| color_to_rgb(c) }

      # Sort stops ascending, keeping (stop, color) pairs together.
      pairs = stops.zip(rgb_colors).sort_by(&:first)
      hex = interpolate_color(pairs.map(&:first), pairs.map(&:last), value)
      { :fill_color => hex }
    end


    # --- colorScale helpers ---------------------------------------------------

    def cfvo_value(cfvo, numbers, anchor, row, col)
      case cfvo.type
      when 'min', 'autoMin' then domain_min(numbers, cfvo)
      when 'max', 'autoMax' then domain_max(numbers, cfvo)
      when 'num'            then Float(cfvo.val)
      when 'percent'
        min = domain_min(numbers, cfvo)
        min + (domain_max(numbers, cfvo) - min) * Float(cfvo.val) / 100.0
      when 'percentile'     then percentile(numbers, Float(cfvo.val))
      when 'formula'        then to_number(eval_formula(cfvo.val.to_s, anchor, row, col))
      else
        raise UnsupportedRuleError, "unsupported cfvo type #{cfvo.type.inspect}"
      end
    rescue ArgumentError, TypeError
      raise FormulaError, "invalid cfvo value #{cfvo.val.inspect} for type #{cfvo.type.inspect}"
    end

    def domain_min(numbers, cfvo)
      raise FormulaError, "cfvo type #{cfvo.type.inspect} requires numeric values in the range" if numbers.empty?
      numbers.min
    end

    def domain_max(numbers, cfvo)
      raise FormulaError, "cfvo type #{cfvo.type.inspect} requires numeric values in the range" if numbers.empty?
      numbers.max
    end

    # PERCENTILE.INC as used by Excel for percentile cfvo stops.
    def percentile(numbers, pct)
      raise FormulaError, 'percentile cfvo requires numeric values in the range' if numbers.empty?
      sorted = numbers.sort
      rank = pct / 100.0 * (sorted.size - 1)
      lower = sorted[rank.floor]
      upper = sorted[rank.ceil]
      lower + (upper - lower) * (rank - rank.floor)
    end

    def color_to_rgb(color)
      rgb = color.rgb
      if rgb.nil?
        raise UnsupportedRuleError,
              'colorScale colors must use explicit rgb values (theme/indexed colors are not supported)'
      end
      hex = rgb[-6, 6]
      [hex[0, 2], hex[2, 2], hex[4, 2]].map { |c| c.to_i(16) }
    end

    def interpolate_color(stops, colors, value)
      return to_hex(colors.first) if value <= stops.first
      return to_hex(colors.last) if value >= stops.last

      (0...stops.size - 1).each do |i|
        lo, hi = stops[i], stops[i + 1]
        next if value > hi
        return to_hex(colors[i + 1]) if hi == lo
        t = (value - lo).to_f / (hi - lo)
        return to_hex(colors[i].zip(colors[i + 1]).map { |a, b| (a + (b - a) * t).round })
      end
      to_hex(colors.last)
    end

    def to_hex(rgb)
      format('FF%02X%02X%02X', *rgb)
    end

    # --- domain values --------------------------------------------------------

    # Values of every cell in the rule's sqref (all ranges), blanks as nil.
    # Read-only: goes through the value provider only.
    def domain_values(sqref)
      total = sqref.sum { |r| (r.last_row - r.first_row + 1) * (r.last_col - r.first_col + 1) }
      if total > MAX_DOMAIN_CELLS
        raise UnsupportedRuleError, "sqref spans #{total} cells, too large to evaluate safely"
      end

      values = []
      sqref.each do |range|
        (range.first_row..range.last_row).each do |r|
          (range.first_col..range.last_col).each do |c|
            values << fetch_value(r, c)
          end
        end
      end
      values
    end

    def duplicate_key(value)
      case value
      when Numeric     then [:n, value]
      when String      then [:s, value.downcase]
      when true, false then [:b, value]
      else [:o, value.to_s]
      end
    end

    # --- formula evaluation ---------------------------------------------------

    def formula_text(formula, rule)
      text = formula && formula.expression
      if text.nil? || text.to_s.empty?
        raise UnsupportedRuleError,
              "#{rule.type} rule (priority #{rule.priority}) is missing its formula"
      end
      text.to_s
    end

    # Parses and evaluates a formula. Relative references are anchored at the
    # top-left cell of +anchor+ (the first range of the rule's sqref).
    def eval_formula(text, anchor, row, col)
      ast = FormulaParser.new.parse(text)
      eval_node(ast, {
        :anchor_row => anchor.first_row, :anchor_col => anchor.first_col,
        :row => row, :col => col
      })
    end

    def eval_node(node, ctx)
      case node[0]
      when :num, :str, :bool then node[1]
      when :ref then resolve_reference(node, ctx)
      when :neg then -to_number(eval_node(node[1], ctx))
      when :pct then to_number(eval_node(node[1], ctx)) / 100.0
      when :arith
        left = to_number(eval_node(node[2], ctx))
        right = to_number(eval_node(node[3], ctx))
        case node[1]
        when '+' then left + right
        when '-' then left - right
        when '*' then left * right
        when '/'
          raise FormulaError, 'division by zero in formula' if right.zero?
          left / right
        when '^' then left**right
        end
      when :concat
        to_string(eval_node(node[1], ctx)) + to_string(eval_node(node[2], ctx))
      when :cmp
        cmp = compare_values(eval_node(node[2], ctx), eval_node(node[3], ctx))
        case node[1]
        when '='  then cmp == 0
        when '<>' then cmp != 0
        when '<'  then cmp < 0
        when '<=' then cmp <= 0
        when '>'  then cmp > 0
        when '>=' then cmp >= 0
        end
      when :call then eval_function(node[1], node[2], ctx)
      end
    end

    def resolve_reference(node, ctx)
      _, row, col, row_abs, col_abs = node
      resolved_row = row_abs ? row : row + (ctx[:row] - ctx[:anchor_row])
      resolved_col = col_abs ? col : col + (ctx[:col] - ctx[:anchor_col])
      if resolved_row.negative? || resolved_col.negative?
        raise FormulaError, 'relative reference resolves outside the sheet'
      end
      fetch_value(resolved_row, resolved_col)
    end

    def eval_function(name, arg_nodes, ctx)
      args = arg_nodes.map { |n| eval_node(n, ctx) }
      case name
      when 'AND'
        raise FormulaError, 'AND requires at least one argument' if args.empty?
        args.all? { |a| to_bool(a) }
      when 'OR'
        raise FormulaError, 'OR requires at least one argument' if args.empty?
        args.any? { |a| to_bool(a) }
      when 'NOT'
        raise FormulaError, 'NOT requires exactly one argument' unless args.size == 1
        !to_bool(args[0])
      when 'ISBLANK'
        raise FormulaError, 'ISBLANK requires exactly one argument' unless args.size == 1
        args[0].nil?
      when 'ISNUMBER'
        raise FormulaError, 'ISNUMBER requires exactly one argument' unless args.size == 1
        args[0].is_a?(Numeric)
      when 'ISTEXT'
        raise FormulaError, 'ISTEXT requires exactly one argument' unless args.size == 1
        args[0].is_a?(String)
      else
        raise UnsupportedRuleError, "unsupported function #{name} " \
                                    "(supported: #{SUPPORTED_FUNCTIONS.join(', ')})"
      end
    end

    # --- value coercion and comparison -----------------------------------------

    def to_number(value)
      case value
      when nil then 0
      when Numeric then value
      when true then 1
      when false then 0
      when String
        begin
          Float(value)
        rescue ArgumentError
          raise FormulaError, "cannot convert #{value.inspect} to a number"
        end
      else
        raise FormulaError, "cannot convert #{value.inspect} to a number"
      end
    end

    def to_string(value)
      case value
      when nil then ''
      when true then 'TRUE'
      when false then 'FALSE'
      when Numeric then value == value.to_i ? value.to_i.to_s : value.to_s
      else value.to_s
      end
    end

    def to_bool(value)
      case value
      when nil then false
      when true, false then value
      when Numeric then value != 0
      when String
        case value.upcase
        when 'TRUE' then true
        when 'FALSE' then false
        else raise FormulaError, "cannot convert #{value.inspect} to a boolean"
        end
      else
        raise FormulaError, "cannot convert #{value.inspect} to a boolean"
      end
    end

    # Excel-style comparison: blanks coerce to the other operand's type;
    # otherwise numbers < text < logicals; text compares case-insensitively.
    def compare_values(left, right)
      left = coerce_blank(left, right)
      right = coerce_blank(right, left)
      return 0 if left.nil? && right.nil?

      if left.is_a?(Numeric) && right.is_a?(Numeric)
        left <=> right
      elsif left.is_a?(String) && right.is_a?(String)
        left.downcase <=> right.downcase
      elsif [true, false].include?(left) && [true, false].include?(right)
        (left ? 1 : 0) <=> (right ? 1 : 0)
      else
        type_rank(left) <=> type_rank(right)
      end
    end

    def coerce_blank(value, other)
      return value unless value.nil?
      case other
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

    # --- differential style extraction and merging ------------------------------

    FONT_SCALAR_CHILDREN = %w{name charset family b i strike outline shadow
                              condense extend sz u vert_align scheme}.freeze
    BORDER_EDGES = %w{left right top bottom diagonal vertical horizontal}.freeze

    # Merges one matched rule's contribution into the accumulated style hash.
    # Properties already set by higher-priority rules always win.
    def merge_rule_style(style, rule, fill_color)
      style['fill'] ||= { 'rgb' => fill_color } if fill_color
      dxf = rule_dxf(rule)
      deep_merge_unset(style, dxf_properties(dxf)) if dxf
      style
    end

    def rule_dxf(rule)
      return nil if rule.dxf_id.nil?
      workbook = @worksheet.workbook
      dxfs = workbook && workbook.stylesheet && workbook.stylesheet.dxfs
      dxf = dxfs && dxfs[rule.dxf_id]
      if dxf.nil?
        raise UnsupportedRuleError,
              "rule (priority #{rule.priority}) references missing dxfId #{rule.dxf_id}"
      end
      dxf
    end

    def dxf_properties(dxf)
      props = {}
      font = font_properties(dxf.font)
      props['font'] = font if font
      fill = fill_properties(dxf.fill)
      props['fill'] = fill if fill
      border = border_properties(dxf.border)
      props['border'] = border if border
      if dxf.num_fmt
        props['numberFormat'] = {
          'numFmtId' => dxf.num_fmt.num_fmt_id,
          'formatCode' => dxf.num_fmt.format_code
        }
      end
      props['alignment'] = attribute_hash(dxf.alignment) if dxf.alignment
      props['protection'] = attribute_hash(dxf.protection) if dxf.protection
      props
    end

    def font_properties(font)
      return nil if font.nil?
      props = {}
      FONT_SCALAR_CHILDREN.each do |name|
        child = font.send(name)
        props[name] = child.val if child
      end
      props['color'] = color_value(font.color) if font.color
      props.empty? ? nil : props
    end

    def fill_properties(fill)
      return nil if fill.nil?
      pattern = fill.pattern_fill
      return nil if pattern.nil?
      props = {}
      props['patternType'] = pattern.pattern_type if pattern.pattern_type
      props['fgColor'] = color_value(pattern.fg_color) if pattern.fg_color
      props['bgColor'] = color_value(pattern.bg_color) if pattern.bg_color
      props.empty? ? nil : props
    end

    def border_properties(border)
      return nil if border.nil?
      props = {}
      BORDER_EDGES.each do |edge|
        edge_obj = border.send(edge)
        next if edge_obj.nil?
        edge_props = {}
        edge_props['style'] = edge_obj.style if edge_obj.style
        edge_props['color'] = color_value(edge_obj.color) if edge_obj.color
        props[edge] = edge_props unless edge_props.empty?
      end
      props.empty? ? nil : props
    end

    def color_value(color)
      return color.rgb if color.rgb
      props = {}
      props['theme'] = color.theme unless color.theme.nil?
      props['indexed'] = color.indexed unless color.indexed.nil?
      props['tint'] = color.tint if color.tint && color.tint != 0
      props['auto'] = color.auto unless color.auto.nil?
      props
    end

    def attribute_hash(obj)
      obj.send(:obtain_class_variable, :@@ooxml_attributes).each_value.with_object({}) do |attr, hash|
        value = obj.send(attr[:accessor])
        hash[attr[:accessor].to_s] = value unless value.nil?
      end
    end

    # Deep-merges +src+ into +dst+, keeping values already present in +dst+
    # (i.e. properties set by higher-priority rules win).
    def deep_merge_unset(dst, src)
      src.each do |key, value|
        if value.is_a?(Hash) && dst[key].is_a?(Hash)
          deep_merge_unset(dst[key], value)
        elsif !dst.key?(key)
          dst[key] = value
        end
      end
      dst
    end
  end

  # Recursive-descent parser for the supported conditional formatting formula
  # subset (see ConditionalFormattingEvaluator docs). Produces a simple
  # s-expression-like AST consumed by the evaluator.
  class FormulaParser
    TOKEN_PATTERN = /\G\s*(?:(?<string>"(?:[^"]|"")*")|
                            (?<number>(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]\d+)?)|
                            (?<ref>\$?[A-Za-z]{1,3}\$?\d+)|
                            (?<name>[A-Za-z_][A-Za-z0-9_.]*)|
                            (?<op><=|>=|<>|[=<>+\-*\/^&%(),:]))/x

    COMPARISON_OPERATORS = %w{= <> < <= > >=}.freeze

    def parse(text)
      @tokens = tokenize(text.to_s.strip)
      @pos = 0
      node = parse_comparison
      unless at_end?
        raise ConditionalFormattingEvaluator::FormulaError,
              "unexpected token #{current.inspect} in formula #{text.inspect}"
      end
      node
    end

    private

    def tokenize(text)
      tokens = []
      pos = 0
      while pos < text.length
        match = TOKEN_PATTERN.match(text, pos)
        if match.nil?
          raise ConditionalFormattingEvaluator::FormulaError,
                "cannot parse formula #{text.inspect} near #{text[pos, 10].inspect}"
        end
        pos = match.end(0)
        if match[:string] then tokens << [:str, match[:string][1..-2].gsub('""', '"')]
        elsif match[:number] then tokens << [:num, Float(match[:number])]
        elsif match[:ref] then tokens << [:ref, match[:ref]]
        elsif match[:name] then tokens << [:name, match[:name].upcase]
        elsif match[:op] then tokens << [:op, match[:op]]
        end
      end
      tokens
    end

    def parse_comparison
      left = parse_concatenation
      return left unless COMPARISON_OPERATORS.include?(peek)
      op = advance
      [:cmp, op, left, parse_concatenation]
    end

    def parse_concatenation
      left = parse_additive
      left = [:concat, left, parse_additive] while peek == '&'
      left
    end

    def parse_additive
      left = parse_multiplicative
      while peek == '+' || peek == '-'
        op = advance
        left = [:arith, op, left, parse_multiplicative]
      end
      left
    end

    def parse_multiplicative
      left = parse_power
      while peek == '*' || peek == '/'
        op = advance
        left = [:arith, op, left, parse_power]
      end
      left
    end

    def parse_power
      base = parse_unary
      return base unless peek == '^'
      advance
      [:arith, '^', base, parse_unary]
    end

    def parse_unary
      case peek
      when '-' then advance; [:neg, parse_unary]
      when '+' then advance; parse_unary
      else parse_postfix
      end
    end

    def parse_postfix
      node = parse_primary
      node = [:pct, node] while peek == '%'
      node
    end

    def parse_primary
      token = current
      raise ConditionalFormattingEvaluator::FormulaError, 'unexpected end of formula' if token.nil?

      case token[0]
      when :num, :str
        advance
        [token[0], token[1]]
      when :ref
        advance
        row, col, row_abs, col_abs = RubyXL::Reference.ref2ind(token[1].upcase)
        [:ref, row, col, row_abs, col_abs]
      when :name
        parse_name_or_call
      when :op
        if token[1] == '('
          advance
          node = parse_comparison
          expect(')')
          node
        else
          raise ConditionalFormattingEvaluator::FormulaError,
                "unexpected operator #{token[1].inspect} in formula"
        end
      end
    end

    def parse_name_or_call
      name = current[1]
      advance
      return [:bool, true] if name == 'TRUE'
      return [:bool, false] if name == 'FALSE'

      unless peek == '('
        raise ConditionalFormattingEvaluator::UnsupportedRuleError,
              "unsupported token #{name.inspect} in formula " \
              '(defined names and sheet-qualified references are not supported)'
      end
      unless ConditionalFormattingEvaluator::SUPPORTED_FUNCTIONS.include?(name)
        raise ConditionalFormattingEvaluator::UnsupportedRuleError,
              "unsupported function #{name} " \
              "(supported: #{ConditionalFormattingEvaluator::SUPPORTED_FUNCTIONS.join(', ')})"
      end

      advance # '('
      args = []
      unless peek == ')'
        loop do
          args << parse_comparison
          break unless peek == ','
          advance
        end
      end
      expect(')')
      [:call, name, args]
    end

    def current
      @tokens[@pos]
    end

    # Value of the current token if it is an operator/punctuation, else nil.
    def peek
      token = current
      token && token[0] == :op ? token[1] : nil
    end

    def advance
      token = current
      @pos += 1
      token && token[0] == :op ? token[1] : token
    end

    def at_end?
      @pos >= @tokens.length
    end

    def expect(op)
      unless peek == op
        raise ConditionalFormattingEvaluator::FormulaError, "expected #{op.inspect} in formula"
      end
      advance
    end
  end
end
