# frozen_string_literal: true

require 'spec_helper'
require 'rubyXL/convenience_methods/workbook'
require 'rubyXL/convenience_methods/move_range'

describe RubyXL::Worksheet do
  let(:workbook) { RubyXL::Workbook.new }
  let!(:sheet1) { workbook[0] } # The default 'Sheet1' created with the workbook
  let!(:sheet2) { workbook.add_worksheet('Sheet2') }

  def build_source_block(sheet)
    sheet.add_cell(0, 0, 1)
    sheet.add_cell(0, 1, 2)
    sheet.add_cell(1, 0, 3)
    sheet.add_cell(1, 1, 4, 'A1*2') # Formula inside the moved range
  end

  describe '.move_range' do
    before { build_source_block(sheet1) }

    it 'relocates the cells and clears the source range' do
      sheet1.move_range('A1:B2', 'D5')

      expect(sheet1[0][0]).to be_nil
      expect(sheet1[0][1]).to be_nil
      expect(sheet1[1][0]).to be_nil
      expect(sheet1[1][1]).to be_nil

      expect(sheet1[4][3].value).to eq(1)
      expect(sheet1[4][4].value).to eq(2)
      expect(sheet1[5][3].value).to eq(3)
      expect(sheet1[5][4].value).to eq(4)
    end

    it 'updates the coordinates of the moved cells' do
      sheet1.move_range('A1:B2', 'D5')

      expect(sheet1[4][3].row).to eq(4)
      expect(sheet1[4][3].column).to eq(3)
      expect(sheet1[5][4].row).to eq(5)
      expect(sheet1[5][4].column).to eq(4)
    end

    it 'returns the new location of the range' do
      result = sheet1.move_range('A1:B2', 'D5')
      expect(result).to eq(RubyXL::Reference.new('D5:E6'))
    end

    it 'accepts RubyXL::Reference objects as arguments' do
      sheet1.move_range(RubyXL::Reference.new('A1:B2'), RubyXL::Reference.new('D5'))
      expect(sheet1.cell_at('A1')).to be_nil
      expect(sheet1.cell_at('D5').value).to eq(1)
    end

    it 'invalidates the calculation chain' do
      workbook.calculation_chain = RubyXL::CalculationChain.new
      sheet1.move_range('A1:B2', 'D5')
      expect(workbook.calculation_chain).to be_nil
      expect { workbook.stream }.not_to raise_error
    end

    it 'keeps formulas inside the moved cells verbatim' do
      sheet1.move_range('A1:B2', 'D5')
      expect(sheet1[5][4].formula.expression).to eq('A1*2')
    end

    it 'redirects same-sheet references, relative and absolute alike' do
      sheet1.add_cell(3, 0, nil, 'A1')
      sheet1.add_cell(4, 0, nil, '$A$1+$B$2')
      sheet1.add_cell(5, 0, nil, 'SUM(A1:B2)')

      sheet1.move_range('A1:B2', 'D5')

      expect(sheet1[3][0].formula.expression).to eq('D5')
      expect(sheet1[4][0].formula.expression).to eq('$D$5+$E$6')
      expect(sheet1[5][0].formula.expression).to eq('SUM(D5:E6)')
    end

    it 'leaves references to unmoved cells alone' do
      sheet1.add_cell(3, 0, nil, 'C1+A3')
      sheet1.move_range('A1:B2', 'D5')
      expect(sheet1[3][0].formula.expression).to eq('C1+A3')
    end

    it 'leaves references to the overwritten destination cells alone' do
      sheet1.add_cell(3, 0, nil, 'D5+E6')
      sheet1.move_range('A1:B2', 'D5')
      expect(sheet1[3][0].formula.expression).to eq('D5+E6')
    end

    it 'redirects cross-sheet references on other worksheets' do
      sheet2.add_cell(0, 0, nil, 'Sheet1!A1')
      sheet2.add_cell(1, 0, nil, 'Sheet1!$A$1:$B$2')

      sheet1.move_range('A1:B2', 'D5')

      expect(sheet2[0][0].formula.expression).to eq('Sheet1!D5')
      expect(sheet2[1][0].formula.expression).to eq('Sheet1!$D$5:$E$6')
    end

    it 'does not touch references to other worksheets' do
      sheet2.add_cell(0, 0, 10)
      sheet1.add_cell(3, 0, nil, 'Sheet2!A1')
      sheet1.move_range('A1:B2', 'D5')
      expect(sheet1[3][0].formula.expression).to eq('Sheet2!A1')
    end

    it 'handles quoted sheet names, including escaped quotes' do
      spaced = workbook.add_worksheet('My Sheet')
      build_source_block(spaced)
      sheet2.add_cell(0, 0, nil, %q{'My Sheet'!A1})

      spaced.move_range('A1:B2', 'D5')

      expect(sheet2[0][0].formula.expression).to eq(%q{'My Sheet'!D5})
    end

    it 'handles sheet names with apostrophes' do
      apostrophe = workbook.add_worksheet("It's")
      build_source_block(apostrophe)
      sheet2.add_cell(0, 0, nil, %q{'It''s'!A1})

      apostrophe.move_range('A1:B2', 'D5')

      expect(sheet2[0][0].formula.expression).to eq(%q{'It''s'!D5})
    end

    it 'redirects union references member by member' do
      sheet1.add_cell(3, 0, nil, 'SUM(A1,C3)')
      sheet1.move_range('A1:B2', 'D5')
      expect(sheet1[3][0].formula.expression).to eq('SUM(D5,C3)')
    end

    it 'splits partially overlapping ranges into a union' do
      sheet1.add_cell(3, 0, nil, 'SUM(A1:B3)')
      sheet1.move_range('A1:B2', 'D5')
      expect(sheet1[3][0].formula.expression).to eq('SUM(A3:B3,D5:E6)')
    end

    it 'preserves string constants that look like references' do
      sheet1.add_cell(3, 0, nil, '"A1"&"Sheet1!B2"&A1')
      sheet1.move_range('A1:B2', 'D5')
      expect(sheet1[3][0].formula.expression).to eq('"A1"&"Sheet1!B2"&D5')
    end

    it 'does not mistake function names for references' do
      sheet1.add_cell(3, 0, nil, 'LOG10(A1)+ABS(B2)')
      sheet1.move_range('A1:B2', 'D5')
      expect(sheet1[3][0].formula.expression).to eq('LOG10(D5)+ABS(E6)')
    end

    it 'redirects workbook-level defined names' do
      workbook.define_new_name('MyRange', 'Sheet1!$A$1:$B$2')
      workbook.define_new_name('Elsewhere', 'Sheet2!$A$1')

      sheet1.move_range('A1:B2', 'D5')

      expect(workbook.get_defined_name('MyRange').reference).to eq('Sheet1!$D$5:$E$6')
      expect(workbook.get_defined_name('Elsewhere').reference).to eq('Sheet2!$A$1')
    end

    it 'supports moving a range onto itself overlapping area' do
      sheet1.move_range('A1:B2', 'B2')

      expect(sheet1[0][0]).to be_nil
      expect(sheet1[0][1]).to be_nil
      expect(sheet1[1][0]).to be_nil

      expect(sheet1[1][1].value).to eq(1)
      expect(sheet1[1][2].value).to eq(2)
      expect(sheet1[2][1].value).to eq(3)
      expect(sheet1[2][2].value).to eq(4)
    end

    it 'redirects references to cells covered by an overlapping move' do
      sheet1.add_cell(3, 0, nil, 'B2')
      sheet1.move_range('A1:B2', 'B2')
      expect(sheet1[3][0].formula.expression).to eq('C3')
    end

    it 'raises ArgumentError when the destination is out of bounds' do
      expect { sheet1.move_range('A1:A1', 'A0') }.to raise_error(ArgumentError)
    end

    it 'raises ArgumentError if source and destination are identical' do
      expect { sheet1.move_range('A1:B2', 'A1') }.to raise_error(ArgumentError)
    end

    it 'raises ArgumentError for an invalid source range' do
      expect { sheet1.move_range('nonsense', 'D5') }.to raise_error(ArgumentError)
    end

    it 'raises ArgumentError when the destination is on another worksheet' do
      expect { sheet1.move_range('A1:B2', 'Sheet2!D5') }.to raise_error(ArgumentError)
    end

    it 'raises ArgumentError when the source is on another worksheet' do
      expect { sheet1.move_range('Sheet2!A1:B2', 'D5') }.to raise_error(ArgumentError)
    end

    describe 'pre-flight checks' do
      it 'rejects the whole move if any formula is an array formula' do
        sheet2.add_cell(0, 0, nil, 'A1')
        sheet2[0][0].formula.t = 'array'

        expect { sheet1.move_range('A1:B2', 'D5') }.to raise_error(/array/)
        expect(sheet1[0][0].value).to eq(1) # Nothing was moved
        expect(sheet1.cell_at('D5')).to be_nil
      end

      it 'rejects the whole move if any formula is a shared formula' do
        sheet2.add_cell(0, 0, nil, 'A1')
        sheet2[0][0].formula.t = 'shared'

        expect { sheet1.move_range('A1:B2', 'D5') }.to raise_error(/shared/)
        expect(sheet1[0][0].value).to eq(1)
      end

      it 'rejects the whole move if any formula uses structured references' do
        sheet2.add_cell(0, 0, nil, 'SUM(Table1[Amount])')

        expect { sheet1.move_range('A1:B2', 'D5') }.to raise_error(/structured/)
        expect(sheet1[0][0].value).to eq(1)
      end

      it 'rejects the whole move if a worksheet contains tables' do
        sheet1.table_parts = RubyXL::TableParts.new
        sheet1.table_parts << RubyXL::RID.new(:r_id => 'rId1')

        expect { sheet1.move_range('A1:B2', 'D5') }.to raise_error(/tables/)
        expect(sheet1[0][0].value).to eq(1)
      end
    end

    describe 'save and reload' do
      let(:file_path) { File.expand_path('../../tmp/move_range_spec.xlsx', __dir__) }

      after { File.delete(file_path) if File.exist?(file_path) }

      it 'preserves cell positions, formulas and defined names through a roundtrip' do
        build_source_block(sheet1)
        sheet1.add_cell(3, 0, nil, 'A1')
        sheet1.add_cell(4, 0, nil, '$A$1+$B$2')
        sheet1.add_cell(5, 0, nil, 'SUM(A1:B2)')
        sheet1.add_cell(6, 0, nil, 'SUM(A1,C3)')
        sheet1.add_cell(7, 0, nil, '"A1"&A1')
        sheet1.add_cell(8, 0, nil, 'C1')
        sheet1.add_cell(9, 0, nil, 'D5')
        sheet2.add_cell(0, 0, nil, 'Sheet1!A1')
        sheet2.add_cell(1, 0, nil, 'Sheet1!$A$1:$B$2')
        workbook.define_new_name('MyRange', 'Sheet1!$A$1:$B$2')

        sheet1.move_range('A1:B2', 'D5')
        workbook.save(file_path)

        reloaded = RubyXL::Parser.parse(file_path)
        new_sheet1 = reloaded['Sheet1']
        new_sheet2 = reloaded['Sheet2']

        # Cell positions: the block now lives at D5:E6, the source is empty.
        expect(new_sheet1.cell_at('A1')).to be_nil
        expect(new_sheet1.cell_at('B1')).to be_nil
        expect(new_sheet1.cell_at('A2')).to be_nil
        expect(new_sheet1.cell_at('B2')).to be_nil
        expect(new_sheet1[4][3].value).to eq(1)
        expect(new_sheet1[4][4].value).to eq(2)
        expect(new_sheet1[5][3].value).to eq(3)
        expect(new_sheet1[5][4].value).to eq(4)

        # Formula texts, item by item.
        expect(new_sheet1[3][0].formula.expression).to eq('D5')
        expect(new_sheet1[4][0].formula.expression).to eq('$D$5+$E$6')
        expect(new_sheet1[5][0].formula.expression).to eq('SUM(D5:E6)')
        expect(new_sheet1[6][0].formula.expression).to eq('SUM(D5,C3)')
        expect(new_sheet1[7][0].formula.expression).to eq('"A1"&D5')
        expect(new_sheet1[8][0].formula.expression).to eq('C1')
        expect(new_sheet1[9][0].formula.expression).to eq('D5')
        expect(new_sheet1[5][4].formula.expression).to eq('A1*2') # Moved formula, verbatim

        expect(new_sheet2[0][0].formula.expression).to eq('Sheet1!D5')
        expect(new_sheet2[1][0].formula.expression).to eq('Sheet1!$D$5:$E$6')

        expect(reloaded.get_defined_name('MyRange').reference).to eq('Sheet1!$D$5:$E$6')
      end
    end
  end
