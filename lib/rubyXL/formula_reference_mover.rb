require 'rubyXL/objects/reference'

module RubyXL
  # Rewrites A1-style cell references in formula expressions so that they keep
  # pointing at cells whose location has changed as a result of a "move range"
  # (cut/paste) operation.
  #
  # This is deliberately different from the "copy formula" semantics: when a
  # formula is *copied*, its relative references shift according to the new
  # position of the formula itself. Here the formula stays where it is, but the
  # *target* of the reference has moved, so every reference to the moved cells
  # is adjusted -- including absolute ones ($A$1).
  #
  # Handled constructs:
  # * plain A1 references (A1, $A$1, A1:B2, and any mix of absolute markers);
  # * union references (A1,B2) -- each member is processed independently, and
  #   a range that is only partially covered by the moved area is split into
  #   a union of the unmoved remainder and the shifted intersection;
  # * cross-sheet references (Sheet1!A1, 'My Sheet'!A1, 'It''s'!A1);
  # * workbook-level defined names (their reference strings are rewritten with
  #   the same rules).
  #
  # String constants ("...") are preserved verbatim, even if their contents
  # look like a cell reference.
  class FormulaReferenceMover
    ROW_LIMIT = 1_048_576 # Maximum number of rows on a worksheet
    COL_LIMIT = 16_384    # Maximum number of columns on a worksheet

    SHEET_NAME_PATTERN = /'(?:[^']|'')+'|[\p{L}_][\p{L}\p{N}_.]*/
    CELL_REF_PATTERN = /\$?[A-Za-z]{1,3}\$?[0-9]{1,7}/

    TOKEN_PATTERN = /
      (?<string>"(?:[^"]|"")*")                           # string constant: kept as is
      |
      (?<![\p{L}\p{N}_.$!:])                              # not in the middle of another token
      (?:(?<sheet1>#{SHEET_NAME_PATTERN})!)?              # optional sheet prefix
      (?<ref1>#{CELL_REF_PATTERN})
      (?::(?:(?<sheet2>#{SHEET_NAME_PATTERN})!)?(?<ref2>#{CELL_REF_PATTERN}))?
      (?![\p{L}\p{N}_.$(])                                # not a function call or a longer token
    /x

    # +sheet_name+                 name of the worksheet the cells are moved within
    # +row_from+, +row_to+         zero-based row boundaries of the moved range (inclusive)
    # +col_from+, +col_to+         zero-based column boundaries of the moved range (inclusive)
    # +delta_row+, +delta_col+     displacement of the moved range
    def initialize(sheet_name, row_from, row_to, col_from, col_to, delta_row, delta_col)
      @sheet_name = sheet_name.to_s.downcase
      @row_from = row_from
      @row_to   = row_to
      @col_from = col_from
      @col_to   = col_to
      @delta_row = delta_row
      @delta_col = delta_col
    end

    # Returns a copy of +expression+ (a formula without the leading '=') in which
    # every reference to the moved range is redirected to its new location.
    # +current_sheet+ is the name of the worksheet owning the expression, used to
    # resolve references without an explicit sheet prefix (+nil+ for expressions
    # that are not attached to a worksheet, such as defined names).
    def rewrite(expression, current_sheet)
      expression.gsub(TOKEN_PATTERN) { |token|
        match = Regexp.last_match

        if match[:string] then
          token
        elsif match[:sheet2] && (match[:sheet1].nil? ||
              unquote_sheet_name(match[:sheet2]) != unquote_sheet_name(match[:sheet1])) then
          token # Weird "Sheet1!A1:Sheet2!B2" construct, leave it alone.
        else
          move_token(token, match[:sheet1], match[:ref1], match[:ref2], current_sheet)
        end
      }
    end

    private

    def move_token(token, sheet_prefix, ref1, ref2, current_sheet)
      target_sheet = sheet_prefix ? unquote_sheet_name(sheet_prefix) : current_sheet
      return token if target_sheet.nil? || target_sheet.downcase != @sheet_name

      row1, col1, row1_abs, col1_abs = RubyXL::Reference.ref2ind(ref1)
      if ref2 then
        row2, col2, row2_abs, col2_abs = RubyXL::Reference.ref2ind(ref2)
      else
        row2, col2, row2_abs, col2_abs = row1, col1, row1_abs, col1_abs
      end
      return token if row1.negative? || row2.negative?

      # Normalize the rectangle so that (row1, col1) is the top-left corner.
      if row1 > row2 then
        row1, row2 = row2, row1
        row1_abs, row2_abs = row2_abs, row1_abs
      end
      if col1 > col2 then
        col1, col2 = col2, col1
        col1_abs, col2_abs = col2_abs, col1_abs
      end

      int_row1 = [row1, @row_from].max
      int_row2 = [row2, @row_to].min
      int_col1 = [col1, @col_from].max
      int_col2 = [col2, @col_to].min
      return token if int_row1 > int_row2 || int_col1 > int_col2 # No intersection

      prefix = sheet_prefix ? "#{sheet_prefix}!" : ''
      flags = [row1_abs, col1_abs, row2_abs, col2_abs]

      if int_row1 == row1 && int_row2 == row2 && int_col1 == col1 && int_col2 == col2 then
        # The reference is fully inside the moved range: it simply follows it.
        shifted = shift_rect([row1, row2, col1, col2])
        return '#REF!' if shifted.nil?
        render_rect(prefix, shifted, flags)
      else
        # Partial overlap: the reference is split into a union of the part that
        # stayed behind and the part that moved along with the cells.
        parts = remainder_rects([row1, row2, col1, col2],
                                [int_row1, int_row2, int_col1, int_col2]).map { |rect|
                  render_rect(prefix, rect, flags)
                }
        shifted = shift_rect([int_row1, int_row2, int_col1, int_col2])
        return '#REF!' if shifted.nil?
        parts << render_rect(prefix, shifted, flags)
        parts.join(',')
      end
    end

    def shift_rect(rect)
      row1, row2, col1, col2 = rect
      row1 += @delta_row
      row2 += @delta_row
      col1 += @delta_col
      col2 += @delta_col
      return nil if row1.negative? || col1.negative? || row2 >= ROW_LIMIT || col2 >= COL_LIMIT
      [row1, row2, col1, col2]
    end

    # Rectangles that remain of +rect+ after cutting out +hole+
    # (+hole+ must be fully contained in +rect+).
    def remainder_rects(rect, hole)
      row1, row2, col1, col2 = rect
      hole_row1, hole_row2, hole_col1, hole_col2 = hole
      rects = []
      rects << [row1, hole_row1 - 1, col1, col2] if hole_row1 > row1
      rects << [hole_row2 + 1, row2, col1, col2] if hole_row2 < row2
      rects << [hole_row1, hole_row2, col1, hole_col1 - 1] if hole_col1 > col1
      rects << [hole_row1, hole_row2, hole_col2 + 1, col2] if hole_col2 < col2
      rects
    end

    def render_rect(prefix, rect, flags)
      row1, row2, col1, col2 = rect
      from = RubyXL::Reference.ind2ref(row1, col1, flags[0], flags[1])
      return "#{prefix}#{from}" if row1 == row2 && col1 == col2
      "#{prefix}#{from}:#{RubyXL::Reference.ind2ref(row2, col2, flags[2], flags[3])}"
    end

    def unquote_sheet_name(name)
      if name.start_with?("'") then name[1..-2].gsub("''", "'")
      else name
      end
    end
  end
end

