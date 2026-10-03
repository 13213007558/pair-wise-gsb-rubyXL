# frozen_string_literal: true

require 'spec_helper'
require 'rubyXL/convenience_methods/workbook'
require 'rubyXL/convenience_methods/color'

describe RubyXL::StyleCompressor do
  def xf(attrs = {})
    RubyXL::XF.new({ :num_fmt_id => 0, :font_id => 0, :fill_id => 0, :border_id => 0 }.merge(attrs))
  end

  def solid_fill(color)
    RubyXL::Fill.new(:pattern_fill => RubyXL::PatternFill.new(
      :pattern_type => 'solid', :fg_color => color))
  end

  def resolved_fill_rgb(workbook, style_index)
    styles = workbook.stylesheet
    cell_xf = styles.cell_xfs[style_index]
    styles.fills[cell_xf.fill_id].pattern_fill.fg_color.get_rgb(workbook)
  end

  let(:workbook) { RubyXL::Workbook.new }
  let(:styles) { workbook.stylesheet }

  describe '.compress' do
    it 'rejects unknown modes' do
      expect { described_class.compress(workbook, :nope) }.to raise_error(ArgumentError)
    end

    it 'merges equivalent custom number formats by format code and keeps built-ins' do
      styles.number_formats = RubyXL::NumberFormats.new(:_ => [
        RubyXL::NumberFormat.new(:num_fmt_id => 200, :format_code => '0.000'),
        RubyXL::NumberFormat.new(:num_fmt_id => 201, :format_code => '0.000')
      ])
      styles.cell_xfs.replace([xf, xf(:num_fmt_id => 200), xf(:num_fmt_id => 201)])

      result = workbook.compress_styles

      expect(result[:mappings][:num_fmts]).to eq(200 => 164, 201 => 164)
      expect(styles.number_formats.map(&:num_fmt_id)).to eq([164])
      expect(result[:mappings][:cell_xfs][1]).to eq(result[:mappings][:cell_xfs][2])
      expect(styles.cell_xfs.size).to eq(2)
    end

    it 'collapses a custom format code onto the built-in with the same code' do
      styles.number_formats = RubyXL::NumberFormats.new(:_ => [
        RubyXL::NumberFormat.new(:num_fmt_id => 180, :format_code => '0.00%')
      ])
      styles.cell_xfs.replace([xf, xf(:num_fmt_id => 180), xf(:num_fmt_id => 10)])

      result = workbook.compress_styles

      expect(result[:mappings][:num_fmts]).to eq(180 => 10)
      expect(styles.number_formats).to be_nil
      expect(result[:mappings][:cell_xfs][1]).to eq(result[:mappings][:cell_xfs][2])
    end

    it 'merges duplicate fonts, fills and borders by deep semantic content' do
      styles.fills << solid_fill(RubyXL::Color.new(:rgb => 'abcdef'))
      styles.fills << solid_fill(RubyXL::Color.new(:rgb => 'ABCDEF'))
      styles.cell_xfs.replace([xf, xf(:fill_id => 2), xf(:fill_id => 3)])

      result = workbook.compress_styles

      expect(result[:mappings][:fills][3]).to eq(2)
      expect(styles.fills.size).to eq(3)
      expect(result[:mappings][:cell_xfs][1]).to eq(result[:mappings][:cell_xfs][2])
    end

    it 'merges cellStyleXfs and rewrites cellStyles xfId' do
      styles.cell_style_xfs.replace([xf, xf, xf(:fill_id => 1)])
      styles.cell_styles.replace([
        RubyXL::CellStyle.new(:builtin_id => 0, :name => 'Normal', :xf_id => 1),
        RubyXL::CellStyle.new(:name => 'Other', :xf_id => 2)
      ])

      result = workbook.compress_styles

      expect(styles.cell_style_xfs.size).to eq(2)
      expect(result[:mappings][:cell_style_xfs]).to eq(0 => 0, 1 => 0, 2 => 1)
      expect(styles.cell_styles.map(&:xf_id)).to eq([0, 1])
    end

    it 'resolves cellXfs through xfId inheritance and apply flags' do
      styles.cell_style_xfs.replace([xf, xf(:font_id => 1, :fill_id => 1)])
      styles.cell_xfs.replace([
        xf,
        xf(:xf_id => 1),                                             # fully inherited
        xf(:xf_id => 1, :apply_font => false),                      # still inherited
        xf(:xf_id => 1, :font_id => 1, :fill_id => 1, :border_id => 0,
           :apply_font => true, :apply_fill => true,
           :apply_border => true, :apply_number_format => true), # repeats inheritance
        xf(:xf_id => 1, :font_id => 0, :fill_id => 1, :border_id => 0,
           :apply_font => true, :apply_fill => true,
           :apply_border => true, :apply_number_format => true)  # real override
      ])

      result = workbook.compress_styles
      map = result[:mappings][:cell_xfs]

      expect(map[1]).to eq(map[2])
      expect(map[2]).to eq(map[3])
      expect(map[4]).not_to eq(map[1])
    end

    it 'keeps implicit (no xfId) defaults distinct from named-style inheritance' do
      styles.cell_style_xfs.replace([xf(:font_id => 1)])
      styles.cell_xfs.replace([xf, xf(:xf_id => 0)])

      result = workbook.compress_styles

      expect(result[:mappings][:cell_xfs][1]).not_to eq(0)
    end

    it 'merges duplicate differential styles by their own semantics' do
      dxf1 = RubyXL::DXF.new(:font => RubyXL::Font.new(
        :color => RubyXL::Color.new(:rgb => 'ff0000')))
      dxf2 = RubyXL::DXF.new(:font => RubyXL::Font.new(
        :color => RubyXL::Color.new(:rgb => 'FF0000')))
      styles.dxfs = RubyXL::DXFs.new(:_ => [dxf1, dxf2])
      rule = RubyXL::ConditionalFormattingRule.new(:priority => 1, :dxf_id => 1)
      cf = RubyXL::ConditionalFormatting.new(:sqref => 'A1', :cf_rule => [rule])
      workbook[0].conditional_formatting = [cf]

      result = workbook.compress_styles

      expect(styles.dxfs.size).to eq(1)
      expect(result[:mappings][:dxfs]).to eq(0 => 0, 1 => 0)
      expect(rule.dxf_id).to eq(0)
    end

    it 'rewrites cell, row and column-default style references' do
      styles.cell_xfs.replace([xf, xf(:fill_id => 1), xf(:fill_id => 1)])
      sheet = workbook[0]
      sheet.add_cell(0, 0, 'a').style_index = 1
      sheet.add_cell(0, 1, 'b').style_index = 2
      sheet.sheet_data.rows[1] = RubyXL::Row.new(:style_index => 2)
      sheet.cols << RubyXL::ColumnRange.new(:min => 1, :max => 1, :style_index => 1)

      workbook.compress_styles

      expect(sheet[0][0].style_index).to eq(sheet[0][1].style_index)
      expect(sheet.sheet_data.rows[1].style_index).to eq(sheet[0][0].style_index)
      expect(sheet.cols[0].style_index).to eq(sheet[0][0].style_index)
    end

    it 'returns complete id mappings and compression statistics' do
      styles.fills << solid_fill(RubyXL::Color.new(:rgb => '112233'))
      styles.fills << solid_fill(RubyXL::Color.new(:rgb => '112233'))
      styles.cell_xfs.replace([xf, xf(:fill_id => 2), xf(:fill_id => 3)])

      result = workbook.compress_styles

      expect(result[:mappings].keys).to include(:num_fmts, :fonts, :fills, :borders,
                                           :cell_style_xfs, :cell_xfs, :dxfs)
      expect(result[:stats][:fills]).to eq(:before => 4, :after => 3, :removed => 1)
      expect(result[:stats][:cell_xfs]).to eq(:before => 3, :after => 2, :removed => 1)
      expect(result[:stats][:total][:removed]).to be > 0
    end

    it 'is idempotent: a second compression changes neither XML nor mappings' do
      styles.number_formats = RubyXL::NumberFormats.new(:_ => [
        RubyXL::NumberFormat.new(:num_fmt_id => 200, :format_code => '0.000'),
        RubyXL::NumberFormat.new(:num_fmt_id => 201, :format_code => '0.000')
      ])
      styles.fills << solid_fill(RubyXL::Color.new(:rgb => '112233'))
      styles.fills << solid_fill(RubyXL::Color.new(:rgb => '112233'))
      styles.cell_xfs.replace([xf, xf(:fill_id => 2, :num_fmt_id => 200),
                               xf(:fill_id => 3, :num_fmt_id => 201)])
      sheet = workbook[0]
      sheet.add_cell(0, 0, 'a').style_index = 1
      sheet.add_cell(0, 1, 'b').style_index = 2

      workbook.compress_styles
      xml_after_first = styles.write_xml
      cell_style_after_first = sheet[0][0].style_index
      second = workbook.compress_styles

      expect(styles.write_xml).to eq(xml_after_first)
      expect(sheet[0][0].style_index).to eq(cell_style_after_first)
      expect(second[:stats][:total][:removed]).to eq(0)
      second[:mappings].each_value do |map|
        map.each { |old_id, new_id| expect(new_id).to eq(old_id) }
      end
    end

    it 'does not fold a theme color into an equal-looking RGB in default mode' do
      styles.fills << solid_fill(RubyXL::Color.new(:theme => 4))
      styles.fills << solid_fill(RubyXL::Color.new(:rgb => '4F81BD'))
      styles.cell_xfs.replace([xf, xf(:fill_id => 2), xf(:fill_id => 3)])

      expect(resolved_fill_rgb(workbook, 1)).to eq('4f81bd')
      expect(resolved_fill_rgb(workbook, 2).downcase).to eq('4f81bd')

      result = workbook.compress_styles
      theme_index = result[:mappings][:cell_xfs][1]
      rgb_index   = result[:mappings][:cell_xfs][2]
      expect(theme_index).not_to eq(rgb_index)

      workbook.theme.a_theme_elements.a_clr_scheme.a_accent1.a_srgb_clr.val = 'FF0000'
      expect(resolved_fill_rgb(workbook, theme_index)).to eq('ff0000')
      expect(resolved_fill_rgb(workbook, rgb_index)).to eq('4F81BD')
    end

    it 'keeps tinted theme colors dependent on the theme' do
      styles.fills << solid_fill(RubyXL::Color.new(:theme => 4, :tint => 0.5))
      styles.fills << solid_fill(RubyXL::Color.new(:rgb => 'DCE6F1'))
      styles.cell_xfs.replace([xf, xf(:fill_id => 2), xf(:fill_id => 3)])

      result = workbook.compress_styles
      expect(result[:mappings][:cell_xfs][1]).not_to eq(result[:mappings][:cell_xfs][2])
    end

    it 'merges theme and RGB representations in :resolve_theme mode' do
      styles.fills << solid_fill(RubyXL::Color.new(:theme => 4))
      styles.fills << solid_fill(RubyXL::Color.new(:rgb => '4F81BD'))
      styles.cell_xfs.replace([xf, xf(:fill_id => 2), xf(:fill_id => 3)])

      result = workbook.compress_styles(:resolve_theme)

      expect(result[:mappings][:cell_xfs][1]).to eq(result[:mappings][:cell_xfs][2])
      merged = result[:mappings][:cell_xfs][1]
      workbook.theme.a_theme_elements.a_clr_scheme.a_accent1.a_srgb_clr.val = 'FF0000'
      expect(resolved_fill_rgb(workbook, merged)).to eq('4F81BD')
    end

    it 'pins indexes referenced by raw (unparsed) parts to their slots' do
      5.times { styles.fills << solid_fill(RubyXL::Color.new(:rgb => 'ABCDEF')) }
      xfs = [xf]
      (2..6).each { |fill_id| xfs << xf(:fill_id => fill_id) }
      styles.cell_xfs.replace(xfs)
      raw_table = '<table xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' \
                  '<tableColumns><tableColumn id="1" name="a" fillId="5" s="4"/>' \
                  '</tableColumns></table>'
      workbook.generic_storage = [RubyXL::TableFile.new('xl/tables/table1.xml', raw_table)]

      result = workbook.compress_styles

      expect(result[:mappings][:fills][5]).to eq(5)
      expect(result[:mappings][:fills][2]).to eq(5)
      expect(result[:mappings][:cell_xfs][4]).to eq(4)
    end
  end
end
