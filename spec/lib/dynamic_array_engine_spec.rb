require 'spec_helper'
require 'rubyXL/convenience_methods'

describe RubyXL::DynamicArrayEngine do
  before do
    @workbook = RubyXL::Workbook.new
    @worksheet = @workbook.worksheets.first
  end

  def cell_at(row, col)
    @worksheet.sheet_data[row] && @worksheet.sheet_data[row][col]
  end

  def value_at(row, col)
    cell_at(row, col)&.value
  end

  def raw_at(row, col)
    cell_at(row, col)&.raw_value
  end

  describe 'constant matrices and element-wise arithmetic' do
    it 'spills a constant matrix' do
      @worksheet.set_dynamic_formula(0, 0, '{1,2;3,4}')
      expect(value_at(0, 0)).to eq(1)
      expect(value_at(0, 1)).to eq(2)
      expect(value_at(1, 0)).to eq(3)
      expect(value_at(1, 1)).to eq(4)
      expect(@worksheet.spill_range_at(1, 1).to_s).to eq('A1:B2')
    end

    it 'evaluates element-wise arithmetic with broadcasting' do
      @worksheet.set_dynamic_formula(0, 0, '{1,2;3,4}*10+{0,1;0,1}')
      expect(value_at(0, 0)).to eq(10)
      expect(value_at(0, 1)).to eq(21)
      expect(value_at(1, 0)).to eq(30)
      expect(value_at(1, 1)).to eq(41)
    end

    it 'reports #VALUE! on incompatible shapes and #DIV/0! on division by zero' do
      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(2,2)+SEQUENCE(3,2)')
      expect(raw_at(0, 0)).to eq('#VALUE!')
      @worksheet.set_dynamic_formula(0, 0, '{1,2}/0')
      expect(raw_at(0, 0)).to eq('#DIV/0!')
      expect(raw_at(0, 1)).to eq('#DIV/0!')
    end

    it 'rejects unparsable formulas without touching the sheet' do
      expect {
        @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(')
      }.to raise_error(RubyXL::DynamicArrayEngine::EvaluationError)
      expect(cell_at(0, 0)).to be_nil
    end
  end

  describe 'SEQUENCE, TRANSPOSE and FILTER' do
    it 'evaluates SEQUENCE with all arguments' do
      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(2,3,5,10)')
      expect(value_at(0, 0)).to eq(5)
      expect(value_at(0, 2)).to eq(25)
      expect(value_at(1, 2)).to eq(55)
      expect(@worksheet.spill_range_at(1, 2).to_s).to eq('A1:C2')
    end

    it 'evaluates TRANSPOSE' do
      @worksheet.set_dynamic_formula(0, 0, 'TRANSPOSE(SEQUENCE(2,3))')
      expect(@worksheet.spill_range_at(2, 1).to_s).to eq('A1:B3')
      expect(value_at(0, 0)).to eq(1)
      expect(value_at(0, 1)).to eq(4)
      expect(value_at(2, 1)).to eq(6)
    end

    it 'evaluates FILTER over rows and columns' do
      @worksheet.set_dynamic_formula(0, 0, 'FILTER(SEQUENCE(3,2), {1;0;1})')
      expect(@worksheet.spill_range_at(1, 1).to_s).to eq('A1:B2')
      expect(value_at(0, 0)).to eq(1)
      expect(value_at(1, 0)).to eq(5)
      expect(value_at(1, 1)).to eq(6)

      @worksheet.set_dynamic_formula(0, 0, 'FILTER(SEQUENCE(2,3), {1,0,1})')
      expect(@worksheet.spill_range_at(1, 1).to_s).to eq('A1:B2')
      expect(value_at(0, 1)).to eq(3)
    end

    it 'returns #CALC! when FILTER has no matches' do
      @worksheet.set_dynamic_formula(0, 0, 'FILTER(SEQUENCE(2,2), {0;0})')
      expect(raw_at(0, 0)).to eq('#CALC!')
    end

    it 'reads plain A1:B2 ranges and recalculates when the anchor behind them reshapes' do
      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(2,2)')
      @worksheet.set_dynamic_formula(0, 3, 'TRANSPOSE(A1:B2)')
      expect(@worksheet.spill_range_at(1, 4).to_s).to eq('D1:E2')
      expect(value_at(0, 4)).to eq(3)

      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(3,2)')
      # The dependent formula still reads A1:B2 (its declared range), but the
      # released C-row cells now read as empty (0).
      expect(value_at(0, 4)).to eq(3)
      expect(@worksheet.spill_range_at(1, 4).to_s).to eq('D1:E2')
    end
  end

  describe 'spill growth and shrinkage' do
    it 'grows a 2x2 spill to 3x2 and updates the cached values' do
      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(2,2)')
      expect(@worksheet.spill_range_at(1, 1).to_s).to eq('A1:B2')

      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(3,2)')
      expect(@worksheet.spill_range_at(2, 1).to_s).to eq('A1:B3')
      expect(value_at(2, 0)).to eq(5)
      expect(value_at(2, 1)).to eq(6)
    end

    it 'shrinks a spill back to a single cell and releases the old cells' do
      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(3,2)')
      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(1,1)')
      expect(value_at(0, 0)).to eq(1)
      expect(@worksheet.spill_range_at(0, 0).to_s).to eq('A1')
      expect(cell_at(0, 1)).to be_nil
      expect(cell_at(1, 0)).to be_nil
      expect(cell_at(1, 1)).to be_nil
      expect(cell_at(2, 0)).to be_nil
      expect(cell_at(2, 1)).to be_nil
      expect(@worksheet.spill_anchor_at(1, 1)).to be_nil
    end
  end

  describe '#SPILL! handling' do
    it 'is blocked by a user value in the middle of the target range' do
      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(2,2)')
      @worksheet.add_cell(1, 1, 'keep me') # B2, in the middle of A1:C3

      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(3,3)')
      expect(raw_at(0, 0)).to eq('#SPILL!')
      expect(cell_at(0, 0).datatype).to eq(RubyXL::DataType::ERROR)

      # The user cell is untouched, and no partial results are left behind.
      expect(raw_at(1, 1)).to eq('keep me')
      expect(cell_at(0, 1)).to be_nil
      expect(cell_at(1, 0)).to be_nil
      expect(cell_at(2, 0)).to be_nil
      expect(cell_at(2, 2)).to be_nil
    end

    it 'recovers once the blocking cell is removed' do
      @worksheet.add_cell(1, 1, 'blocker')
      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(2,2)')
      expect(raw_at(0, 0)).to eq('#SPILL!')

      @worksheet.delete_cell(1, 1)
      @worksheet.recalculate_dynamic_arrays
      expect(@worksheet.spill_range_at(1, 1).to_s).to eq('A1:B2')
      expect(value_at(1, 1)).to eq(4)
    end

    it 'is blocked by merged cells' do
      @worksheet.merged_cells = RubyXL::MergedCells.new
      @worksheet.merged_cells << RubyXL::MergedCell.new(:ref => RubyXL::Reference.new('B2:C2'))
      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(3,3)')
      expect(raw_at(0, 0)).to eq('#SPILL!')
      expect(cell_at(1, 0)).to be_nil
    end

    it 'is blocked by another spill' do
      @worksheet.set_dynamic_formula(2, 0, 'SEQUENCE(2,2)') # A3:B4
      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(4,2)') # would need A1:B4
      expect(raw_at(0, 0)).to eq('#SPILL!')
      # The other spill is untouched.
      expect(@worksheet.spill_range_at(3, 1).to_s).to eq('A3:B4')
      expect(value_at(3, 1)).to eq(4)
    end

    it 'does not overwrite a user value typed into an existing spill' do
      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(2,2)')
      @worksheet.add_cell(1, 1, 'user') # B2, inside the A1:B2 spill

      @worksheet.recalculate_dynamic_arrays
      expect(raw_at(0, 0)).to eq('#SPILL!')
      expect(raw_at(1, 1)).to eq('user')
      expect(cell_at(0, 1)).to be_nil
      expect(cell_at(1, 0)).to be_nil
    end
  end

  describe 'dependent anchors and A1# references' do
    it 'recalculates dependents when the anchor shape changes' do
      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(2,2)')
      @worksheet.set_dynamic_formula(0, 3, 'TRANSPOSE(A1#)')
      @worksheet.set_dynamic_formula(0, 6, 'A1#*2')

      expect(@worksheet.spill_range_at(1, 4).to_s).to eq('D1:E2')
      expect(value_at(1, 3)).to eq(2)
      expect(@worksheet.spill_range_at(1, 7).to_s).to eq('G1:H2')
      expect(value_at(1, 7)).to eq(8)

      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(3,2)')
      expect(@worksheet.spill_range_at(0, 5).to_s).to eq('D1:F2')
      expect(value_at(0, 5)).to eq(5)
      expect(value_at(1, 3)).to eq(2)
      expect(@worksheet.spill_range_at(2, 7).to_s).to eq('G1:H3')
      expect(value_at(2, 7)).to eq(12)
      # Cells of the old dependent spills are released.
      expect(cell_at(2, 3)).to be_nil
    end

    it 'propagates #SPILL! through dependent anchors' do
      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(2,2)')
      @worksheet.set_dynamic_formula(0, 3, 'A1#*2')
      @worksheet.add_cell(1, 0, 'blocker') # blocks A1:B2 on next recalc

      @worksheet.recalculate_dynamic_arrays
      expect(raw_at(0, 0)).to eq('#SPILL!')
      expect(raw_at(0, 3)).to eq('#SPILL!')
      expect(cell_at(0, 4)).to be_nil
    end

    it 'reports #REF! for a spill reference to a non-anchor cell' do
      @worksheet.set_dynamic_formula(0, 0, 'Z9#+1')
      expect(raw_at(0, 0)).to eq('#REF!')
    end
  end

  describe 'circular dependencies' do
    it 'reports cycles as #CYCLE! without affecting unrelated anchors' do
      @worksheet.set_dynamic_formula(0, 0, 'B1#+1')
      @worksheet.set_dynamic_formula(0, 1, 'A1#+1')
      @worksheet.set_dynamic_formula(0, 3, 'SEQUENCE(2,1)')

      expect(raw_at(0, 0)).to eq('#CYCLE!')
      expect(raw_at(0, 1)).to eq('#CYCLE!')
      expect(value_at(1, 3)).to eq(2)

      engine = @worksheet.dynamic_array_engine
      expect(engine.cyclic_keys).to contain_exactly([0, 0], [0, 1])
      expect(engine.errors[[0, 0]].code).to eq('#CYCLE!')
    end

    it 'propagates the cycle error to dependents of the cycle' do
      @worksheet.set_dynamic_formula(0, 0, 'B1#+1')
      @worksheet.set_dynamic_formula(0, 1, 'A1#+1')
      @worksheet.set_dynamic_formula(0, 3, 'A1#*2')
      expect(raw_at(0, 3)).to eq('#CYCLE!')
      expect(@worksheet.dynamic_array_engine.cyclic_keys).not_to include([0, 3])
    end
  end

  describe 'save and reload' do
    it 'preserves dynamic formulas, cached results and spill membership' do
      @worksheet.set_dynamic_formula(0, 0, 'SEQUENCE(2,2)')
      @worksheet.set_dynamic_formula(0, 3, 'TRANSPOSE(A1#)')

      reloaded = RubyXL::Parser.parse_buffer(@workbook.stream)['Sheet1']

      anchor = reloaded.sheet_data[0][0]
      expect(anchor.formula.expression).to eq('SEQUENCE(2,2)')
      expect(anchor.formula.t).to eq('array')
      expect(anchor.formula.aca).to eq(true)
      expect(anchor.formula.ref.to_s).to eq('A1:B2')

      # Cached results survive the round trip.
      expect(reloaded.sheet_data[1][1].value).to eq(4)
      expect(reloaded.sheet_data[1][4].value).to eq(4)

      # Spill membership is recovered from the stored anchor refs.
      expect(reloaded.spill_anchor_at(1, 1)).to eq([0, 0])
      expect(reloaded.spill_anchor_at(0, 4)).to eq([0, 3])
      expect(reloaded.spill_range_at(1, 1).to_s).to eq('A1:B2')
      expect(reloaded.spill_range_at(1, 4).to_s).to eq('D1:E2')
      expect(reloaded.dynamic_anchor?(0, 0)).to eq(true)
      expect(reloaded.dynamic_anchor?(1, 1)).to eq(false)

      # The reloaded workbook can be recalculated and reshaped.
      reloaded.set_dynamic_formula(0, 0, 'SEQUENCE(3,2)')
      expect(reloaded.spill_range_at(2, 1).to_s).to eq('A1:B3')
      expect(reloaded.spill_range_at(0, 5).to_s).to eq('D1:F2')
      expect(reloaded.sheet_data[2][1].value).to eq(6)
    end
  end
end
