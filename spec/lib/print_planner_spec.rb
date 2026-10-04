# frozen_string_literal: true

require 'spec_helper'
require 'rubyXL/convenience_methods/worksheet'
require 'rubyXL/convenience_methods/workbook'

describe RubyXL::PrintPlanner do
  let(:worksheet) do
    workbook = RubyXL::Workbook.new
    workbook[0]
  end

  let(:base_options) do
    {
      :mode => :scale,
      :scale => 100,
      :page_width => 100,
      :page_height => 100,
      :left => 0,
      :right => 0,
      :top => 0,
      :bottom => 0
    }
  end

  def plan(cells, overrides = {})
    cells.each { |row, column| worksheet.add_cell(row, column, 'x') }
    worksheet.print_plan(base_options.merge(overrides))
  end

  def square_grid(count, size)
    {
      :print_area => "A1:#{RubyXL::Reference.ind2ref(count - 1, count - 1)}",
      :row_heights => Array.new(count, size),
      :column_widths => Array.new(count, size)
    }
  end

  describe 'fixed-scale page slices' do
    it 'fits exactly at the printable width and height' do
      result = plan([[0, 0], [1, 1]], square_grid(2, 50))

      expect(result.pages.size).to eq(1)
      expect(result.pages.first.body_ranges.map(&:to_s)).to eq(['A1:B2'])
      expect(result.conflicts).to be_empty
    end

    it 'starts another page when either dimension is one point too large' do
      wide = plan([[0, 0], [0, 1]],
                  :print_area => 'A1:B1',
                  :row_heights => [50],
                  :column_widths => [50, 51])
      tall = plan([[0, 0], [1, 0]],
                  :print_area => 'A1:A2',
                  :row_heights => [50, 51],
                  :column_widths => [50])

      expect(wide.pages.map { |page| page.body_ranges.map(&:to_s) }).to eq([['A1'], ['B1']])
      expect(tall.pages.map { |page| page.body_ranges.map(&:to_s) }).to eq([['A1'], ['A2']])
    end

    it 'reserves title space without repeating a title row as body content' do
      result = plan([[0, 0], [1, 0], [2, 0]],
                    :print_area => 'A1:A3',
                    :repeat_rows => [0],
                    :row_heights => [21, 40, 40],
                    :column_widths => [80])

      expect(result.pages.size).to eq(2)
      expect(result.pages.first.title_row_ranges.map(&:to_s)).to eq(['A1'])
      expect(result.pages.first.body_ranges.map(&:to_s)).to eq(['A2'])
      expect(result.pages.last.body_ranges.map(&:to_s)).to eq(['A3'])
      expect(result.pages.first.body_top).to eq(21)
      expect(result.pages.first.row_offset).to eq(0)
      expect(result.pages.last.row_offset).to eq(40)
    end

    it 'excludes hidden rows and columns from used space but preserves body bounds' do
      result = plan([[0, 0], [0, 2]],
                    :print_area => 'A1:C1',
                    :repeat_columns => [0],
                    :hidden_columns => [1],
                    :row_heights => [50],
                    :column_widths => [50, 20, 50])

      page = result.pages.first
      expect(result.pages.size).to eq(1)
      expect(page.title_column_ranges.map(&:to_s)).to eq(['A1'])
      expect(page.body_ranges.map(&:to_s)).to eq(['C1'])
      expect(page.column_offset).to eq(0)
    end

    it 'reads hidden flags and manual break objects from the worksheet' do
      worksheet.add_cell(0, 0, 'x')
      worksheet.add_cell(1, 0, 'x')
      worksheet.add_cell(2, 0, 'x')
      worksheet[1].hidden = true
      worksheet.row_breaks = RubyXL::BreakList.new
      worksheet.row_breaks << RubyXL::Break.new(:id => 1, :man => true,
                                                :min => 0, :max => 16_383)

      result = worksheet.print_plan(base_options.merge(
        :print_area => 'A1:A3',
        :row_heights => [50, 1, 50],
        :column_widths => [50]
      ))

      expect(result.pages.size).to eq(2)
      expect(result.pages.flat_map { |page| page.body_ranges.map(&:to_s) })
        .to eq(['A1', 'A3'])
    end

    it 'reads workbook print title definitions and separates title ranges' do
      worksheet.workbook.define_new_name('_xlnm.Print_Titles', "#{worksheet.sheet_name}!$1:$1,$A:$A")
      worksheet.add_cell(0, 0, 'x')
      worksheet.add_cell(1, 1, 'x')

      result = worksheet.print_plan(base_options.merge(
        :print_area => 'B2:B2',
        :row_heights => [20, 40],
        :column_widths => [20, 60]
      ))

      page = result.pages.first
      expect(page.title_row_ranges.map(&:to_s)).to eq(['A1:B1'])
      expect(page.title_column_ranges.map(&:to_s)).to eq(['A1:A2'])
      expect(page.body_ranges.map(&:to_s)).to eq(['B2'])
    end
  end

  describe 'fit scale and manual breaks' do
    it 'uses the largest integer percentage that fits' do
      exact = plan([[0, 0], [0, 1]],
                   :mode => :fit,
                   :fit_to_width => 1,
                   :fit_to_height => 0,
                   :page_width => 99,
                   :print_area => 'A1:B1',
                   :row_heights => [10],
                   :column_widths => [75, 75])
      one_point_wider = plan([[0, 0], [0, 1]],
                             :mode => :fit,
                             :fit_to_width => 1,
                             :fit_to_height => 0,
                             :page_width => 99,
                             :print_area => 'A1:B1',
                             :row_heights => [10],
                             :column_widths => [75, 76])

      expect(exact.scale).to eq(66)
      expect(exact.pages.size).to eq(1)
      expect(one_point_wider.scale).to eq(65)
      expect(one_point_wider.pages.size).to eq(1)
    end

    it 'treats fit-mode manual breaks as hard one-page-band boundaries' do
      result = plan([[0, 0], [0, 1]],
                    :mode => :fit,
                    :fit_to_width => 1,
                    :fit_to_height => 0,
                    :print_area => 'A1:B1',
                    :row_heights => [10],
                    :column_widths => [80, 80],
                    :column_breaks => [1])

      expect(result.scale).to eq(100)
      expect(result.pages.size).to eq(2)
      expect(result.pages.map { |page| page.body_ranges.map(&:to_s) }).to eq([['A1'], ['B1']])
      expect(result.conflicts.map { |conflict| conflict[:reason] })
        .to eq([:manual_breaks_exceed_fit_to_width])
    end

    it 'reports a reason when more manual bands than fit pages are requested' do
      result = plan([[0, 0], [0, 1]],
                    :mode => :fit,
                    :fit_to_width => 1,
                    :fit_to_height => 0,
                    :print_area => 'A1:B1',
                    :row_heights => [10],
                    :column_widths => [150, 150],
                    :column_breaks => [1])

      expect(result.pages.size).to eq(2)
      expect(result.scale).to eq(66)
      expect(result.conflicts.map { |conflict| conflict[:reason] })
        .to eq([:manual_breaks_exceed_fit_to_width])
    end
  end

  describe 'multiple print areas' do
    it 'paginates each area independently and honors page order' do
      cells = [[0, 0], [1, 0], [0, 1], [1, 1], [0, 4], [1, 4], [0, 5], [1, 5]]
      options = {
        :print_area => 'E1:F2,A1:B2',
        :row_heights => [51, 51],
        :column_widths => [51, 51, 1, 1, 51, 51],
        :page_order => 'overThenDown'
      }
      result = plan(cells, options)

      ranges = result.pages.map { |page| page.body_ranges.map(&:to_s) }
      expect(ranges).to eq([['A1'], ['A2'], ['B1'], ['B2'],
                            ['E1'], ['E2'], ['F1'], ['F2']])
      expect(result.pages.map(&:print_area_index)).to eq([1, 1, 1, 1, 0, 0, 0, 0])
    end
  end
end
