require 'rubyXL/formula_reference_mover'

module RubyXL
  module WorksheetMoveRangeMethods
    # Moves a rectangular range of cells to a new location on the same worksheet
    # (cut/paste semantics), and adjusts everything that pointed at the old
    # location so that it keeps referencing the moved cells:
    #
    # * formulas on every worksheet of the workbook (A1 references, union
    #   references, cross-sheet references -- relative and absolute alike,
    #   because it is the *target* of the reference that moved, not the formula);
    # * workbook-level defined names.
    #
    # Formulas inside the moved cells themselves are carried over verbatim,
    # exactly like Excel does on cut/paste. String constants that merely look
    # like cell references are left untouched.
    #
    # The operation is atomic: if the workbook contains constructs that cannot
    # be safely rewritten (array formulas, shared formulas, table structured
    # references, external workbook references, tables), a RuntimeError is
    # raised during the pre-flight check, before anything is modified.
    #
    # +source+      - the range to move: 'A1:B2' or a RubyXL::Reference
    # +destination+ - the top-left cell of the new location: 'D5' or a RubyXL::Reference
    #
    # Returns a RubyXL::Reference describing the new location of the range.
    def move_range(source, destination)
      validate_workbook

      src = source.is_a?(RubyXL::Reference) ? source : RubyXL::Reference.new(source.to_s)
      dst = destination.is_a?(RubyXL::Reference) ? destination : RubyXL::Reference.new(destination.to_s)

      raise ArgumentError, "invalid source range: #{source.inspect}" unless src.valid?
      raise ArgumentError, "invalid destination: #{destination.inspect}" unless dst.valid?

      if src.sheet_name && src.sheet_name.downcase != sheet_name.to_s.downcase then
        raise ArgumentError, "source range #{source.inspect} is not on worksheet #{sheet_name.inspect}"
      end
      if dst.sheet_name then
        raise ArgumentError, 'moving a range to another worksheet is not supported'
      end

      delta_row = dst.first_row - src.first_row
      delta_col = dst.first_col - src.first_col
      raise ArgumentError, 'source and destination are identical' if delta_row.zero? && delta_col.zero?

      if (src.last_row + delta_row) >= RubyXL::FormulaReferenceMover::ROW_LIMIT ||
           (src.last_col + delta_col) >= RubyXL::FormulaReferenceMover::COL_LIMIT then
        raise ArgumentError, 'destination range is out of worksheet bounds'
      end

      mover = RubyXL::FormulaReferenceMover.new(sheet_name, src.first_row, src.last_row,
                                                src.first_col, src.last_col, delta_row, delta_col)

      validate_move_range_supported!

      # Redirect formulas in every worksheet of the workbook. Formulas inside
      # the moved cells are skipped: they travel with their cells unchanged.
      workbook.worksheets.each { |ws|
        ws.sheet_data&.rows&.each_with_index { |row, row_index|
          next if row.nil?
          row.cells.each_with_index { |cell, col_index|
            next if cell.nil? || cell.formula.nil? || cell.formula.expression.nil?
            next if ws.equal?(self) &&
                    row_index.between?(src.first_row, src.last_row) &&
                    col_index.between?(src.first_col, src.last_col)
            cell.formula.expression = mover.rewrite(cell.formula.expression, ws.sheet_name)
          }
        }
      }

      # Redirect workbook-level defined names.
      workbook.defined_names&.each { |defined_name|
        next if defined_name.reference.nil?
        defined_name.reference = mover.rewrite(defined_name.reference, nil)
      }

      # Physically relocate the cells. The source cells are detached before any
      # of them is written to its new location, so overlapping moves are safe.
      moved_cells = []
      (src.first_row..src.last_row).each { |row_index|
        row = sheet_data.rows[row_index]
        next if row.nil?
        (src.first_col..src.last_col).each { |col_index|
          cell = row.cells[col_index]
          moved_cells << [row_index, col_index, cell] unless cell.nil?
        }
      }
      moved_cells.each { |row_index, col_index, _| sheet_data.rows[row_index].cells[col_index] = nil }
      moved_cells.each { |row_index, col_index, cell|
        new_row = sheet_data.rows[row_index + delta_row] || add_row(row_index + delta_row)
        new_row.cells[col_index + delta_col] = cell
        cell.r = RubyXL::Reference.new(row_index + delta_row, col_index + delta_col)
      }

      # The calculation chain no longer matches the worksheet contents;
      # drop it and let the spreadsheet application rebuild it.
      workbook.calculation_chain = nil

      RubyXL::Reference.new(dst.first_row, src.last_row + delta_row,
                            dst.first_col, src.last_col + delta_col)
    end

    private

    # Pre-flight check for move_range: rejects the operation as a whole if the
    # workbook contains formula constructs that cannot be rewritten safely.
    def validate_move_range_supported!
      workbook.worksheets.each { |ws|
        unless ws.table_parts.nil? || ws.table_parts.empty? then
          raise "cannot move a range: worksheet #{ws.sheet_name.inspect} contains tables"
        end

        ws.sheet_data&.rows&.each { |row|
          row&.cells&.each { |cell|
            formula = cell&.formula
            next if formula.nil?

            type = formula.t
            unless type.nil? || type == 'normal' then
              raise "cannot move a range: #{type} formulas are not supported"
            end
            if formula.expression&.include?('[') then
              raise 'cannot move a range: structured and external references are not supported'
            end
          }
        }
      }

      workbook.defined_names&.each { |defined_name|
        if defined_name.reference&.include?('[') then
          raise 'cannot move a range: structured and external references are not supported'
        end
      }
    end
  end

  RubyXL::Worksheet.send(:include, RubyXL::WorksheetMoveRangeMethods) # ruby 2.1 compat
end

