# frozen_string_literal: true

require 'spec_helper'
require 'rubyXL/convenience_methods'
require 'tmpdir'

describe RubyXL::RangeMover do
  # Builds a workbook with:
  # * "Sheet1" - values 11..73 in the block B2:D8 (row * 10 + col)
  # * "My Sheet" - empty sheet with a name that requires quoting
  def build_workbook
    workbook = RubyXL::Workbook.new
    sheet1 = workbook.worksheets[0]
    sheet1.sheet_name = 'Sheet1'
    sheet2 = workbook.add_worksheet('My Sheet')

    (1..7).each do |row|
      (1..3).each do |col|
        sheet1.add_cell(row, col, row * 10 + col)
      end
    end

    [workbook, sheet1, sheet2]
  end

  def add_data_validation(sheet, sqref, formula1)
    validation = RubyXL::DataValidation.new
    validation.sqref = RubyXL::Sqref.new(sqref)
    validation.formula1 = RubyXL::Formula.new(:expression => formula1)
    sheet.data_validations ||= RubyXL::DataValidations.new
    sheet.data_validations << validation
    validation
  end

  def add_chart(sheet, series_formula)
    chart = RubyXL::ChartFile.new(
      Pathname.new('xl/charts/chart1.xml'),
      "<c:chartSpace><c:ser><c:val><c:numRef><c:f>#{series_formula}</c:f></c:numRef></c:val></c:ser></c:chartSpace>"
    )

    # Wire up worksheet -> drawing -> chart relationships so that the chart
    # survives a save/reload round-trip.
    drawing = RubyXL::DrawingFile.new(
      Pathname.new('xl/drawings/drawing1.xml'),
      '<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"/>'
    )
    drawing.relationship_container = RubyXL::OOXMLRelationshipsFile.new
    drawing.relationship_container.relationships << RubyXL::Relationship.new(
      :id => 'rId1', :type => RubyXL::ChartFile::REL_TYPE, :target => '../charts/chart1.xml'
    )
    drawing.generic_storage << chart

    sheet.relationship_container ||= RubyXL::OOXMLRelationshipsFile.new
    sheet.relationship_container.relationships << RubyXL::Relationship.new(
      :id => "rId#{sheet.relationship_container.relationships.size + 1}",
      :type => RubyXL::DrawingFile::REL_TYPE, :target => '../drawings/drawing1.xml'
    )
    sheet.generic_storage << drawing

    chart
  end

  def collect_charts(sheet)
    charts = []
    stack = sheet.generic_storage.dup
    until stack.empty?
      obj = stack.pop
      if obj.is_a?(RubyXL::ChartFile) then
        charts << obj
      elsif obj.respond_to?(:generic_storage) && obj.generic_storage then
        stack.concat(obj.generic_storage)
      end
    end
    charts
  end

  describe 'cell movement' do
    it 'moves cell values to the destination and clears the source' do
      _, sheet1, = build_workbook
      sheet1.move_range('B2:D8', 'G2')

      expect(sheet1[1][6].value).to eq(11)
      expect(sheet1[7][8].value).to eq(73)
      expect(sheet1[1][1]).to be_nil
      expect(sheet1[7][3]).to be_nil
    end

    it 'returns the destination reference' do
      workbook, = build_workbook
      expect(workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')).to eq(RubyXL::Reference.new('G2:I8'))
    end

    it 'accepts a destination range of matching size' do
      _, sheet1, = build_workbook
      sheet1.move_range('B2:D8', 'G2:I8')
      expect(sheet1[1][6].value).to eq(11)
    end

    it 'overwrites cells in the destination area' do
      _, sheet1, = build_workbook
      sheet1.add_cell(2, 7, 'old')
      sheet1.move_range('B2:D8', 'G2')
      expect(sheet1[2][7].value).to eq(22)
    end

    it 'moves cells to another worksheet' do
      workbook, sheet1, sheet2 = build_workbook
      workbook.move_range('Sheet1!B2:D8', "'My Sheet'!E5")

      expect(sheet2[4][4].value).to eq(11)
      expect(sheet2[10][6].value).to eq(73)
      expect(sheet1[1][1]).to be_nil
    end

    it 'rejects overlapping source and destination' do
      workbook, sheet1, = build_workbook
      expect { workbook.move_range('Sheet1!B2:D8', 'Sheet1!C3') }.to raise_error(ArgumentError)
      expect(sheet1[1][1].value).to eq(11)
      expect(sheet1[2][2].value).to eq(22)
    end

    it 'rejects a destination range of a different size' do
      workbook, = build_workbook
      expect { workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2:H8') }.to raise_error(ArgumentError)
    end

    it 'rejects unbounded source references' do
      workbook, = build_workbook
      expect { workbook.move_range('Sheet1!B:B', 'Sheet1!G2') }.to raise_error(ArgumentError)
      expect { workbook.move_range('Sheet1!2:2', 'Sheet1!G2') }.to raise_error(ArgumentError)
    end

    it 'rejects destinations outside the worksheet bounds' do
      workbook, = build_workbook
      expect { workbook.move_range('Sheet1!B2:D8', 'Sheet1!A1048575') }.to raise_error(ArgumentError)
    end

    it 'rejects an unknown worksheet' do
      workbook, = build_workbook
      expect { workbook.move_range('NoSuch!B2:D8', 'Sheet1!G2') }.to raise_error(ArgumentError)
    end

    it 'rejects an invalid on_partial option' do
      workbook, = build_workbook
      expect { workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2', :on_partial => :ignore) }
        .to raise_error(ArgumentError)
    end

    it 'moves a single cell' do
      workbook, sheet1, = build_workbook
      workbook.move_range('Sheet1!B2', 'Sheet1!G10')
      expect(sheet1[9][6].value).to eq(11)
      expect(sheet1[1][1]).to be_nil
    end

    it 'moves a range up and to the left' do
      workbook, sheet1, = build_workbook
      (9..15).each { |row| (6..8).each { |col| sheet1.add_cell(row, col, row * 100 + col) } }
      workbook.move_range('Sheet1!G10:I16', 'Sheet1!B2')
      expect(sheet1[1][1].value).to eq(906)
      expect(sheet1[7][3].value).to eq(1508)
      expect(sheet1[9][6]).to be_nil
    end

    it 'handles sheet names that require escaped quotes' do
      workbook, = build_workbook
      sheet = workbook.add_worksheet("O'Brien")
      sheet.add_cell(0, 0, 5)
      sheet.add_cell(1, 0, nil, "'O''Brien'!A1*2")
      workbook.move_range("O'Brien!A1", "O'Brien!C1")
      expect(sheet[0][2].value).to eq(5)
      expect(sheet[1][0].formula.expression).to eq("'O''Brien'!C1*2")
    end
  end

  describe 'formula rewriting' do
    it 'updates same-sheet range references to the moved range' do
      workbook, sheet1, = build_workbook
      sheet1.add_cell(0, 5, nil, 'SUM(B2:D8)')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(sheet1[0][5].formula.expression).to eq('SUM(G2:I8)')
    end

    it 'updates references in spite of $ anchors' do
      workbook, sheet1, = build_workbook
      sheet1.add_cell(0, 5, nil, '$B$2+$C3')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(sheet1[0][5].formula.expression).to eq('$G$2+$H3')
    end

    it 'updates cross-sheet references' do
      workbook, _, sheet2 = build_workbook
      sheet2.add_cell(0, 0, nil, 'Sheet1!B2*2')
      sheet2.add_cell(1, 0, nil, "'Sheet1'!C3")
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(sheet2[0][0].formula.expression).to eq('Sheet1!G2*2')
      expect(sheet2[1][0].formula.expression).to eq('Sheet1!H3')
    end

    it 'keeps explicit same-sheet qualifications intact' do
      workbook, sheet1, = build_workbook
      sheet1.add_cell(0, 0, nil, 'Sheet1!$B$2')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(sheet1[0][0].formula.expression).to eq('Sheet1!$G$2')
    end

    it 'updates references to a moved range on a sheet whose name needs quoting' do
      workbook, sheet1, sheet2 = build_workbook
      (0..2).each { |i| sheet2.add_cell(i, 0, i + 1) }
      sheet1.add_cell(0, 0, nil, "SUM('My Sheet'!A1:A3)")
      workbook.move_range("'My Sheet'!A1:A3", "'My Sheet'!C5")
      expect(sheet1[0][0].formula.expression).to eq("SUM('My Sheet'!C5:C7)")
    end

    it 'does not touch references to other sheets at the same address' do
      workbook, sheet1, sheet2 = build_workbook
      sheet2.add_cell(1, 1, 'other')
      sheet1.add_cell(0, 0, nil, "'My Sheet'!B2")
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(sheet1[0][0].formula.expression).to eq("'My Sheet'!B2")
    end

    it 'updates references inside moved cells that point at moved cells' do
      workbook, sheet1, = build_workbook
      sheet1.add_cell(1, 1, nil, 'C2')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(sheet1[1][6].formula.expression).to eq('H2')
    end

    it 'leaves references from moved cells to unmoved cells unchanged' do
      workbook, sheet1, = build_workbook
      sheet1.add_cell(1, 1, nil, 'A1')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(sheet1[1][6].formula.expression).to eq('A1')
    end

    it 'does not touch references to the destination area' do
      workbook, sheet1, = build_workbook
      sheet1.add_cell(0, 0, nil, 'G2+H3')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(sheet1[0][0].formula.expression).to eq('G2+H3')
    end

    it 'does not touch A1-like text inside string constants' do
      workbook, sheet1, = build_workbook
      sheet1.add_cell(0, 0, nil, '"B2:D8"&"Sheet1!B2"')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(sheet1[0][0].formula.expression).to eq('"B2:D8"&"Sheet1!B2"')
    end

    it 'does not mistake function names or number literals for references' do
      workbook, sheet1, = build_workbook
      sheet1.add_cell(0, 0, nil, 'LOG10(B2)+1E5')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(sheet1[0][0].formula.expression).to eq('LOG10(G2)+1E5')
    end

    it 'leaves whole-column references alone' do
      workbook, sheet1, = build_workbook
      sheet1.add_cell(0, 0, nil, 'SUM(B:B)')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(sheet1[0][0].formula.expression).to eq('SUM(B:B)')
    end

    it 'splits ranges that partially overlap the moved range' do
      workbook, sheet1, = build_workbook
      sheet1.add_cell(0, 0, nil, 'SUM(B2:B10)')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(sheet1[0][0].formula.expression).to eq('SUM(G2:G8,B9:B10)')
    end

    it 'splits two-dimensional partial overlaps into a union of rectangles' do
      workbook, sheet1, = build_workbook
      sheet1.add_cell(0, 0, nil, 'SUM(A1:C3)')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(sheet1[0][0].formula.expression).to eq('SUM(G2:H3,A1:C1,A2:A3)')
    end

    it 'can reject partial overlaps instead of splitting' do
      workbook, sheet1, = build_workbook
      sheet1.add_cell(0, 0, nil, 'SUM(B2:B10)')
      expect { workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2', :on_partial => :raise) }
        .to raise_error(RubyXL::MoveRangeError, /partially overlaps/)
      expect(sheet1[0][0].formula.expression).to eq('SUM(B2:B10)')
      expect(sheet1[1][1].value).to eq(11)
    end

    it 'requalifies references when moving to another worksheet' do
      workbook, sheet1, sheet2 = build_workbook
      sheet1.add_cell(0, 0, nil, 'B2')
      sheet2.add_cell(0, 0, nil, 'Sheet1!C3')
      workbook.move_range('Sheet1!B2:D8', "'My Sheet'!E5")
      expect(sheet1[0][0].formula.expression).to eq("'My Sheet'!E5")
      expect(sheet2[0][0].formula.expression).to eq("'My Sheet'!F6")
    end
  end

  describe 'defined names' do
    it 'updates defined names that reference the moved range' do
      workbook, = build_workbook
      workbook.define_new_name('MyRange', 'Sheet1!$B$2:$D$8')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(workbook.get_defined_name('MyRange').reference).to eq('Sheet1!$G$2:$I$8')
    end

    it 'splits defined names that partially overlap the moved range' do
      workbook, = build_workbook
      workbook.define_new_name('Partial', 'Sheet1!$B$2:$D$10')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(workbook.get_defined_name('Partial').reference).to eq('Sheet1!$G$2:$I$8,Sheet1!$B$9:$D$10')
    end

    it 'updates local defined names with unqualified references' do
      workbook, = build_workbook
      workbook.defined_names = RubyXL::DefinedNames.new
      workbook.defined_names << RubyXL::DefinedName.new(
        :name => 'Local', :reference => '$B$2:$D$8', :local_sheet_id => '0'
      )
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(workbook.defined_names['Local'].reference).to eq('$G$2:$I$8')
    end
  end

  describe 'data validations' do
    it 'updates validation formulas and sqref on the same sheet' do
      workbook, sheet1, = build_workbook
      validation = add_data_validation(sheet1, 'B2:D8', '$B$2')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(validation.sqref.to_s).to eq('G2:I8')
      expect(validation.formula1.expression).to eq('$G$2')
    end

    it 'splits a partially overlapping validation sqref' do
      workbook, sheet1, = build_workbook
      validation = add_data_validation(sheet1, 'B2:B10', '$B$2')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(validation.sqref.to_s).to eq('G2:G8 B9:B10')
    end

    it 'moves validations with the cells on cross-sheet moves' do
      workbook, sheet1, sheet2 = build_workbook
      validation = add_data_validation(sheet1, 'B2:D8', '$B$2')
      workbook.move_range('Sheet1!B2:D8', "'My Sheet'!E5")
      expect(sheet1.data_validations.size).to eq(0)
      expect(sheet2.data_validations.size).to eq(1)
      expect(sheet2.data_validations[0].sqref.to_s).to eq('E5:G11')
      expect(validation.formula1.expression).to eq("'My Sheet'!$E$5")
    end
  end

  describe 'chart series formulas' do
    it 'rewrites chart series references' do
      workbook, sheet1, = build_workbook
      chart = add_chart(sheet1, 'Sheet1!$B$2:$B$8')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')
      expect(chart.data).to include('Sheet1!$G$2:$G$8')
    end
  end

  describe 'unsupported references' do
    it 'reports external references before changing anything' do
      workbook, sheet1, = build_workbook
      sheet1.add_cell(0, 0, nil, '[1]Sheet1!A1')
      expect { workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2') }
        .to raise_error(RubyXL::MoveRangeError, /external|unsupported/)
      expect(sheet1[1][1].value).to eq(11)
      expect(sheet1[0][0].formula.expression).to eq('[1]Sheet1!A1')
    end

    it 'reports structured (table) references' do
      workbook, sheet1, = build_workbook
      sheet1.add_cell(0, 0, nil, 'SUM(Table1[Col1])')
      expect { workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2') }
        .to raise_error(RubyXL::MoveRangeError)
      expect(sheet1[1][1].value).to eq(11)
    end

    it 'reports 3D references' do
      workbook, sheet1, = build_workbook
      sheet1.add_cell(0, 0, nil, "SUM(Sheet1:'My Sheet'!A1)")
      expect { workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2') }
        .to raise_error(RubyXL::MoveRangeError)
      expect(sheet1[1][1].value).to eq(11)
    end
  end

  describe 'round-trip through save and reload' do
    it 'preserves cells and rewritten references' do
      workbook, sheet1, sheet2 = build_workbook
      sheet1.add_cell(0, 5, nil, 'SUM(B2:D8)') # formula outside the moved region
      sheet1.add_cell(1, 1, nil, 'C2')         # formula inside the moved region
      sheet1.add_cell(0, 6, nil, '$B$2')
      sheet2.add_cell(0, 0, nil, "'Sheet1'!C3")
      workbook.define_new_name('MyRange', 'Sheet1!$B$2:$D$8')
      add_data_validation(sheet1, 'B2:D8', '$B$2')
      add_chart(sheet1, 'Sheet1!$B$2:$B$8')

      workbook.move_range('Sheet1!B2:D8', 'Sheet1!G2')

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'moved.xlsx')
        workbook.write(path)
        reloaded = RubyXL::Parser.parse(path)

        rs1 = reloaded['Sheet1']
        rs2 = reloaded['My Sheet']

        expect(rs1[0][5].formula.expression).to eq('SUM(G2:I8)')
        expect(rs1[1][6].formula.expression).to eq('H2')
        expect(rs1[0][6].formula.expression).to eq('$G$2')
        expect(rs2[0][0].formula.expression).to eq('Sheet1!H3')
        expect(reloaded.get_defined_name('MyRange').reference).to eq('Sheet1!$G$2:$I$8')
        expect(rs1.data_validations[0].sqref.to_s).to eq('G2:I8')
        expect(rs1.data_validations[0].formula1.expression).to eq('$G$2')
        expect(rs1[2][7].value).to eq(22)
        expect(rs1[1][1]).to be_nil
        expect(collect_charts(rs1)[0].data).to include('Sheet1!$G$2:$G$8')
        expect(reloaded.calc_pr.full_calc_on_load).to eq(true)
      end
    end
  end
end
