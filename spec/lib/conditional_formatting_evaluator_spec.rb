# frozen_string_literal: true

require 'spec_helper'
require 'rubyXL/convenience_methods/conditional_formatting_evaluator'

describe RubyXL::ConditionalFormattingEvaluator do
  def rule(type:, priority:, **options)
    RubyXL::ConditionalFormattingRule.new({ :type => type, :priority => priority }.merge(options))
  end

  def formula(expression)
    RubyXL::Formula.new(:expression => expression)
  end

  def conditional_formatting(sqref, rules)
    RubyXL::ConditionalFormatting.new(:sqref => sqref, :cf_rule => rules)
  end

  def font_dxf(color)
    RubyXL::DXF.new(:font => RubyXL::Font.new(:color => RubyXL::Color.new(:rgb => color)))
  end

  def fill_dxf(color)
    RubyXL::DXF.new(:fill => RubyXL::Fill.new(:pattern_fill =>
      RubyXL::PatternFill.new(:pattern_type => 'solid', :bg_color => RubyXL::Color.new(:rgb => color))))
  end

  def register_dxf(workbook, dxf)
    workbook.stylesheet.dxfs ||= RubyXL::DXFs.new
    workbook.stylesheet.dxfs << dxf
    workbook.stylesheet.dxfs.size - 1
  end

  def font_color(result)
    result.style.font.color.rgb
  end

  def fill_color(result)
    result.style.fill.pattern_fill.bg_color.rgb
  end

  subject(:worksheet) { workbook[0] }

  let(:workbook) { RubyXL::Workbook.new }

  before do
    [[0, 0, 1], [1, 0, 2], [2, 0, 2], [3, 0, nil], [4, 0, 5], [5, 0, 3],
     [0, 2, 10], [1, 2, 9], [2, 2, 8], [0, 3, 2]].each do |row, column, value|
    worksheet.add_cell(row, column, value)
    end
    worksheet.add_cell(0, 1, 11)
  end

  it 'merges different differential style properties by priority and honors stopIfTrue' do
    fill_id = register_dxf(workbook, fill_dxf('FF0000'))
    font_id = register_dxf(workbook, font_dxf('00FF00'))
    stopped_id = register_dxf(workbook, fill_dxf('0000FF'))
    worksheet.conditional_formatting << conditional_formatting('A1:A6', [
      rule(:type => 'cellIs', :priority => 3, :operator => 'lessThan', :dxf_id => fill_id,
           :formulas => [formula('10')]),
      rule(:type => 'cellIs', :priority => 1, :operator => 'greaterThan', :dxf_id => font_id,
           :formulas => [formula('0')]),
      rule(:type => 'cellIs', :priority => 2, :operator => 'equal', :dxf_id => stopped_id,
           :stop_if_true => true, :formulas => [formula('1')])
    ])

    result = worksheet.evaluate_conditional_formatting(0, 0) { |row, column| worksheet[row]&.[](column)&.value }

    expect(result.rules.map(&:priority)).to eq([1, 2])
    expect(font_color(result)).to eq('00FF00')
    expect(fill_color(result)).to eq('0000FF')
    expect(worksheet.sheet_data.rows[0].cells[0].style_index).to eq(0)
  end

  it 'evaluates duplicate values, tied top values, blanks, and cell coordinates' do
    duplicate_id = register_dxf(workbook, fill_dxf('FF0000'))
    top_id = register_dxf(workbook, font_dxf('0000FF'))
    blank_id = register_dxf(workbook, fill_dxf('00FF00'))
    worksheet.conditional_formatting << conditional_formatting('A1:A5', [
      rule(:type => 'duplicateValues', :priority => 1, :dxf_id => duplicate_id),
      rule(:type => 'top10', :priority => 2, :rank => 2, :dxf_id => top_id),
      rule(:type => 'expression', :priority => 3, :dxf_id => blank_id,
           :formulas => [formula('ISBLANK(A1)')])
    ])

    duplicate_result = worksheet.evaluate_conditional_formatting(2, 0) { |row, column| worksheet[row][column]&.value }
    top_result = worksheet.evaluate_conditional_formatting(4, 0) { |row, column| worksheet[row][column]&.value }
    blank_result = worksheet.evaluate_conditional_formatting('A4') { |row, column| worksheet[row]&.[](column)&.value }

    expect(duplicate_result.rules.map(&:type)).to eq(%w[duplicateValues top10])
    expect(fill_color(duplicate_result)).to eq('FF0000')
    expect(font_color(duplicate_result)).to eq('0000FF')
    expect(top_result.rules.map(&:type)).to eq(%w[top10])
    expect(blank_result.rules.map(&:type)).to eq(%w[expression])
  end

  it 'uses each sqref segment as the relative formula anchor' do
    relative_id = register_dxf(workbook, fill_dxf('FF0000'))
    worksheet.conditional_formatting << conditional_formatting('A1:A5 C1:C3', [
      rule(:type => 'expression', :priority => 1, :dxf_id => relative_id,
           :formulas => [formula('AND(SUM(A1:B1)>=12,$A$1=1)')])
    ])

    first_segment = worksheet.evaluate_conditional_formatting(4, 0) { |row, column| worksheet[row]&.[](column)&.value }
    second_segment = worksheet.evaluate_conditional_formatting(0, 2) { |row, column| worksheet[row]&.[](column)&.value }
    third_segment = worksheet.evaluate_conditional_formatting(2, 2) { |row, column| worksheet[row]&.[](column)&.value }

    expect(first_segment.rules).to be_empty
    expect(second_segment.rules.map(&:type)).to eq(%w[expression])
    expect(third_segment.rules).to be_empty
  end

  it 'evaluates color scale endpoints and midpoint interpolation' do
    color_scale = RubyXL::ColorScale.new(
      :cfvo => [
        RubyXL::ConditionalFormatValue.new(:type => 'min'),
        RubyXL::ConditionalFormatValue.new(:type => 'max')
      ],
      :color => [
        RubyXL::Color.new(:rgb => 'FF000000'),
        RubyXL::Color.new(:rgb => 'FFFFFFFF')
      ]
    )
    worksheet.conditional_formatting << conditional_formatting('A1:A6', [
      rule(:type => 'colorScale', :priority => 1, :color_scale => color_scale)
    ])

    minimum = worksheet.evaluate_conditional_formatting(0, 0) { |row, column| worksheet[row]&.[](column)&.value }
    middle = worksheet.evaluate_conditional_formatting(5, 0) { |row, column| worksheet[row]&.[](column)&.value }
    blank = worksheet.evaluate_conditional_formatting(3, 0) { |row, column| worksheet[row]&.[](column)&.value }

    expect(fill_color(minimum)).to eq('FF000000')
    expect(fill_color(middle)).to eq('FF808080')
    expect(blank.rules).to be_empty
  end

  it 'uses the worksheet value reader by default and returns detached styles' do
    fill_id = register_dxf(workbook, fill_dxf('123456'))
    worksheet.conditional_formatting << conditional_formatting('A1:A1', [
      rule(:type => 'cellIs', :priority => 1, :operator => 'greaterThan', :dxf_id => fill_id,
           :formulas => [formula('0')])
    ])

    result = worksheet.evaluate_conditional_formatting('A1')

    expect(result.rules.map(&:type)).to eq(%w[cellIs])
    expect(fill_color(result)).to eq('123456')
    result.style.fill.pattern_fill.bg_color.rgb = 'ABCDEF'
    expect(workbook.stylesheet.dxfs[fill_id].fill.pattern_fill.bg_color.rgb).to eq('123456')
    expect(worksheet[0][0].style_index).to eq(0)
  end

  it 'does not default unsupported rules or uncomputable formulas to false' do
    worksheet.conditional_formatting << conditional_formatting('A1:A5', [
      rule(:type => 'containsText', :priority => 1, :formulas => [formula('NOT_IMPLEMENTED()')])
    ])

    expect { worksheet.evaluate_conditional_formatting(0, 0) { |_, _| 1 } }
      .to raise_error(RubyXL::ConditionalFormattingError, /containsText/)

    worksheet.conditional_formatting.first.cf_rule[0] = rule(:type => 'expression', :priority => 1,
                                                             :formulas => [formula('VLOOKUP(A1,A:A,1,FALSE)')])

    expect { worksheet.evaluate_conditional_formatting(0, 0) { |_, _| 1 } }
      .to raise_error(RubyXL::ConditionalFormattingError, /VLOOKUP/)
  end
end
