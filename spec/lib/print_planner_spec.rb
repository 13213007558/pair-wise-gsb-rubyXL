# frozen_string_literal: true

require 'spec_helper'
require 'rubyXL/convenience_methods'

describe RubyXL::PrintPlanner do
  def sheet_with_grid(rows, columns)
    workbook = RubyXL::Workbook.new
    worksheet = workbook.worksheets[0]
    rows.times do |row|
      columns.times do |column|
        worksheet.add_cell(row, column, "#{column}:#{row}")
      end
    end
    worksheet
  end

  def plan_options(overrides = {})
    {
      :page_size_points => [100, 100],
      :margins_points => { :left => 10, :right => 10, :top => 10, :bottom => 10 }
    }.merge(overrides)
  end

  it 'reports one page when two columns exactly consume the fit capacity' do
    worksheet = sheet_with_grid(1, 2)

    plan = described_class.plan(worksheet, plan_options(
      :print_area => 'A1:B1',
      :fit => true,
      :fit_to_width => 1,
      :fit_to_height => 0,
      :column_widths_points => { 0 => 40, 1 => 40 }
    ))

    expect(plan[:feasible]).to eq(true)
    expect(plan[:page_count]).to eq(1)
    expect(plan[:actual_scale_percent]).to eq(100.0)
    expect(plan[:pages].first[:body_range]).to eq('A1:B1')
  end

  it 'finds the largest hundredth-percent scale when one point would not fit' do
    worksheet = sheet_with_grid(1, 2)

    plan = described_class.plan(worksheet, plan_options(
      :print_area => 'A1:B1',
      :fit => true,
      :fit_to_width => 1,
      :fit_to_height => 0,
      :column_widths_points => { 0 => 40, 1 => 40 }
    ))

    expect(plan[:actual_scale_percent]).to eq(100.0)

    tighter = described_class.plan(worksheet, plan_options(
      :print_area => 'A1:B1',
      :fit => true,
      :fit_to_width => 1,
      :fit_to_height => 0,
      :margins_points => { :left => 10, :right => 11, :top => 10, :bottom => 10 },
      :column_widths_points => { 0 => 40, 1 => 40 }
    ))

    expect(tighter[:feasible]).to eq(true)
    expect(tighter[:page_count]).to eq(1)
    expect(tighter[:actual_scale_percent]).to eq(98.75)
    expect(tighter[:scale_search][:step_percent]).to eq(0.01)
  end

  it 'keeps repeated titles out of the body range and reserves their scaled space' do
    worksheet = sheet_with_grid(4, 3)

    plan = described_class.plan(worksheet, plan_options(
      :print_area => 'B2:C4',
      :print_titles => '1:1,A:A',
      :fit => true,
      :fit_to_width => 1,
      :fit_to_height => 1
    ))

    page = plan[:pages].first
    expect(page[:body_range]).to eq('B2:C4')
    expect(page[:title_ranges].map { |title| title[:range] }).to eq(['B1:C1', 'A2:A4', 'A1:A1'])
    top_title = page[:title_ranges].find { |title| title[:kind] == :top }
    left_title = page[:title_ranges].find { |title| title[:kind] == :left }
    expect(top_title[:page_top_points]).to eq(10.0)
    expect(left_title[:page_left_points]).to eq(10.0)
    expect(page[:offset][:page_body_top_points]).to be > 10
    expect(page[:offset][:page_body_left_points]).to be > 10
  end

  it 'skips hidden rows and columns' do
    worksheet = sheet_with_grid(3, 3)
    worksheet.sheet_data.rows[1].hidden = true
    range = worksheet.cols.get_range(1)
    range.hidden = true

    plan = described_class.plan(worksheet, plan_options(
      :print_area => 'A1:C3',
      :scale => 100,
      :column_widths_points => { 0 => 40, 1 => 0, 2 => 40 }
    ))

    expect(plan[:pages].map { |page| page[:body_range] }).to eq(['A1:C3'])
  end

  it 'rejects fit-to-width when a manual column break forces more pages' do
    worksheet = sheet_with_grid(2, 4)
    worksheet.col_breaks = RubyXL::BreakList.new(:_ => [
      RubyXL::Break.new(:id => 1, :man => true),
      RubyXL::Break.new(:id => 3, :man => true)
    ])

    plan = described_class.plan(worksheet, plan_options(
      :print_area => 'A1:D2',
      :fit => true,
      :fit_to_width => 1,
      :fit_to_height => 0
    ))

    expect(plan[:feasible]).to eq(false)
    expect(plan[:conflict_reasons]).to include('manual column breaks require more pages than fitToWidth')
    expect(plan[:pages]).to eq([])
  end

  it 'honors a manual column break even when the selected scale would fit both columns' do
    worksheet = sheet_with_grid(2, 2)
    worksheet.col_breaks = RubyXL::BreakList.new(:_ => [
      RubyXL::Break.new(:id => 1, :man => true)
    ])

    plan = described_class.plan(worksheet, plan_options(
      :print_area => 'A1:B2',
      :scale => 100,
      :column_widths_points => { 0 => 40, 1 => 40 }
    ))

    expect(plan[:pages].map { |page| page[:body_range] }).to eq(['A1:A2', 'B1:B2'])
  end

  it 'orders tiles down first for downThenOver' do
    worksheet = sheet_with_grid(2, 2)

    plan = described_class.plan(worksheet, plan_options(
      :print_area => 'A1:B2',
      :scale => 100,
      :page_order => 'downThenOver',
      :column_widths_points => { 0 => 45, 1 => 45 },
      :row_heights_points => { 0 => 45, 1 => 45 }
    ))

    expect(plan[:pages].map { |page| page[:body_range] }).to eq(%w[A1:A1 A2:A2 B1:B1 B2:B2])
  end

  it 'paginates disjoint areas independently and orders tiles across then down' do
    worksheet = sheet_with_grid(10, 10)

    plan = described_class.plan(worksheet, plan_options(
      :print_area => 'A1:B2 D4:E5',
      :scale => 100,
      :page_order => 'overThenDown',
      :page_size_points => [100, 100],
      :margins_points => { :left => 10, :right => 10, :top => 10, :bottom => 10 },
      :column_widths_points => { 0 => 45, 1 => 45, 3 => 45, 4 => 45 },
      :row_heights_points => { 0 => 45, 1 => 45, 3 => 45, 4 => 45 }
    ))

    expect(plan[:pages].map { |page| page[:body_range] }).to eq(
      %w[A1:A1 B1:B1 A2:A2 B2:B2 D4:D4 E4:E4 D5:D5 E5:E5]
    )
    expect(plan[:pages].map { |page| [page[:area_index], page[:tile_column], page[:tile_row]] }).to eq([
      [0, 0, 0], [0, 1, 0], [0, 0, 1], [0, 1, 1],
      [1, 0, 0], [1, 1, 0], [1, 0, 1], [1, 1, 1]
    ])
  end
end
