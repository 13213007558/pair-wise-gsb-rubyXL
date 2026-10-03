# frozen_string_literal: true

require 'spec_helper'

describe RubyXL::ConditionalFormattingEvaluator do
  let(:workbook) { RubyXL::Workbook.new }
  let(:worksheet) { workbook.add_worksheet('Sheet1') }

  def add_dxfs(*dxfs)
    workbook.stylesheet.dxfs = RubyXL::DXFs.new(:_ => dxfs)
  end

  def font_dxf(color_rgb)
    RubyXL::DXF.new(:font => RubyXL::Font.new(
      :b => RubyXL::BooleanValue.new(:val => true),
      :color => RubyXL::Color.new(:rgb => color_rgb)))
  end

  def fill_dxf(rgb)
    RubyXL::DXF.new(:fill => RubyXL::Fill.new(
      :pattern_fill => RubyXL::PatternFill.new(
        :pattern_type => 'solid',
        :fg_color => RubyXL::Color.new(:rgb => rgb))))
  end

  def add_conditional_formatting(sqref, *rules)
    worksheet.conditional_formatting =
      (worksheet.conditional_formatting || []) +
      [RubyXL::ConditionalFormatting.new(:sqref => RubyXL::Sqref.new(sqref), :cf_rule => rules)]
  end

  def cell_is_rule(priority:, dxf_id:, operator:, formulas:, stop_if_true: false)
    RubyXL::ConditionalFormattingRule.new(
      :type => 'cellIs', :priority => priority, :dxf_id => dxf_id,
      :operator => operator, :stop_if_true => stop_if_true,
      :formulas => formulas.map { |f| RubyXL::Formula.new(:expression => f) })
  end

  def expression_rule(priority:, dxf_id:, formula:)
    RubyXL::ConditionalFormattingRule.new(
      :type => 'expression', :priority => priority, :dxf_id => dxf_id,
      :formulas => [RubyXL::Formula.new(:expression => formula)])
  end

  def evaluator_for(values)
    described_class.new(worksheet, ->(row, col) { values[[row, col]] })
  end

  describe 'priority handling and style merging' do
    before { add_dxfs(font_dxf('FFFF0000'), fill_dxf('FFFFFF00'), font_dxf('FF0000FF')) }

    it 'merges different properties contributed by multiple matching rules' do
      add_conditional_formatting('A1:A5',
        cell_is_rule(:priority => 1, :dxf_id => 0, :operator => 'greaterThan', :formulas => ['5']),
        cell_is_rule(:priority => 2, :dxf_id => 1, :operator => 'lessThan', :formulas => ['100']))

      result = evaluator_for({ [0, 0] => 10 }).evaluate(0, 0)

      expect(result.matched_rules.size).to eq(2)
      expect(result.matched_rules.map(&:priority)).to eq([1, 2])
      expect(result.style['font']['b']).to eq(true)
      expect(result.style['font']['color']).to eq('FFFF0000')
      expect(result.style['fill']).to eq('patternType' => 'solid', 'fgColor' => 'FFFFFF00')
    end

    it 'lets the higher-priority rule win on conflicting properties' do
      add_conditional_formatting('A1:A5',
        cell_is_rule(:priority => 1, :dxf_id => 0, :operator => 'greaterThan', :formulas => ['5']),
        cell_is_rule(:priority => 2, :dxf_id => 2, :operator => 'greaterThan', :formulas => ['1']))

      result = evaluator_for({ [0, 0] => 10 }).evaluate(0, 0)

      expect(result.style['font']['color']).to eq('FFFF0000')
    end

    it 'stops evaluating lower-priority rules when stopIfTrue is set' do
      add_conditional_formatting('A1:A5',
        cell_is_rule(:priority => 1, :dxf_id => 0, :operator => 'greaterThan',
                     :formulas => ['5'], :stop_if_true => true),
        cell_is_rule(:priority => 2, :dxf_id => 1, :operator => 'lessThan', :formulas => ['100']))

      result = evaluator_for({ [0, 0] => 10 }).evaluate(0, 0)

      expect(result.matched_rules.size).to eq(1)
      expect(result.style).not_to have_key('fill')
    end

    it 'returns an empty result when no rule matches' do
      add_conditional_formatting('A1:A5',
        cell_is_rule(:priority => 1, :dxf_id => 0, :operator => 'greaterThan', :formulas => ['50']))

      result = evaluator_for({ [0, 0] => 10 }).evaluate(0, 0)

      expect(result.matched?).to eq(false)
      expect(result.style).to eq({})
    end
  end

  describe 'duplicateValues / uniqueValues' do
    let(:values) { { [0, 0] => 1, [1, 0] => 2, [2, 0] => 2, [3, 0] => 3 } }

    it 'matches values that appear more than once in the range' do
      add_conditional_formatting('A1:A4',
        RubyXL::ConditionalFormattingRule.new(:type => 'duplicateValues', :priority => 1, :dxf_id => 0))
      add_dxfs(font_dxf('FFFF0000'))

      expect(evaluator_for(values).evaluate(1, 0).matched?).to eq(true)
      expect(evaluator_for(values).evaluate(0, 0).matched?).to eq(false)
    end

    it 'matches values that appear exactly once in the range' do
      add_conditional_formatting('A1:A4',
        RubyXL::ConditionalFormattingRule.new(:type => 'uniqueValues', :priority => 1, :dxf_id => 0))
      add_dxfs(font_dxf('FFFF0000'))

      expect(evaluator_for(values).evaluate(0, 0).matched?).to eq(true)
      expect(evaluator_for(values).evaluate(1, 0).matched?).to eq(false)
    end

    it 'ignores blank cells' do
      add_conditional_formatting('A1:A3',
        RubyXL::ConditionalFormattingRule.new(:type => 'duplicateValues', :priority => 1, :dxf_id => 0))
      add_dxfs(font_dxf('FFFF0000'))

      expect(evaluator_for({ [2, 0] => 1 }).evaluate(0, 0).matched?).to eq(false)
    end
  end

  describe 'top10' do
    let(:values) { { [0, 0] => 10, [1, 0] => 10, [2, 0] => 7, [3, 0] => 5 } }

    before { add_dxfs(font_dxf('FFFF0000')) }

    it 'includes tied values at the threshold' do
      add_conditional_formatting('A1:A4',
        RubyXL::ConditionalFormattingRule.new(:type => 'top10', :priority => 1, :dxf_id => 0, :rank => 1))

      expect(evaluator_for(values).evaluate(0, 0).matched?).to eq(true)
      expect(evaluator_for(values).evaluate(1, 0).matched?).to eq(true)
      expect(evaluator_for(values).evaluate(2, 0).matched?).to eq(false)
    end

    it 'supports bottom N' do
      add_conditional_formatting('A1:A4',
        RubyXL::ConditionalFormattingRule.new(:type => 'top10', :priority => 1, :dxf_id => 0,
                                              :rank => 1, :bottom => true))

      expect(evaluator_for(values).evaluate(3, 0).matched?).to eq(true)
      expect(evaluator_for(values).evaluate(2, 0).matched?).to eq(false)
    end

    it 'supports percent' do
      add_conditional_formatting('A1:A4',
        RubyXL::ConditionalFormattingRule.new(:type => 'top10', :priority => 1, :dxf_id => 0,
                                              :rank => 75, :percent => true))

      expect(evaluator_for(values).evaluate(0, 0).matched?).to eq(true)
      expect(evaluator_for(values).evaluate(2, 0).matched?).to eq(true)
      expect(evaluator_for(values).evaluate(3, 0).matched?).to eq(false)
    end
  end

  describe 'blank cells' do
    before { add_dxfs(font_dxf('FFFF0000')) }

    it 'does not apply cellIs rules to blank cells' do
      add_conditional_formatting('A1:A5',
        cell_is_rule(:priority => 1, :dxf_id => 0, :operator => 'equal', :formulas => ['0']))

      expect(evaluator_for({}).evaluate(0, 0).matched?).to eq(false)
    end

    it 'evaluates ISBLANK expressions' do
      add_conditional_formatting('A1:A5', expression_rule(:priority => 1, :dxf_id => 0, :formula => 'ISBLANK(A1)'))

      expect(evaluator_for({}).evaluate(0, 0).matched?).to eq(true)
      expect(evaluator_for({ [0, 0] => 1 }).evaluate(0, 0).matched?).to eq(false)
    end
  end

  describe 'colorScale' do
    let(:values) { { [0, 0] => 0, [1, 0] => 50, [2, 0] => 100 } }

    before do
      add_conditional_formatting('A1:A3',
        RubyXL::ConditionalFormattingRule.new(
          :type => 'colorScale', :priority => 1,
          :color_scale => RubyXL::ColorScale.new(
            :cfvo => [RubyXL::ConditionalFormatValue.new(:type => 'min'),
                      RubyXL::ConditionalFormatValue.new(:type => 'max')],
            :color => [RubyXL::Color.new(:rgb => 'FFFF0000'),
                       RubyXL::Color.new(:rgb => 'FF0000FF')])))
    end

    it 'returns the first color at the lower endpoint' do
      result = evaluator_for(values).evaluate(0, 0)
      expect(result.style['fill']['rgb']).to eq('FFFF0000')
      expect(result.matched_rules.first.fill_color).to eq('FFFF0000')
    end

    it 'returns the last color at the upper endpoint' do
      expect(evaluator_for(values).evaluate(2, 0).style['fill']['rgb']).to eq('FF0000FF')
    end

    it 'interpolates between the endpoints' do
      expect(evaluator_for(values).evaluate(1, 0).style['fill']['rgb']).to eq('FF800080')
    end

    it 'clamps values outside the endpoints' do
      expect(evaluator_for(values.merge([-1, 0] => nil, [0, 0] => -5)).evaluate(0, 0).style['fill']['rgb'])
        .to eq('FFFF0000')
      expect(evaluator_for(values.merge([0, 0] => 200)).evaluate(0, 0).style['fill']['rgb'])
        .to eq('FF0000FF')
    end
  end

  describe 'expression rules and reference anchoring' do
    before { add_dxfs(font_dxf('FFFF0000')) }

    it 'anchors relative references at the top-left of the containing range' do
      add_conditional_formatting('B2:B5', expression_rule(:priority => 1, :dxf_id => 0, :formula => 'A2>5'))

      expect(evaluator_for({ [2, 0] => 10 }).evaluate(2, 1).matched?).to eq(true)  # B3 looks at A3
      expect(evaluator_for({}).evaluate(2, 1).matched?).to eq(false)
    end

    it 'uses the containing range of a multi-range sqref as anchor, not the cell itself' do
      add_conditional_formatting('B2:B5 D2:D5',
        expression_rule(:priority => 1, :dxf_id => 0, :formula => 'A2>5'))

      # Anchor is B2 (top-left of the first range): D3 resolves A2 -> C3 (row 2, col 2).
      expect(evaluator_for({ [2, 2] => 10 }).evaluate(2, 3).matched?).to eq(true)
      # If the cell itself were (mis)used as anchor, A2 would be read literally.
      expect(evaluator_for({ [1, 0] => 10 }).evaluate(2, 3).matched?).to eq(false)
    end

    it 'keeps absolute references fixed' do
      add_conditional_formatting('B2:B5', expression_rule(:priority => 1, :dxf_id => 0, :formula => '$A$2>5'))

      expect(evaluator_for({ [1, 0] => 10 }).evaluate(4, 1).matched?).to eq(true)
      expect(evaluator_for({}).evaluate(4, 1).matched?).to eq(false)
    end

    it 'supports arithmetic, comparisons and boolean functions' do
      add_conditional_formatting('A1:A5',
        expression_rule(:priority => 1, :dxf_id => 0, :formula => 'AND(A1*2>10, NOT(ISBLANK(A1)))'))

      expect(evaluator_for({ [0, 0] => 6 }).evaluate(0, 0).matched?).to eq(true)
      expect(evaluator_for({ [0, 0] => 5 }).evaluate(0, 0).matched?).to eq(false)
    end
  end

  describe 'unsupported rules and formulas' do
    it 'raises for unsupported rule types instead of defaulting to false' do
      add_conditional_formatting('A1:A5',
        RubyXL::ConditionalFormattingRule.new(:type => 'dataBar', :priority => 1))

      expect { evaluator_for({ [0, 0] => 1 }).evaluate(0, 0) }
        .to raise_error(RubyXL::ConditionalFormattingEvaluator::UnsupportedRuleError, /dataBar/)
    end

    it 'raises for functions outside the supported subset' do
      add_conditional_formatting('A1:A5',
        expression_rule(:priority => 1, :dxf_id => 0, :formula => 'VLOOKUP(A1,B1,1)'))

      expect { evaluator_for({ [0, 0] => 1 }).evaluate(0, 0) }
        .to raise_error(RubyXL::ConditionalFormattingEvaluator::UnsupportedRuleError, /VLOOKUP/)
    end

    it 'raises for range references in formulas' do
      add_conditional_formatting('A1:A5',
        expression_rule(:priority => 1, :dxf_id => 0, :formula => 'AND(A1:A2)'))

      expect { evaluator_for({ [0, 0] => 1 }).evaluate(0, 0) }
        .to raise_error(RubyXL::ConditionalFormattingEvaluator::FormulaError)
    end
  end

  describe 'read-only behavior' do
    it 'does not write computed styles back to the workbook' do
      worksheet.add_cell(0, 0, 10)
      add_dxfs(font_dxf('FFFF0000'))
      add_conditional_formatting('A1:A5',
        cell_is_rule(:priority => 1, :dxf_id => 0, :operator => 'greaterThan', :formulas => ['5']))

      provider = described_class::WorksheetValueProvider.new(worksheet)
      result = described_class.new(worksheet, provider).evaluate('A1')

      expect(result.matched?).to eq(true)
      expect(worksheet[0][0].style_index).to eq(0) # unchanged: no style painted back
      expect(workbook.stylesheet.dxfs.size).to eq(1)
      expect(worksheet.conditional_formatting.size).to eq(1)
    end

    it 'accepts A1-style references and worksheet-backed providers' do
      worksheet.add_cell(1, 1, 10)
      add_dxfs(font_dxf('FFFF0000'))
      add_conditional_formatting('B2:B5',
        cell_is_rule(:priority => 1, :dxf_id => 0, :operator => 'greaterThan', :formulas => ['5']))

      result = described_class.evaluate(worksheet, 'B2', nil,
                                        described_class::WorksheetValueProvider.new(worksheet))

      expect(result.row).to eq(1)
      expect(result.col).to eq(1)
      expect(result.matched?).to eq(true)
      expect(result.style['font']['color']).to eq('FFFF0000')
    end
  end
end
