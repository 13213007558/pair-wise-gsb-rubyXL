# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'rubyXL/convenience_methods/worksheet'
require 'rubyXL/convenience_methods/workbook'

describe RubyXL::Worksheet do
  # Workbook layout ('Report' sheet):
  #   B2=10, C2=20, B3=30, C3==SUM(B2:C2)   <- moved block
  #   A5..A11: same-sheet formulas (see below)
  # 'Data Sheet'!A1/A2: cross-sheet formulas
  # Defined names: InputBlock (range), Inputs (union), Elsewhere (other sheet)
  def build_workbook
    workbook = RubyXL::Workbook.new
    report = workbook[0]
    report.sheet_name = 'Report'
    data = workbook.add_worksheet('Data Sheet')

    report.add_cell(1, 1, 10)
    report.add_cell(1, 2, 20)
    report.add_cell(2, 1, 30)
    report.add_cell(2, 2, 40, 'SUM(B2:C2)')

    report.add_cell(4, 0, 0, 'B2*2')              # relative, follows the move
    report.add_cell(5, 0, 0, '$B$2+$C$3')         # absolute, target moved so it moves too
    report.add_cell(6, 0, 0, 'SUM(B2:C3)')        # whole range inside
    report.add_cell(7, 0, 0, '"B2:C3"&"!"')       # string constant, must survive
    report.add_cell(8, 0, 0, 'SUM(B2:D4)')        # partial overlap, untouched
    report.add_cell(9, 0, 0, 'E5')                # points at overwritten destination
    report.add_cell(10, 0, 0, 'LOG10(B2)')        # function name is not a reference
    report.add_cell(11, 0, 0, "'Data Sheet'!A1")  # other sheet, untouched

    data.add_cell(0, 0, 0, 'Report!B2*3')
    data.add_cell(1, 0, 0, "'Report'!$C$3")

    workbook.define_new_name('InputBlock', 'Report!$B$2:$C$3')
    workbook.define_new_name('Inputs', 'Report!$B$2,Report!$C$3')
    workbook.define_new_name('Elsewhere', "'Data Sheet'!$A$1")

    [workbook, report, data]
  end

  def expect_moved_state(workbook, report, data)
    # Cell positions
    expect(report[4][4].value).to eq(10)
    expect(report[4][5].value).to eq(20)
    expect(report[5][4].value).to eq(30)
    expect(report[1][1]).to be_nil
    expect(report[1][2]).to be_nil
    expect(report[2][1]).to be_nil
    expect(report[2][2]).to be_nil

    # Formula inside the moved block travels unchanged
    expect(report[5][5].formula.expression).to eq('SUM(B2:C2)')

    # Same-sheet formulas
    expect(report[4][0].formula.expression).to eq('E5*2')
    expect(report[5][0].formula.expression).to eq('$E$5+$F$6')
    expect(report[6][0].formula.expression).to eq('SUM(E5:F6)')
    expect(report[7][0].formula.expression).to eq('"B2:C3"&"!"')
    expect(report[8][0].formula.expression).to eq('SUM(B2:D4)')
    expect(report[9][0].formula.expression).to eq('E5')
    expect(report[10][0].formula.expression).to eq('LOG10(E5)')
    expect(report[11][0].formula.expression).to eq("'Data Sheet'!A1")

    # Cross-sheet formulas
    expect(data[0][0].formula.expression).to eq('Report!E5*3')
    expect(data[1][0].formula.expression).to eq("'Report'!$F$6")

    # Defined names
    expect(workbook.get_defined_name('InputBlock').reference).to eq('Report!$E$5:$F$6')
    expect(workbook.get_defined_name('Inputs').reference).to eq('Report!$E$5,Report!$F$6')
    expect(workbook.get_defined_name('Elsewhere').reference).to eq("'Data Sheet'!$A$1")
  end

  describe '#move_range' do
    it 'moves cells and retargets formulas, cross-sheet references, and defined names' do
      workbook, report, data = build_workbook
      report.move_range('B2:C3', 'E5')
      expect_moved_state(workbook, report, data)
    end

    it 'accepts a same-sized range as destination' do
      workbook, report, data = build_workbook
      report.move_range('B2:C3', 'E5:F6')
      expect_moved_state(workbook, report, data)
    end

    it 'handles moves overlapping their own destination' do
      workbook = RubyXL::Workbook.new
      sheet = workbook[0]
      sheet.add_cell(1, 1, 10)
      sheet.add_cell(1, 2, 20)
      sheet.add_cell(2, 1, 30)
      sheet.add_cell(2, 2, 40, 'SUM(B2:C2)')
      sheet.add_cell(0, 0, 0, 'B2+1')

      sheet.move_range('B2:C3', 'C3')

      expect(sheet[2][2].value).to eq(10)
      expect(sheet[2][3].value).to eq(20)
      expect(sheet[3][2].value).to eq(30)
      expect(sheet[3][3].formula.expression).to eq('SUM(B2:C2)')
      expect(sheet[1][1]).to be_nil
      expect(sheet[1][2]).to be_nil
      expect(sheet[2][1]).to be_nil
      expect(sheet[0][0].formula.expression).to eq('C3+1')
    end

    it 'moves a block upwards and leftwards' do
      workbook = RubyXL::Workbook.new
      sheet = workbook[0]
      sheet.add_cell(5, 5, 99)
      sheet.add_cell(0, 0, 0, 'F6*2')

      sheet.move_range('F6', 'B2')

      expect(sheet[1][1].value).to eq(99)
      expect(sheet[5][5]).to be_nil
      expect(sheet[0][0].formula.expression).to eq('B2*2')
    end

    it 'rejects a destination range with different dimensions' do
      _, report, = build_workbook
      expect { report.move_range('B2:C3', 'E5:F7') }.to raise_error(ArgumentError)
    end

    it 'rejects moving a range across worksheets' do
      _, report, = build_workbook
      expect { report.move_range("'Data Sheet'!A1:B2", 'E5') }.to raise_error(ArgumentError)
      expect { report.move_range('B2:C3', "'Data Sheet'!E5") }.to raise_error(ArgumentError)
    end

    it 'rejects destinations outside the worksheet bounds' do
      _, report, = build_workbook
      expect { report.move_range('B2', 'XFE1') }.to raise_error(ArgumentError)
      expect { report.move_range('B2:C3', 'A1048576') }.to raise_error(ArgumentError)
    end

    context 'preflight rejection' do
      def expect_untouched(report, data, workbook)
        expect(report[1][1].value).to eq(10)
        expect(report[4][4]).to be_nil
        expect(report[4][0].formula.expression).to eq('B2*2')
        expect(data[0][0].formula.expression).to eq('Report!B2*3')
        expect(workbook.get_defined_name('InputBlock').reference).to eq('Report!$B$2:$C$3')
      end

      it 'refuses to move when the workbook contains array formulas' do
        workbook, report, data = build_workbook
        report.add_cell(6, 6, 0, 'B2')
        report[6][6].formula.t = 'array'

        expect { report.move_range('B2:C3', 'E5') }.to raise_error(/array/)
        expect_untouched(report, data, workbook)
      end

      it 'refuses to move when the workbook contains shared formulas' do
        workbook, report, data = build_workbook
        report.add_cell(6, 6, 0, 'B2')
        report[6][6].formula.t = 'shared'

        expect { report.move_range('B2:C3', 'E5') }.to raise_error(/shared/)
        expect_untouched(report, data, workbook)
      end

      it 'refuses to move when a formula uses table structured references' do
        workbook, report, data = build_workbook
        data.add_cell(5, 0, 0, 'SUM(Table1[Amount])')

        expect { report.move_range('B2:C3', 'E5') }.to raise_error(/structured|external/)
        expect_untouched(report, data, workbook)
      end

      it 'refuses to move when a formula uses external workbook links' do
        workbook, report, data = build_workbook
        data.add_cell(5, 0, 0, "'[1]Book'!A1")

        expect { report.move_range('B2:C3', 'E5') }.to raise_error(/structured|external/)
        expect_untouched(report, data, workbook)
      end

      it 'refuses to move when a defined name uses structured references' do
        workbook, report, data = build_workbook
        workbook.define_new_name('Tab', 'Table1[Amount]')

        expect { report.move_range('B2:C3', 'E5') }.to raise_error(/structured|external/)
        expect_untouched(report, data, workbook)
      end
    end

    context 'save and reload' do
      before do
        @file = File.expand_path("../../.tmp/move_range-#{$PROCESS_ID}.xlsx", __dir__)
      end

      after do
        FileUtils.rm_f(@file)
      end

      it 'preserves moved cells and retargeted formulas through a save/reload cycle' do
        workbook, report, data = build_workbook
        report.move_range('B2:C3', 'E5')
        workbook.write(@file)

        workbook2 = RubyXL::Parser.parse(@file)
        report2 = workbook2['Report']
        data2 = workbook2['Data Sheet']
        expect_moved_state(workbook2, report2, data2)
      end
    end
  end
