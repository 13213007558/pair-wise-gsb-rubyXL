# frozen_string_literal: true

require 'spec_helper'
require 'rubyXL/dynamic_array'

describe RubyXL::DynamicArray do
  let(:workbook) { RubyXL::Workbook.new }
  let(:worksheet) { workbook.worksheets.first }

  def cell_matrix(worksheet, rows, columns, start_row = 0, start_column = 0)
    Array.new(rows) do |row_index|
      Array.new(columns) do |column_index|
        worksheet[start_row + row_index]&.[](start_column + column_index)&.value
      end
    end
  end

  it 'grows, shrinks, and releases cells outside the cached spill' do
    worksheet.add_cell(4, 1, 2)
    worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(2-(B5=1),B5)')

    worksheet.recalculate_dynamic_arrays
    expect(cell_matrix(worksheet, 2, 2)).to eq([[1, 2], [3, 4]])

    worksheet.add_cell(4, 1, 3)
    worksheet.recalculate_dynamic_arrays
    expect(cell_matrix(worksheet, 2, 3)).to eq([[1, 2, 3], [4, 5, 6]])

    worksheet.add_cell(4, 1, 1)
    worksheet.recalculate_dynamic_arrays
    expect(worksheet[0][0].value).to eq(1)
    expect(worksheet[0][1]).to be_nil
    expect(worksheet[1][0]).to be_nil
    expect(worksheet[1][1]).to be_nil
    expect(worksheet[1][2]).to be_nil
  end

  it 'does not overwrite an occupied cell and leaves no new partial spill' do
    worksheet.add_cell(4, 1, 1)
    worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(B5,2)')
    worksheet.recalculate_dynamic_arrays
    expect(worksheet[0][0].value).to eq(1)

    worksheet.add_cell(4, 1, 2)
    worksheet.add_cell(1, 0, 'blocker')
    worksheet.recalculate_dynamic_arrays

    expect(worksheet[0][0].value).to eq('#SPILL!')
    expect(worksheet[0][0].datatype).to eq(RubyXL::DataType::ERROR)
    expect(worksheet[0][0].cm).to eq(1)
    expect(worksheet[1][0].value).to eq('blocker')
    expect(worksheet[0]&.[](1)).to be_nil
    expect(worksheet[1][1]).to be_nil
  end

  it 'returns #SPILL! when the target region intersects a merged cell' do
    worksheet.merged_cells = RubyXL::MergedCells.new
    worksheet.merged_cells << RubyXL::MergedCell.new(
      :ref => RubyXL::Reference.new(0, 1, 4, 5)
    )
    worksheet.set_dynamic_formula(0, 4, 'SEQUENCE(2,2)')

    worksheet.recalculate_dynamic_arrays

    expect(worksheet[0][4].value).to eq('#SPILL!')
    expect(worksheet[0][5]).to be_nil
    expect(worksheet[1]&.[](4)).to be_nil
  end

  it 'recalculates dependent spill anchors when an upstream shape changes' do
    worksheet.add_cell(3, 0, 3)
    worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(A4,1)')
    worksheet.set_dynamic_formula(0, 3, 'A1#*10')
    worksheet.set_dynamic_formula(0, 6, 'D1#+A1#')

    worksheet.recalculate_dynamic_arrays
    expect(cell_matrix(worksheet, 3, 1, 0, 3)).to eq([[10], [20], [30]])
    expect(cell_matrix(worksheet, 3, 1, 0, 6)).to eq([[11], [22], [33]])

    worksheet.add_cell(3, 0, 2)
    worksheet.recalculate_dynamic_arrays

    expect(worksheet[0][3].value).to eq(10)
    expect(worksheet[1][3].value).to eq(20)
    expect(worksheet[2][3]).to be_nil
    expect(worksheet[0][6].value).to eq(11)
    expect(worksheet[1][6].value).to eq(22)
    expect(worksheet[2][6]).to be_nil
  end

  it 'supports constants, transpose, filtering, and elementwise arithmetic' do
    worksheet.set_dynamic_formula(0, 0, '{1,2;3,4}*10')
    worksheet.set_dynamic_formula(0, 3, 'TRANSPOSE(A1#)')
    worksheet.set_dynamic_formula(0, 7, 'FILTER(A1#,{0;1})')
    worksheet.set_dynamic_formula(5, 0, 'FILTER(TRANSPOSE({1;2;3;4}),TRANSPOSE({1;2;3;4})>2)')

    worksheet.recalculate_dynamic_arrays

    expect(cell_matrix(worksheet, 2, 2)).to eq([[10, 20], [30, 40]])
    expect(cell_matrix(worksheet, 2, 2, 0, 3)).to eq([[10, 30], [20, 40]])
    expect(cell_matrix(worksheet, 1, 2, 0, 7)).to eq([[30, 40]])
    expect(cell_matrix(worksheet, 1, 2, 5, 0)).to eq([[3, 4]])
  end

  it 'reports cyclic A1# dependencies independently' do
    worksheet.set_dynamic_formula(0, 0, 'B1#')
    worksheet.set_dynamic_formula(0, 1, 'A1#+1')

    worksheet.recalculate_dynamic_arrays

    expect(worksheet[0][0].value).to eq('#CYCLE!')
    expect(worksheet[0][1].value).to eq('#CYCLE!')
  end

  it 'persists formulas, cached values, metadata, and spill ownership' do
    worksheet.add_cell(4, 1, 3)
    worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(2,B5)')
    worksheet.recalculate_dynamic_arrays

    output_path = File.join(Dir.tmpdir, "rubyxl-dynamic-#{Process.pid}.xlsx")
    workbook.save(output_path)
    reloaded = RubyXL::Parser.parse(output_path)
    reloaded_sheet = reloaded.worksheets.first

    expect(reloaded_sheet[0][0].formula.expression).to eq('SEQUENCE(2,B5)')
    expect(reloaded_sheet[0][0].formula.t).to eq('array')
    expect(reloaded_sheet[0][0].cm).to eq(0)
    expect(reloaded_sheet[1][2].value).to eq(6)
    expect(reloaded_sheet[1][2].vm).to eq(1)
    expect(reloaded_sheet[1][2].formula).to be_nil

    anchor = reloaded_sheet.dynamic_array_anchor_at(1, 2)
    expect(anchor[:row]).to eq(0)
    expect(anchor[:column]).to eq(0)
    expect(reloaded_sheet.dynamic_array_anchor?(0, 0)).to eq(true)
    expect(reloaded.sheet_metadata.data).to include('XLDAPR')
  ensure
    File.delete(output_path) if output_path && File.exist?(output_path)
  end
end
