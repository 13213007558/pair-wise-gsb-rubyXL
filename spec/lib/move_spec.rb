# frozen_string_literal: true

require 'spec_helper'
require 'rubyXL/convenience_methods/move'
require 'rubyXL/convenience_methods/workbook'
require 'rubyXL/convenience_methods/worksheet'

describe RubyXL::RangeMove do
  let(:workbook) { RubyXL::Workbook.new }
  let(:sheet1) { workbook.worksheets.first }
  let(:sheet2) { workbook.add_worksheet('Second') }

  def formula_at(ws, row, col)
    ws[row][col]&.formula&.expression
  end

  describe 'same-sheet move' do
    before do
      sheet1.add_cell(1, 1, 10)                 # B2
      sheet1.add_cell(1, 2, 20)                 # C2
      sheet1.add_cell(1, 3, nil, 'B2+C2')       # D2, inside the moved range
      sheet1.add_cell(0, 5, nil, 'B2*2')        # F1, outside
      sheet1.add_cell(0, 6, nil, '$B$2+$C2')    # G1, absolute refs outside
      sheet1.add_cell(0, 7, nil, '"B2="&B2')    # H1, string constant
    end

    it 'moves cell values and clears the source' do
      workbook.move_range('Sheet1!B2:D2', 'Sheet1!B5')
      expect(sheet1[4][1].value).to eq(10)
      expect(sheet1[4][2].value).to eq(20)
      expect(sheet1[1][1]).to be_nil
      expect(sheet1[1][2]).to be_nil
    end

    it 'updates formulas inside the moved range to follow their references' do
      workbook.move_range('Sheet1!B2:D2', 'Sheet1!B5')
      expect(formula_at(sheet1, 4, 3)).to eq('B5+C5')
    end

    it 'updates formulas outside the moved range that reference moved cells' do
      workbook.move_range('Sheet1!B2:D2', 'Sheet1!B5')
      expect(formula_at(sheet1, 0, 5)).to eq('B5*2')
    end

    it 'updates absolute ($) references, which only constrain copying, not moving' do
      workbook.move_range('Sheet1!B2:D2', 'Sheet1!B5')
      expect(formula_at(sheet1, 0, 6)).to eq('$B$5+$C5')
    end

    it 'does not touch A1-like text inside string constants' do
      workbook.move_range('Sheet1!B2:D2', 'Sheet1!B5')
      expect(formula_at(sheet1, 0, 7)).to eq('"B2="&B5')
    end

    it 'replaces existing contents of the destination' do
      sheet1.add_cell(4, 1, 99) # B5
      workbook.move_range('Sheet1!B2:D2', 'Sheet1!B5')
      expect(sheet1[4][1].value).to eq(10)
    end

    it 'is a no-op when the destination equals the source' do
      workbook.move_range('Sheet1!B2:D2', 'Sheet1!B2')
      expect(sheet1[1][1].value).to eq(10)
      expect(formula_at(sheet1, 0, 5)).to eq('B2*2')
    end

    it 'rejects a destination overlapping the source and leaves the workbook unchanged' do
      expect { workbook.move_range('Sheet1!B2:D2', 'Sheet1!C2') }.to raise_error(RubyXL::MoveError, /overlaps/)
      expect(sheet1[1][1].value).to eq(10)
      expect(formula_at(sheet1, 0, 5)).to eq('B2*2')
    end

    it 'leaves references to the destination area untouched' do
      sheet1.add_cell(0, 8, nil, 'B5*2') # I1 references the destination cell
      workbook.move_range('Sheet1!B2:D2', 'Sheet1!B5')
      expect(formula_at(sheet1, 0, 8)).to eq('B5*2')
    end
  end

  describe 'cross-sheet move' do
    before do
      sheet1.add_cell(1, 1, 10)            # B2
      sheet1.add_cell(1, 2, nil, 'B2*2')   # C2, moves along
      sheet2                               # make sure the sheet exists
    end

    it 'moves cells to the other sheet' do
      workbook.move_range('Sheet1!B2:C2', 'Second!E10')
      expect(sheet2[9][4].value).to eq(10)
      expect(sheet1[1][1]).to be_nil
    end

    it 'drops the sheet prefix when a reference becomes local' do
      sheet2.add_cell(0, 0, nil, 'Sheet1!B2+1')
      workbook.move_range('Sheet1!B2:C2', 'Second!E10')
      expect(formula_at(sheet2, 0, 0)).to eq('E10+1')
    end

    it 'keeps moved formulas local when their references moved along' do
      workbook.move_range('Sheet1!B2:C2', 'Second!E10')
      expect(formula_at(sheet2, 9, 5)).to eq('E10*2')
    end

    it 'qualifies references to unmoved cells when the formula moves to another sheet' do
      sheet1.add_cell(0, 0, 1)                 # A1, does not move
      sheet1.add_cell(2, 2, nil, 'A1+B2*2')    # C3, moves alone
      workbook.move_range('Sheet1!C3', 'Second!F10')
      expect(formula_at(sheet2, 9, 5)).to eq('Sheet1!A1+Sheet1!B2*2')
    end

    it 'rewrites references from other sheets with the new sheet name' do
      sheet2.add_cell(0, 0, nil, 'Sheet1!B2')
      workbook.move_range('Sheet1!B2:C2', 'Sheet1!E10')
      expect(formula_at(sheet2, 0, 0)).to eq('Sheet1!E10')
    end

    it 'does not rewrite local references on other sheets' do
      sheet2.add_cell(0, 0, nil, 'B2')
      workbook.move_range('Sheet1!B2:C2', 'Second!E10')
      expect(formula_at(sheet2, 0, 0)).to eq('B2')
    end
  end

  describe 'quoted sheet names' do
    let(:quoted) { workbook.add_worksheet('My Sheet') }

    it 'rewrites references with quoted sheet names' do
      quoted.add_cell(1, 1, 5)
      sheet1.add_cell(0, 0, nil, "='My Sheet'!B2*2")
      workbook.move_range("'My Sheet'!B2", "'My Sheet'!D9")
      expect(formula_at(sheet1, 0, 0)).to eq("='My Sheet'!D9*2")
    end

    it 'quotes sheet names with spaces when a prefix has to be added' do
      quoted.add_cell(1, 1, 5)
      quoted.add_cell(0, 0, nil, 'B2*3')
      workbook.move_range("'My Sheet'!B2", 'Sheet1!E5')
      expect(formula_at(quoted, 0, 0)).to eq('Sheet1!E5*3')
    end
  end

  describe 'range references' do
    it 'translates ranges fully contained in the moved range' do
      sheet1.add_cell(0, 0, nil, 'SUM(B2:D8)')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!F10')
      expect(formula_at(sheet1, 0, 0)).to eq('SUM(F10:H16)')
    end

    it 'splits partially intersecting ranges into a union of rectangles' do
      sheet1.add_cell(0, 0, nil, 'SUM(A1:C10)')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!F12')
      expect(formula_at(sheet1, 0, 0)).to eq('SUM(A1:C1,A9:C10,A2:A8,F12:G18)')
    end

    it 'splits full-column ranges' do
      sheet1.add_cell(0, 0, nil, 'SUM(B:B)')
      workbook.move_range('Sheet1!B2:B8', 'Sheet1!E2')
      expect(formula_at(sheet1, 0, 0)).to eq('SUM(B1,B9:B1048576,E2:E8)')
    end

    it 'translates fully contained full-column ranges' do
      sheet1.add_cell(0, 0, nil, 'SUM(B:B)')
      workbook.move_range('Sheet1!B1:B1048576', 'Sheet1!E1')
      expect(formula_at(sheet1, 0, 0)).to eq('SUM(E:E)')
    end

    it 'splits full-row ranges' do
      sheet1.add_cell(0, 0, nil, 'SUM(2:2)')
      workbook.move_range('Sheet1!B2:D2', 'Sheet1!B5')
      expect(formula_at(sheet1, 0, 0)).to eq('SUM(A2,E2:XFD2,B5:D5)')
    end
  end

  describe 'defined names' do
    it 'rewrites defined names that reference the moved range' do
      workbook.define_new_name('TEST', 'Sheet1!$B$2:$D$8')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!F10')
      expect(workbook.get_defined_name('TEST').reference).to eq('Sheet1!$F$10:$H$16')
    end

    it 'splits defined names that partially overlap the moved range' do
      workbook.define_new_name('TEST', 'Sheet1!$A$1:$C$3')
      workbook.move_range('Sheet1!B2:B2', 'Sheet1!F10')
      expect(workbook.get_defined_name('TEST').reference).to(
        eq('Sheet1!$A$1:$C$1,Sheet1!$A$3:$C$3,Sheet1!$A$2,Sheet1!$C$2,Sheet1!$F$10')
      )
    end

    it 'leaves unrelated defined names alone' do
      workbook.define_new_name('TEST', 'Sheet1!$A$1')
      workbook.move_range('Sheet1!B2:D8', 'Sheet1!F10')
      expect(workbook.get_defined_name('TEST').reference).to eq('Sheet1!$A$1')
    end
  end

  describe 'data validations' do
    it 'moves the sqref of a validation whose cells moved (same sheet)' do
      sheet1.add_validation_list('B2:B8', %w[a b c])
      workbook.move_range('Sheet1!B2:B8', 'Sheet1!E3')
      validation = sheet1.data_validations.first
      expect(validation.sqref.to_s).to eq('E3:E9')
      expect(validation.formula1.expression).to eq('"a,b,c"') # string constant untouched
    end

    it 'rewrites validation formulas referencing the moved range' do
      sheet1.data_validations = RubyXL::DataValidations.new
      sheet1.data_validations << RubyXL::DataValidation.new(
        :sqref => RubyXL::Reference.new('A1'),
        :formula1 => RubyXL::Formula.new(:expression => '$B$2:$B$8'),
        :type => 'list'
      )
      workbook.move_range('Sheet1!B2:B8', 'Sheet1!E3')
      expect(sheet1.data_validations.first.formula1.expression).to eq('$E$3:$E$9')
    end

    it 'splits a sqref that partially overlaps the moved range' do
      sheet1.add_validation_list('A1:C3', %w[a b])
      workbook.move_range('Sheet1!B2:B2', 'Sheet1!F10')
      expect(sheet1.data_validations.first.sqref.to_s).to eq('A1:C1 A3:C3 A2 C2 F10')
    end

    it 'moves the validation to the destination sheet on cross-sheet moves' do
      sheet2
      sheet1.add_validation_list('B2:B8', %w[a b c])
      workbook.move_range('Sheet1!B2:B8', 'Second!E3')
      expect(sheet1.data_validations).to be_empty
      expect(sheet2.data_validations.first.sqref.to_s).to eq('E3:E9')
    end

    it 'splits the validation across sheets when only part of it moves' do
      sheet2
      sheet1.add_validation_list('A1:B8', %w[a b])
      workbook.move_range('Sheet1!B2:B8', 'Second!E3')
      expect(sheet1.data_validations.first.sqref.to_s).to eq('A1:B1 A2:A8')
      expect(sheet2.data_validations.first.sqref.to_s).to eq('E3:E9')
    end

    it 'rejects validation formulas that partially overlap the moved range' do
      sheet1.data_validations = RubyXL::DataValidations.new
      sheet1.data_validations << RubyXL::DataValidation.new(
        :sqref => RubyXL::Reference.new('A1'),
        :formula1 => RubyXL::Formula.new(:expression => '$A$1:$C$10'),
        :type => 'list'
      )
      expect { workbook.move_range('Sheet1!B2:B8', 'Sheet1!F2') }.to raise_error(RubyXL::MoveError, /partially overlaps/)
    end
  end

  describe 'merged cells' do
    it 'translates merged ranges inside the moved range' do
      sheet1.merge_cells(1, 1, 2, 2) # B2:C3
      workbook.move_range('Sheet1!B2:C3', 'Sheet1!E5')
      expect(sheet1.merged_cells.first.ref.to_s).to eq('E5:F6')
    end

    it 'drops merged ranges that intersect the destination' do
      sheet1.merge_cells(4, 4, 5, 5) # E5:F6
      workbook.move_range('Sheet1!B2:C3', 'Sheet1!E5')
      expect(sheet1.merged_cells).to be_empty
    end

    it 'rejects merged ranges partially overlapping the source' do
      sheet1.merge_cells(1, 1, 3, 3) # B2:D4
      expect { workbook.move_range('Sheet1!B2:C3', 'Sheet1!F10') }.to raise_error(RubyXL::MoveError, /partially/)
    end
  end

  describe 'chart series formulas' do
    let(:chart_xml) { '<c:chartSpace><c:ser><c:cat><c:f>Sheet1!$B$2:$B$8</c:f></c:cat></c:ser></c:chartSpace>' }
    let(:chart) { RubyXL::ChartFile.new('xl/charts/chart1.xml', chart_xml) }

    before { sheet1.generic_storage << chart }

    it 'rewrites chart series references to the moved range' do
      workbook.move_range('Sheet1!B2:B8', 'Sheet1!E3')
      expect(chart.data).to include('<c:f>Sheet1!$E$3:$E$9</c:f>')
    end

    it 'rejects chart series that partially overlap the moved range' do
      chart
      expect { workbook.move_range('Sheet1!B2:B4', 'Sheet1!E3') }.to raise_error(RubyXL::MoveError, /partially overlaps/)
    end
  end

  describe 'unsupported references' do
    it 'reports external workbook references before changing anything' do
      sheet1.add_cell(1, 1, 10)
      sheet1.add_cell(0, 0, nil, 'B2')
      sheet2.add_cell(0, 0, nil, '[1]Sheet1!A1')
      expect { workbook.move_range('Sheet1!B2', 'Sheet1!E5') }.to raise_error(RubyXL::MoveError, /unsupported/)
      # The workbook is left untouched.
      expect(formula_at(sheet1, 0, 0)).to eq('B2')
      expect(sheet1[1][1].value).to eq(10)
    end

    it 'reports quoted external workbook references' do
      sheet1.add_cell(0, 0, nil, "'[1]My Book'!A1")
      expect { workbook.move_range('Sheet1!B2', 'Sheet1!E5') }.to raise_error(RubyXL::MoveError, /unsupported/)
    end

    it 'reports structured (table) references' do
      sheet1.add_cell(0, 0, nil, 'Table1[Col1]')
      expect { workbook.move_range('Sheet1!B2', 'Sheet1!E5') }.to raise_error(RubyXL::MoveError, /unsupported/)
    end

    it 'reports 3-D references' do
      sheet2
      sheet1.add_cell(0, 0, nil, 'SUM(Sheet1:Second!A1)')
      expect { workbook.move_range('Sheet1!B2', 'Sheet1!E5') }.to raise_error(RubyXL::MoveError, /unsupported/)
    end

    it 'reports all problems at once and keeps the workbook usable' do
      sheet1.add_cell(1, 1, 10)
      sheet1.add_cell(0, 0, nil, 'B2')
      sheet1.add_cell(0, 1, nil, '[2]Sheet1!A1')
      sheet1.add_cell(0, 2, nil, 'Table1[Col1]')
      expect { workbook.move_range('Sheet1!B2', 'Sheet1!E5') }.to raise_error(RubyXL::MoveError) { |error|
        expect(error.message).to include('[2]Sheet1!A1')
        expect(error.message).to include('Table1[Col1]')
      }
      expect(formula_at(sheet1, 0, 0)).to eq('B2')
      expect(sheet1[1][1].value).to eq(10)
    end
  end

  describe 'formula preservation' do
    it 'does not mistake function names or literals for references' do
      sheet1.add_cell(0, 0, nil, 'LOG10(B2)+TRUE')
      workbook.move_range('Sheet1!B2', 'Sheet1!B9')
      expect(formula_at(sheet1, 0, 0)).to eq('LOG10(B9)+TRUE')
    end

    it 'does not touch numbers, error literals or unknown sheets' do
      sheet1.add_cell(0, 0, nil, '1E5+#REF!+NoSheet!B2')
      workbook.move_range('Sheet1!B2', 'Sheet1!B9')
      expect(formula_at(sheet1, 0, 0)).to eq('1E5+#REF!+NoSheet!B2')
    end

    it 'does not touch defined names used in formulas' do
      sheet1.add_cell(0, 0, nil, 'MyName+B2')
      workbook.move_range('Sheet1!B2', 'Sheet1!B9')
      expect(formula_at(sheet1, 0, 0)).to eq('MyName+B9')
    end
  end

  describe 'shared and array formulas' do
    it 'translates the formula range when it moves along' do
      cell = sheet1.add_cell(1, 1, nil, 'C1')
      cell.formula.t = 'shared'
      cell.formula.ref = RubyXL::Reference.new('B2:B8')
      workbook.move_range('Sheet1!B2:B8', 'Sheet1!E3')
      expect(sheet1[2][4].formula.ref.to_s).to eq('E3:E9')
    end

    it 'rejects formula ranges partially overlapping the moved range' do
      cell = sheet1.add_cell(0, 0, nil, 'C1')
      cell.formula.t = 'array'
      cell.formula.ref = RubyXL::Reference.new('A1:C10')
      expect { workbook.move_range('Sheet1!B2:B8', 'Sheet1!F2') }.to raise_error(RubyXL::MoveError, /partially overlaps/)
    end
  end

  describe 'worksheet-level API' do
    it 'defaults the sheet to the worksheet itself' do
      sheet1.add_cell(1, 1, 10)
      sheet1.add_cell(0, 0, nil, 'B2')
      sheet1.move_range('B2', 'E5')
      expect(formula_at(sheet1, 0, 0)).to eq('E5')
      expect(sheet1[4][4].value).to eq(10)
    end
  end

  describe 'input validation' do
    it 'rejects unknown sheets' do
      expect { workbook.move_range('Nope!B2', 'Sheet1!E5') }.to raise_error(RubyXL::MoveError, /unknown source sheet/)
      expect { workbook.move_range('Sheet1!B2', 'Nope!E5') }.to raise_error(RubyXL::MoveError, /unknown destination sheet/)
    end

    it 'rejects non-single-cell destinations and unbounded sources' do
      expect { workbook.move_range('Sheet1!B2', 'Sheet1!E5:F6') }.to raise_error(RubyXL::MoveError)
      expect { workbook.move_range('Sheet1!B:B', 'Sheet1!E5') }.to raise_error(RubyXL::MoveError)
    end
  end

  describe 'save and reopen' do
    it 'preserves all rewritten references through a write/parse roundtrip' do
      quoted = workbook.add_worksheet('My Sheet')
      sheet1.add_cell(1, 1, 10)                    # B2
      sheet1.add_cell(1, 2, nil, 'B2*2')           # C2 moves along
      sheet1.add_cell(0, 0, nil, '$B$2+Second!A1') # absolute ref + cross-sheet ref
      sheet2.add_cell(0, 0, 5)                     # Second!A1
      quoted.add_cell(0, 0, nil, 'Sheet1!B2')
      workbook.define_new_name('TEST', 'Sheet1!$B$2')
      sheet1.add_validation_list('B2:B2', %w[a b])

      workbook.move_range('Sheet1!B2:C2', 'Sheet1!E5')

      reopened = RubyXL::Parser.parse_buffer(workbook.stream)
      rs1 = reopened['Sheet1']
      rs2 = reopened['Second']
      rq  = reopened['My Sheet']

      expect(rs1[4][4].value).to eq(10)                  # moved value at E5
      expect(rs1[1][1]).to be_nil                        # source cleared
      expect(rs1[4][5].formula.expression).to eq('E5*2') # moved formula
      expect(rs1[0][0].formula.expression).to eq('$E$5+Second!A1')
      expect(rq[0][0].formula.expression).to eq('Sheet1!E5')
      expect(reopened.get_defined_name('TEST').reference).to eq('Sheet1!$E$5')
      expect(rs1.data_validations.first.sqref.to_s).to eq('E5')
      expect(rs2[0][0].value).to eq(5)
      expect(reopened.calc_pr.full_calc_on_load).to eq(true)
    end
  end
end
