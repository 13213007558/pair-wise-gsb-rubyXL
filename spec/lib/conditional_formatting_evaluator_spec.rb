# frozen_string_literal: true

require 'spec_helper'

describe RubyXL::ConditionalFormattingEvaluation do
  def font_dxf(bold: nil, strike: nil, color_rgb: nil)
    font = RubyXL::Font.new
    font.b = RubyXL::BooleanValue.new(:val => bold) unless bold.nil?
    font.strike = RubyXL::BooleanValue.new(:val => strike) unless strike.nil?
    font.color = RubyXL::Color.new(:rgb => color_rgb) if color_rgb
    RubyXL::DXF.new(:font => font)
  end

  def fill_dxf(rgb)
    fill = RubyXL::Fill.new(
      :pattern_fill => RubyXL::PatternFill.new(
        :pattern_type => 'solid',
        :fg_color => RubyXL::Color.new(:rgb => rgb),
        :bg_color => RubyXL::Color.new(:rgb => rgb)
      )
    )
    RubyXL::DXF.new(:fill => fill)
  end

  def add_dxfs(workbook, dxfs)
    workbook.stylesheet.dxfs = RubyXL::DXFs.new(:_ => dxfs)
  end

  def add_cf_block(worksheet, sqref, rules)
    block = RubyXL::ConditionalFormatting.new(:sqref => RubyXL::Sqref.new(sqref))
    block.cf_rule = rules
    worksheet.conditional_formatting << block
    block
  end

  def rule(type:, priority:, dxf_id: nil, stop: false, operator: nil, formulas: [], rank: nil, color_scale: nil)
    RubyXL::ConditionalFormattingRule.new(
      :type => type,
      :priority => priority,
      :dxf_id => dxf_id,
      :stop_if_true => stop,
      :operator => operator,
      :rank => rank,
      :formulas => formulas.map { |f| RubyXL::Formula.new(:expression => f) },
      :color_scale => color_scale
    )
  end

  def rule_types(result, address)
    result[address].applied_rules.map { |entry| entry[:type] }
  end

  describe 'rule priority, stopIfTrue and property-level merging' do
    before do
      @workbook = RubyXL::Workbook.new
      @worksheet = @workbook.add_worksheet('Sheet1')
      [[10, 'x'], [3, 'skip'], [7, 'x']].each_with_index do |(value, tag), i|
        @worksheet.add_cell(i, 0, value)
        @worksheet.add_cell(i, 1, tag)
      end
      add_dxfs(@workbook, [
        font_dxf(:strike => true),                    # dxf 0
        font_dxf(:bold => true, :color_rgb => 'FFFF0000'), # dxf 1
        fill_dxf('FFFFFF00'),                         # dxf 2
        fill_dxf('FF00FF00')                          # dxf 3
      ])
      add_cf_block(@worksheet, 'A1:A3', [
        rule(:type => 'expression', :priority => 1, :dxf_id => 0, :stop => true, :formulas => ['$B1="skip"']),
        rule(:type => 'cellIs', :priority => 2, :dxf_id => 1, :operator => 'greaterThan', :formulas => ['5']),
        rule(:type => 'expression', :priority => 3, :dxf_id => 2, :formulas => ['A1>0']),
        rule(:type => 'expression', :priority => 4, :dxf_id => 3, :formulas => ['A1>0'])
      ])
      @result = @worksheet.evaluate_conditional_formatting('A1:A3')
    end

    it 'merges font and fill contributed by separate matching rules' do
      style = @result['A1']
      expect(style.font.b.val).to eq(true)
      expect(style.font_color).to eq('FFFF0000')
      expect(style.fill_color).to eq('FFFFFF00')
      expect(style.font.name.val).to eq(@workbook.stylesheet.fonts[0].name.val)
    end

    it 'explains which rules actually contributed style properties' do
      style = @result['A1']
      expect(style.applied_rules.map { |r| r[:priority] }).to eq([2, 3, 4])
      expect(style.contributing_rules.map { |r| r[:priority] }).to eq([2, 3])
      expect(style.applied_rules[0][:properties]).to contain_exactly(:"font.b", :"font.color")
      expect(style.applied_rules[1][:properties]).to eq([:fill])
      expect(style.applied_rules[2][:properties]).to eq([]) # matched, but fill was already claimed
    end

    it 'stops evaluating lower-priority rules after a matching stopIfTrue rule' do
      style = @result['A2']
      expect(style.applied_rules.map { |r| r[:priority] }).to eq([1])
      expect(style.applied_rules[0][:stop_if_true]).to eq(true)
      expect(style.font.strike.val).to eq(true)
      expect(style.font.b).to be_nil
      expect(style.fill_color).to be_nil
    end

    it 'does not mutate the shared stylesheet font' do
      expect(@workbook.stylesheet.fonts[0].b).to be_nil
    end

    it 'defaults to evaluating every conditional formatting range' do
      result = @worksheet.evaluate_conditional_formatting
      expect(result.cells.keys).to contain_exactly('A1', 'A2', 'A3')
    end

    it 'exports a plain hash representation' do
      hash = @result.to_h
      expect(hash['A1'][:font][:bold]).to eq(true)
      expect(hash['A1'][:fill][:fg_color]).to eq('FFFFFF00')
      expect(hash['A1'][:applied_rules].size).to eq(3)
      expect(hash['A2'][:applied_rules].size).to eq(1)
    end
  end

  describe 'top10 and duplicateValues over a range with blanks and duplicates' do
    before do
      @workbook = RubyXL::Workbook.new
      @worksheet = @workbook.add_worksheet('Sheet1')
      [10, nil, 10, 5, nil, 3].each_with_index do |value, i|
        @worksheet.add_cell(i, 0, value) unless value.nil?
      end
      add_dxfs(@workbook, [fill_dxf('FFFFFF00'), fill_dxf('FF00FF00')])
      add_cf_block(@worksheet, 'A1:A6', [
        rule(:type => 'top10', :priority => 1, :dxf_id => 0, :rank => 2),
        rule(:type => 'duplicateValues', :priority => 2, :dxf_id => 1)
      ])
      @result = @worksheet.evaluate_conditional_formatting('A1:A6')
    end

    it 'gives duplicated numbers the same rank' do
      expect(rule_types(@result, 'A1')).to include('top10')
      expect(rule_types(@result, 'A3')).to include('top10')
      expect(rule_types(@result, 'A4')).not_to include('top10')
      expect(rule_types(@result, 'A6')).not_to include('top10')
    end

    it 'ignores blank cells' do
      expect(@result['A2'].applied_rules).to be_empty
      expect(@result['A5'].applied_rules).to be_empty
    end

    it 'flags both occurrences of a duplicated value' do
      expect(rule_types(@result, 'A1')).to include('duplicateValues')
      expect(rule_types(@result, 'A3')).to include('duplicateValues')
      expect(rule_types(@result, 'A4')).not_to include('duplicateValues')
    end

    it 'lets the higher-priority rule win the fill' do
      expect(@result['A1'].fill_color).to eq('FFFFFF00')
      expect(@result['A1'].contributing_rules.map { |r| r[:type] }).to eq(['top10'])
    end
  end

  describe 'colorScale' do
    before do
      @workbook = RubyXL::Workbook.new
      @worksheet = @workbook.add_worksheet('Sheet1')
      [0, 5, 10].each_with_index { |value, i| @worksheet.add_cell(i, 0, value) }
      scale = RubyXL::ColorScale.new(
        :cfvo => [
          RubyXL::ConditionalFormatValue.new(:type => 'min'),
          RubyXL::ConditionalFormatValue.new(:type => 'max')
        ],
        :color => [
          RubyXL::Color.new(:rgb => 'FFFF0000'),
          RubyXL::Color.new(:rgb => 'FF00FF00')
        ]
      )
      add_cf_block(@worksheet, 'A1:A4', [rule(:type => 'colorScale', :priority => 1, :color_scale => scale)])
      @result = @worksheet.evaluate_conditional_formatting('A1:A4')
    end

    it 'interpolates the fill color across the value range' do
      expect(@result['A1'].fill_color).to eq('FFFF0000')
      expect(@result['A2'].fill_color).to eq('FF808000')
      expect(@result['A3'].fill_color).to eq('FF00FF00')
      expect(@result['A2'].fill.pattern_fill.pattern_type).to eq('solid')
    end

    it 'records the contribution in applied rules' do
      entry = @result['A2'].applied_rules.first
      expect(entry[:type]).to eq('colorScale')
      expect(entry[:properties]).to eq([:fill])
      expect(entry[:color]).to eq('FF808000')
    end

    it 'leaves blank cells uncolored' do
      expect(@result['A4'].applied_rules).to be_empty
      expect(@result['A4'].fill_color).to be_nil
    end
  end

  describe 'unevaluatable formulas' do
    before do
      @workbook = RubyXL::Workbook.new
      @worksheet = @workbook.add_worksheet('Sheet1')
      @worksheet.add_cell(0, 0, 10)
      add_dxfs(@workbook, [fill_dxf('FFFFFF00'), font_dxf(:bold => true)])
      add_cf_block(@worksheet, 'A1:A1', [
        rule(:type => 'expression', :priority => 1, :dxf_id => 0, :stop => true, :formulas => ['SUM(A1,A2)>5']),
        rule(:type => 'cellIs', :priority => 2, :dxf_id => 1, :operator => 'greaterThan', :formulas => ['5'])
      ])
      @result = @worksheet.evaluate_conditional_formatting('A1:A1')
    end

    it 'reports unsupported functions as unevaluatable, not as false' do
      style = @result['A1']
      expect(style.unevaluatable_rules.size).to eq(1)
      entry = style.unevaluatable_rules.first
      expect(entry[:type]).to eq('expression')
      expect(entry[:reason]).to include('SUM')
    end

    it 'does not let an unevaluatable stopIfTrue rule block lower-priority rules' do
      style = @result['A1']
      expect(style.applied_rules.map { |r| r[:priority] }).to eq([2])
      expect(style.font.b.val).to eq(true)
    end
  end

  describe 'multiple sqref ranges' do
    before do
      @workbook = RubyXL::Workbook.new
      @worksheet = @workbook.add_worksheet('Sheet1')
      @worksheet.add_cell(0, 4, 0)  # E1
      @worksheet.add_cell(1, 4, 0)  # E2
      @worksheet.add_cell(0, 5, 1)  # F1
      @worksheet.add_cell(1, 5, -1) # F2
      @worksheet.add_cell(0, 6, 0)  # G1
      @worksheet.add_cell(1, 6, 0)  # G2
      @worksheet.add_cell(0, 7, 0)  # H1
      @worksheet.add_cell(1, 7, 5)  # H2
      add_dxfs(@workbook, [font_dxf(:bold => true)])
      add_cf_block(@worksheet, 'E1:E2 G1:G2', [
        rule(:type => 'expression', :priority => 1, :dxf_id => 0, :formulas => ['F1>0'])
      ])
      @result = @worksheet.evaluate_conditional_formatting('E1:G2')
    end

    it 'anchors relative references at the origin of each range' do
      expect(@result['E1'].applied_rules.size).to eq(1) # F1 = 1 > 0
      expect(@result['E2'].applied_rules).to be_empty  # F2 = -1
      expect(@result['G1'].applied_rules.size).to eq(1) # anchored at G1: still F1, not H1
      expect(@result['G2'].applied_rules).to be_empty  # anchored at G1: F2, not H2
    end
  end

  describe 'formula subset' do
    def evaluate_formula(formula, values = {})
      workbook = RubyXL::Workbook.new
      worksheet = workbook.add_worksheet('Sheet1')
      values.each { |addr, value| worksheet.add_cell(addr[0], addr[1], value) }
      evaluator = RubyXL::ConditionalFormattingEvaluation::Evaluator.new(worksheet)
      ast = RubyXL::ConditionalFormattingEvaluation::FormulaParser.parse(formula)
      RubyXL::ConditionalFormattingEvaluation::FormulaEvaluator.new(evaluator).evaluate(ast)
    end

    it 'evaluates arithmetic, comparisons and boolean combinations' do
      expect(evaluate_formula('1+2*3')).to eq(7)
      expect(evaluate_formula('(1+2)*3')).to eq(9)
      expect(evaluate_formula('A1>5', [0, 0] => 10)).to eq(true)
      expect(evaluate_formula('AND(A1>5, OR(A1=10, FALSE))', [0, 0] => 10)).to eq(true)
      expect(evaluate_formula('NOT(TRUE)')).to eq(false)
      expect(evaluate_formula('A1<=B1', [0, 0] => 3, [0, 1] => 4)).to eq(true)
    end

    it 'treats blank cells as zero in numeric comparisons' do
      expect(evaluate_formula('A1=0')).to eq(true)
    end

    it 'raises UnevaluatableError for unsupported functions' do
      expect { evaluate_formula('SUM(A1,A2)') }.to raise_error(RubyXL::ConditionalFormattingEvaluation::UnevaluatableError)
    end

    it 'raises UnevaluatableError for ranges and references to other sheets' do
      expect { evaluate_formula('A1:B2') }.to raise_error(RubyXL::ConditionalFormattingEvaluation::UnevaluatableError)
      expect { evaluate_formula('Other!A1') }.to raise_error(RubyXL::ConditionalFormattingEvaluation::UnevaluatableError)
    end
  end
end