end

describe RubyXL::FormulaReferenceMover do
  # Moves A1:B2 to D5:E6 on 'Sheet1'
  subject(:mover) { RubyXL::FormulaReferenceMover.new('Sheet1', 0, 1, 0, 1, 4, 3) }

  it 'shifts references whose target moved, even absolute ones' do
    expect(mover.rewrite('A1+$A$1+B2', 'Sheet1')).to eq('D5+$D$5+E6')
  end

  it 'ignores references without sheet context when there is no current sheet' do
    expect(mover.rewrite('A1', nil)).to eq('A1')
    expect(mover.rewrite('Sheet1!A1', nil)).to eq('Sheet1!D5')
  end

  it 'matches sheet names case-insensitively' do
    expect(mover.rewrite('SHEET1!A1', 'Other')).to eq('SHEET1!D5')
  end

  it 'replaces references shifted out of the worksheet with #REF!' do
    shifter = RubyXL::FormulaReferenceMover.new('Sheet1', 0, 0, 0, 0, -1, 0)
    expect(shifter.rewrite('A1+B1', 'Sheet1')).to eq('#REF!+B1')
  end

  it 'splits a range around the moved area into a union' do
    wide = RubyXL::FormulaReferenceMover.new('Sheet1', 0, 0, 1, 2, 0, 5) # B1:C1 -> G1:H1
    expect(wide.rewrite('A1:D1', 'Sheet1')).to eq('A1,D1,G1:H1')
  end

  it 'does not touch numeric or boolean literals' do
    expect(mover.rewrite('TRUE+1E5+100', 'Sheet1')).to eq('TRUE+1E5+100')
  end
end
