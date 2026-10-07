# frozen_string_literal: true

require 'rubyXL/conditional_formatting/formula_evaluator'
require 'rubyXL/conditional_formatting/style_merger'

module RubyXL
  module ConditionalFormatRules
    # One rule that fired for a cell and therefore contributed to its style.
    RuleContribution = Struct.new(
      :priority, :type, :dxf_id, :areas, :stop_if_true,
      :font_changed, :fill_changed, :border_changed,
      :number_format_changed, :alignment_changed, :protection_changed,
      keyword_init: true
    )

    # A rule that covered a cell but could not be evaluated. It never changes
    # the style and must not be confused with a rule that evaluated to false.
    UnevaluableRule = Struct.new(:priority, :type, :reason, keyword_init: true)

    # Final result for a single cell: the base materialised style, the merged
    # style, the rules that actually contributed and rules that were
    # unevaluable.
    class CellStyleResult
      attr_reader :row, :column, :base_style, :style,
                  :contributions, :unevaluable_rules

      def initialize(row, column, base_style, style, contributions, unevaluable_rules)
        @row = row
        @column = column
        @base_style = base_style
        @style = style
        @contributions = contributions
        @unevaluable_rules = unevaluable_rules
      end

      def ref
        RubyXL::Reference.ind2ref(row, column)
      end

      def stopped?
        contributions.any?(&:stop_if_true)
      end
    end

    # Region-level conditional formatting evaluator.
    #
    # Rules are applied in +priority+ order (lowest first). Each fired rule
    # overlays its differential style onto the running style; colorScale rules
    # overlay a solid interpolated fill. When a fired rule has
    # +stopIfTrue+, lower-priority rules no longer apply to that cell.
    class Evaluator
      SUPPORTED_TYPES = %w[cellIs expression duplicateValues uniqueValues top10 colorScale].freeze

      def initialize(worksheet)
        @worksheet = worksheet
        @workbook = worksheet.workbook
        @stylesheet = @workbook&.stylesheet
      end

      # Evaluates conditional formatting for every cell inside +range+
      # (a RubyXL::Reference or an A1-style string). Without an argument the
      # union of every declared sqref area is used.
      #
      # Returns a Hash of zero-based [row, column] => CellStyleResult.
      def evaluate(range = nil)
        rules = ordered_rules
        datasets = build_datasets(rules)

        results = {}
        target_cells(range).each_key do |row, col|
          results[[row, col]] = evaluate_cell(row, col, rules, datasets)
        end
        results
      end

      private

      # ----- region enumeration -------------------------------------------

      def target_cells(range)
        refs = range ? [coerce_reference(range)] : all_areas
        cells = {}
        refs.each do |area|
          area.row_range.each do |row|
            area.col_range.each do |col|
              cells[[row, col]] = true
            end
          end
        end
        cells
      end

      def coerce_reference(range)
        range.is_a?(RubyXL::Reference) ? range : RubyXL::Reference.new(range.to_s)
      end

      def all_areas
        conditional_formattings.flat_map { |cf| cf.sqref || [] }
      end

      def conditional_formattings
        @worksheet.conditional_formatting || []
      end

      def ordered_rules
        entries = []
        conditional_formattings.each do |cf|
          (cf.cf_rule || []).each { |rule| entries << [cf, rule] }
        end
        entries.sort_by.with_index do |(_cf, rule), index|
          [rule.priority.nil? ? 1_000_000 : rule.priority, index]
        end
      end

      # ----- precomputed per-rule datasets --------------------------------

      def build_datasets(rules)
        rules.each_with_object({}) do |(cf, rule), memo|
          memo[[cf.object_id, rule.object_id]] =
            case rule.type
            when 'duplicateValues', 'uniqueValues' then value_frequency_dataset(cf)
            when 'top10'                        then top10_dataset(cf, rule)
            when 'colorScale'                    then color_scale_dataset(cf, rule)
            else nil
            end
        end
      end

      def area_cells(cf)
        cells = []
        (cf.sqref || []).each do |area|
          area.row_range.each do |row|
            area.col_range.each { |col| cells << [row, col] }
          end
        end
        cells
      end

      def value_frequency_dataset(cf)
        groups = Hash.new { |hash, key| hash[key] = [] }
        area_cells(cf).each do |row, col|
          value = comparable_cell_value(row, col)
          next if value.nil? # Blank cells are neither duplicates nor uniques.
          groups[value] << [row, col]
        end

        duplicates = groups.values.select { |cells| cells.size > 1 }.flatten(1)
        uniques = groups.values.select { |cells| cells.size == 1 }.flatten(1)
        { duplicates: duplicates, uniques: uniques }
      end

      # Normalises numbers and text for duplicate detection. Numbers compare
      # numerically (5 and 5.0 are the same); everything else compares as
      # stripped strings. Booleans keep their own category.
      def comparable_cell_value(row, col)
        value = cell_value(row, col)
        case value
        when nil    then nil
        when Numeric then [:num, value.to_f]
        when true, false then [:bool, value]
        else
          text = value.to_s
          text.empty? ? nil : [:text, text]
        end
      end

      def top10_dataset(cf, rule)
        entries = area_cells(cf).map do |row, col|
          value = numeric_value(row, col)
          value.nil? ? nil : [row, col, value]
        end.compact

        sorted = entries.sort_by(&:last)
        rank_count = rule.rank || 10

        selected = top10_selected(sorted, rank_count, rule)

        { selected: selected.map { |row, col, _value| [row, col] } }
      end

      # Excel Top 10 semantics: rank N selects every cell whose value is at
      # least the Nth-largest value (ties all come along), likewise for
      # bottom N. Percentage mode uses the value boundary at the given
      # percentage of the value span, which also keeps ties together.
      def top10_selected(sorted, rank_count, rule)
        return [] if sorted.empty? || rank_count.nil? || rank_count <= 0

        threshold =
          if rule.percent == true
            min = sorted.first.last.to_f
            max = sorted.last.last.to_f
            if rule.bottom == true
              min + (max - min) * rank_count / 100.0
            else
              max - (max - min) * rank_count / 100.0
            end
          else
            count = [rank_count, sorted.size].min
            rule.bottom == true ? sorted[count - 1].last : sorted[sorted.size - count].last
          end

        sorted.select do |_row, _col, value|
          rule.bottom == true ? value <= threshold : value >= threshold
        end
      end

      def color_scale_dataset(cf, rule)
        entries = area_cells(cf).map do |row, col|
          value = numeric_value(row, col)
          value.nil? ? nil : [row, col, value]
        end.compact

        resolver = ColorScaleResolver.new(rule, @worksheet, entries)
        { resolver: resolver, colors: resolver.colors }
      end

      # ----- per-cell flow -------------------------------------------------

      def evaluate_cell(row, col, rules, datasets)
        base = resolve_base_style(row, col)
        style = StyleMerger.dup_style(base)
        contributions = []
        unevaluable = []

        rules.each do |cf, rule|
          areas = containing_areas(cf, row, col)
          next if areas.empty?

          outcome = rule_outcome(rule, row, col, areas, datasets[[cf.object_id, rule.object_id]])

          case outcome[:status]
          when :unevaluable
            unevaluable << UnevaluableRule.new(priority: rule.priority, type: rule.type,
                                               reason: outcome[:reason])
          when :hit
            changed = apply_hit_style(rule, style, outcome)
            contributions << RuleContribution.new(
              priority: rule.priority, type: rule.type, dxf_id: rule.dxf_id,
              areas: areas.map(&:to_s), stop_if_true: rule.stop_if_true == true,
              **changed
            )
            break if rule.stop_if_true == true
          end
        end

        CellStyleResult.new(row, col, base, style, contributions, unevaluable)
      end

      def containing_areas(cf, row, col)
        (cf.sqref || []).select do |area|
          area.row_range.cover?(row) && area.col_range.cover?(col)
        end
      end

      def rule_outcome(rule, row, col, areas, dataset)
        case rule.type
        when 'cellIs'       then evaluate_cell_is(rule, row, col, areas)
        when 'expression'  then evaluate_expression(rule, row, col, areas)
        when 'duplicateValues'
          { status: dataset[:duplicates].include?([row, col]) ? :hit : :miss }
        when 'uniqueValues'
          { status: dataset[:uniques].include?([row, col]) ? :hit : :miss }
        when 'top10'
          { status: dataset[:selected].include?([row, col]) ? :hit : :miss }
        when 'colorScale'
          color = dataset[:colors][[row, col]]
          color ? { status: :hit, color: color } : { status: :miss }
        else
          { status: :unevaluable, reason: "unsupported rule type #{rule.type.inspect}" }
        end
      end

      # ----- cellIs --------------------------------------------------------

      def evaluate_cell_is(rule, row, col, areas)
        value = numeric_value(row, col)
        return { status: :miss } if value.nil?

        expressions = rule.formulas || []
        operator = rule.operator

        case operator
        when 'between', 'notBetween'
          lower = formula_value(expressions[0]&.expression, areas.first, row, col)
          return lower unless lower[:status] == :ok
          upper = formula_value(expressions[1]&.expression, areas.first, row, col)
          return upper unless upper[:status] == :ok
          low, high = [lower[:value], upper[:value]].minmax
          numeric = low.is_a?(Numeric) && high.is_a?(Numeric)
          return { status: :unevaluable, reason: 'between bounds are not numeric' } unless numeric
          inside = value >= low && value <= high
          { status: (operator == 'between' ? inside : !inside) ? :hit : :miss }
        when 'equal', 'notEqual', 'lessThan', 'lessThanOrEqual',
             'greaterThan', 'greaterThanOrEqual'
          other = formula_value(expressions[0]&.expression, areas.first, row, col)
          return other unless other[:status] == :ok
          return { status: :unevaluable, reason: 'cellIs comparison value is not numeric' } unless other[:value].is_a?(Numeric)
          hit = compare_numbers(value, operator, other[:value])
          { status: hit ? :hit : :miss }
        else
          { status: :unevaluable, reason: "cellIs operator #{operator.inspect} is not supported" }
        end
      end

      def compare_numbers(value, operator, other)
        case operator
        when 'equal'              then value == other
        when 'notEqual'           then value != other
        when 'lessThan'           then value <  other
        when 'lessThanOrEqual'    then value <= other
        when 'greaterThan'        then value >  other
        when 'greaterThanOrEqual' then value >= other
        end
      end

      # ----- expression ----------------------------------------------------

      def evaluate_expression(rule, row, col, areas)
        expression = rule.formulas&.first&.expression
        areas.each do |area|
          outcome = formula_value(expression, area, row, col)
          return outcome if outcome[:status] == :unevaluable
          return { status: :hit } if FormulaEvaluator.truthy?(outcome[:value])
        end
        { status: :miss }
      end

      # Evaluates a formula with its anchor at the top-left corner of the
      # particular sqref area, so relative references shift per area.
      def formula_value(expression, area, row, col)
        # The formula is authored against the area's top-left cell. When it is
        # applied to a cell further into the area, relative references walk
        # forward by (cell - area anchor): formula A1>B1 applied to C2 reads
        # A2>B2, so each sqref area gets its own relative starting point.
        evaluator = FormulaEvaluator.new(@worksheet, row - area.first_row, col - area.first_col)
        { status: :ok, value: evaluator.evaluate(expression) }
      rescue UnevaluableFormula => e
        { status: :unevaluable, reason: e.message }
      end

      # ----- styles --------------------------------------------------------

      def apply_hit_style(rule, style, outcome)
        if rule.type == 'colorScale'
          style.fill = StyleMerger.solid_fill(outcome[:color])
          { fill_changed: true }
        else
          dxf = dxf_for(rule)
          changes = StyleMerger.apply_dxf(style, dxf)
          changes
        end
      end

      def dxf_for(rule)
        return nil if rule.dxf_id.nil?
        dxfs = @stylesheet.dxfs
        dxfs && dxfs[rule.dxf_id]
      end

      def resolve_base_style(row, col)
        cell = @worksheet.cell_at(RubyXL::Reference.ind2ref(row, col)) rescue nil
        xf = if cell
               @stylesheet.cell_xfs[cell.style_index || 0]
             else
               @stylesheet.cell_xfs[0]
             end
        xf ||= @stylesheet.cell_xfs[0]
        materialise(xf)
      end

      def materialise(xf)
        ResolvedStyle.new(
          xf: xf,
          font: @stylesheet.fonts[xf.font_id || 0],
          fill: @stylesheet.fills[xf.fill_id || 0],
          border: @stylesheet.borders[xf.border_id || 0],
          number_format: @stylesheet.get_number_format_by_id(xf.num_fmt_id || 0),
          alignment: xf.alignment,
          protection: xf.protection
        )
      end

      # ----- cell values ---------------------------------------------------

      def cell_value(row, col)
        cell = @worksheet.cell_at(RubyXL::Reference.ind2ref(row, col)) rescue nil
        return nil if cell.nil? || cell.formula
        cell.value
      end

      def numeric_value(row, col)
        value = cell_value(row, col)
        value.is_a?(Numeric) ? value : nil
      end
    end
  end
end
