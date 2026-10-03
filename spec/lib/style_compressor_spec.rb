# frozen_string_literal: true

require 'spec_helper'
require 'rubyXL/style_compressor'
require 'rubyXL/convenience_methods/workbook'

describe RubyXL::StyleCompressor do
  let(:workbook) { RubyXL::Workbook.new }
  let(:styles) { workbook.stylesheet }

  def xf(options = {})
    RubyXL::XF.new({ :num_fmt_id => 0, :font_id => 0, :fill_id => 0, :border_id => 0 }.merge(options))
  end

  def solid_fill(color)
    RubyXL::Fill.new(:pattern_fill => RubyXL::PatternFill.new(
      :pattern_type => 'solid',
      :fg_color => color
    ))
  end

  it 'merges semantically equivalent styles and rewrites all supported references' do
    font = styles.fonts[0]
    fill = solid_fill(RubyXL::Color.new(:rgb => 'FF0000'))
    border = RubyXL::Border.new(:left => RubyXL::BorderEdge.new(:style => 'thin'))

    styles.number_formats = RubyXL::NumberFormats.new(:_ => [
      RubyXL::NumberFormat.new(:num_fmt_id => 175, :format_code => 'GENERAL'),
      RubyXL::NumberFormat.new(:num_fmt_id => 176, :format_code => '0.00'),
      RubyXL::NumberFormat.new(:num_fmt_id => 177, :format_code => '0.00')
    ])
    styles.fills << fill.dup << fill.dup
    styles.borders << border.dup << border.dup
    styles.fonts << font.dup

    styles.cell_style_xfs = RubyXL::CellStyleXFs.new(:_ => [
      xf(:font_id => 2, :fill_id => 2, :border_id => 1,
         :alignment => RubyXL::Alignment.new(:horizontal => 'center'))
    ])
    styles.cell_styles = RubyXL::CellStyles.new(:_ => [
      RubyXL::CellStyle.new(:name => 'Normal', :xf_id => 0)
    ])

    styles.cell_xfs = RubyXL::CellXFs.new(:_ => [
      xf(:num_fmt_id => 0, :font_id => 2, :fill_id => 2, :border_id => 1,
         :xf_id => 0, :apply_number_format => false, :apply_font => true,
         :apply_fill => true, :apply_border => true,
         :alignment => RubyXL::Alignment.new(:horizontal => 'center')),
      xf(:num_fmt_id => 2, :font_id => 0, :fill_id => 0, :border_id => 0,
         :xf_id => 0, :apply_number_format => false, :apply_font => false,
         :apply_fill => false, :apply_border => false,
         :alignment => RubyXL::Alignment.new(:horizontal => 'center')),
      xf(:num_fmt_id => 177, :font_id => 0, :fill_id => 0, :border_id => 0)
    ])

    worksheet = workbook[0]
    worksheet.add_cell(0, 0, 'A')
    worksheet.add_cell(1, 0, 'B')
    worksheet.add_cell(2, 0, 'C')
    worksheet[0][0].style_index = 0
    worksheet[1][0].style_index = 1
    worksheet[2][0].style_index = 2
    worksheet.sheet_data.rows[0].style_index = 0
    worksheet.cols << RubyXL::ColumnRange.new(:min => 1, :max => 1, :style_index => 2)

    result = workbook.compress_styles

    expect(styles.cell_xfs.size).to eq(2)
    expect(styles.fills.size).to eq(3)
    expect(styles.borders.size).to eq(2)
    expect(styles.fonts.size).to eq(2)
    expect(styles.number_formats).to be_nil
    expect(styles.cell_styles[0].xf_id).to eq(0)
    expect(worksheet[0][0].style_index).to eq(0)
    expect(worksheet[1][0].style_index).to eq(0)
    expect(worksheet[2][0].style_index).to eq(1)
    expect(worksheet.sheet_data.rows[0].style_index).to eq(0)
    expect(worksheet.cols[0].style_index).to eq(1)
    expect(result[:mappings][:cell_xfs]).to eq(0 => 0, 1 => 0, 2 => 1)
    expect(result[:mappings][:num_fmts]).to include(176 => 2, 177 => 2, 0 => 0)
    expect(result[:statistics][:removed][:cell_xfs]).to eq(1)
    expect(result[:statistics][:removed][:num_fmts]).to eq(3)
  end

  it 'is idempotent and keeps theme colors distinct from RGB colors' do
    rgb_blue = workbook.theme.get_theme_color(4).a_srgb_clr.val
    rgb_fill = solid_fill(RubyXL::Color.new(:rgb => rgb_blue))
    theme_fill = solid_fill(RubyXL::Color.new(:theme => 4))

    styles.fills << rgb_fill << theme_fill
    styles.cell_xfs = RubyXL::CellXFs.new(:_ => [
      xf(:fill_id => 2),
      xf(:fill_id => 3)
    ])

    worksheet = workbook[0]
    worksheet.add_cell(0, 0, 'rgb')
    worksheet.add_cell(1, 0, 'theme')
    worksheet[0][0].style_index = 0
    worksheet[1][0].style_index = 1

    first = workbook.compress_styles
    rgb_before = workbook.get_fill_color(styles.cell_xfs[worksheet[0][0].style_index])
    theme_before = workbook.get_fill_color(styles.cell_xfs[worksheet[1][0].style_index])
    expect(rgb_before.upcase).to eq(theme_before.upcase)

    second = workbook.compress_styles

    expect(styles.cell_xfs.size).to eq(2)
    expect(styles.fills.size).to eq(4)
    expect(first[:mappings][:cell_xfs]).to eq(0 => 0, 1 => 1)
    expect(second[:mappings][:cell_xfs]).to eq(0 => 0, 1 => 1)
    expect(second[:statistics][:removed].values).to all(eq(0))

    workbook.theme.a_theme_elements.a_clr_scheme.a_accent1.a_srgb_clr.val = '00AA00'
    expect(workbook.get_fill_color(styles.cell_xfs[worksheet[0][0].style_index])).to eq(rgb_before)
    expect(workbook.get_fill_color(styles.cell_xfs[worksheet[1][0].style_index])).not_to eq(theme_before)
  end

  it 'keeps theme, indexed, and RGB representations distinct and compresses dxfs separately' do
    styles.fills << solid_fill(RubyXL::Color.new(:theme => 4))
    styles.fills << solid_fill(RubyXL::Color.new(:indexed => 4))
    styles.fills << solid_fill(RubyXL::Color.new(:rgb => '4F81BD'))

    dxf_fill = solid_fill(RubyXL::Color.new(:rgb => 'FF0000'))
    dxf1 = RubyXL::DXF.new(:fill => dxf_fill)
    dxf2 = RubyXL::DXF.new(:fill => dxf_fill.dup)
    styles.dxfs = RubyXL::DXFs.new(:_ => [dxf1, dxf2])

    worksheet = workbook[0]
    worksheet.conditional_formatting = [
      RubyXL::ConditionalFormatting.new(:cf_rule => [
        RubyXL::ConditionalFormattingRule.new(:priority => 1, :dxf_id => 0),
        RubyXL::ConditionalFormattingRule.new(:priority => 2, :dxf_id => 1)
      ])
    ]

    workbook.compress_styles

    expect(styles.fills.size).to eq(5)
    expect(styles.dxfs.size).to eq(1)
    expect(worksheet.conditional_formatting[0].cf_rule[0].dxf_id).to eq(0)
    expect(worksheet.conditional_formatting[0].cf_rule[1].dxf_id).to eq(0)
  end

  it 'rewrites named style references after styleXfs compaction' do
    styles.cell_style_xfs = RubyXL::CellStyleXFs.new(:_ => [
      xf(:font_id => 0, :fill_id => 0, :border_id => 0, :alignment => RubyXL::Alignment.new(:wrap_text => true)),
      xf(:font_id => 0, :fill_id => 0, :border_id => 0, :alignment => RubyXL::Alignment.new(:wrap_text => true))
    ])
    styles.cell_styles = RubyXL::CellStyles.new(:_ => [
      RubyXL::CellStyle.new(:name => 'A', :xf_id => 0),
      RubyXL::CellStyle.new(:name => 'B', :xf_id => 1)
    ])

    result = workbook.compress_styles

    expect(styles.cell_style_xfs.size).to eq(1)
    expect(styles.cell_styles.map(&:xf_id)).to eq([0, 0])
    expect(result[:mappings][:style_xfs]).to eq(0 => 0, 1 => 0)
  end

  it 'resolves current theme colors to RGB only when theme preservation is disabled' do
    current_rgb = workbook.theme.get_theme_color(4).a_srgb_clr.val
    styles.fills << solid_fill(RubyXL::Color.new(:theme => 4, :tint => 0.0))
    styles.fills << solid_fill(RubyXL::Color.new(:rgb => current_rgb))
    styles.cell_xfs = RubyXL::CellXFs.new(:_ => [xf(:fill_id => 2), xf(:fill_id => 3)])

    result = workbook.compress_styles(:preserve_theme_colors => false)

    expect(styles.fills.size).to eq(3)
    expect(styles.cell_xfs.size).to eq(1)
    expect(result[:mappings][:cell_xfs]).to eq(0 => 0, 1 => 0)
    expect(styles.fills.find { |fill| fill&.pattern_fill&.fg_color&.rgb }.pattern_fill.fg_color.rgb).not_to be_nil
  end
end