end

describe RubyXL::FormulaShifter do
  subject(:shifter) { RubyXL::FormulaShifter.new('Sheet1', RubyXL::Reference.new('B2:C3'), 3, 3) }

  it 'shifts relative references inside the moved range' do
    expect(shifter.shift('B2+C3', 'Sheet1')).to eq('E5+F6')
  end

  it 'shifts absolute references because their target moved' do
    expect(shifter.shift('$B$2+$C3+B$2', 'Sheet1')).to eq('$E$5+$F6+E$5')
  end

  it 'shifts every member of a union expression' do
    expect(shifter.shift('SUM(B2,C3)', 'Sheet1')).to eq('SUM(E5,F6)')
  end

  it 'keeps references outside the moved range' do
    expect(shifter.shift('B1+C4', 'Sheet1')).to eq('B1+C4')
  end

  it 'keeps ranges that only partially overlap the moved range' do
    expect(shifter.shift('SUM(B2:D4)', 'Sheet1')).to eq('SUM(B2:D4)')
  end

  it 'keeps string constants that look like addresses' do
    expect(shifter.shift('"B2:C3"&B2', 'Sheet1')).to eq('"B2:C3"&E5')
  end

  it 'does not mistake function names for references' do
    expect(shifter.shift('LOG10(B2)', 'Sheet1')).to eq('LOG10(E5)')
  end

  it 'does not touch names that fall outside the A1 grid' do
    expect(shifter.shift('XFE1+B2', 'Sheet1')).to eq('XFE1+E5')
  end

  it 'only shifts references that resolve to the moved sheet' do
    expect(shifter.shift('B2', 'Other')).to eq('B2')
    expect(shifter.shift('Sheet2!B2', 'Sheet1')).to eq('Sheet2!B2')
    expect(shifter.shift('Sheet1!B2', 'Sheet1')).to eq('Sheet1!E5')
  end

  it 'handles quoted sheet names, including escaped quotes' do
    quoted = RubyXL::FormulaShifter.new("O'Brien", RubyXL::Reference.new('A1'), 1, 0)
    expect(quoted.shift("'O''Brien'!A1", 'Sheet1')).to eq("'O''Brien'!A2")
  end

  it 'detects unsupported structured and external references' do
    expect(RubyXL::FormulaShifter.unsupported_expression?('SUM(Table1[Amount])')).to be(true)
    expect(RubyXL::FormulaShifter.unsupported_expression?("'[1]Book'!A1")).to be(true)
    expect(RubyXL::FormulaShifter.unsupported_expression?('SUM(A1,"[not a ref]")')).to be(false)
    expect(RubyXL::FormulaShifter.unsupported_expression?('A1+B2')).to be(false)
  end
end
