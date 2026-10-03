module RubyXL
  # Rewrites A1-style references in formula expressions after a range of cells
  # has been moved (cut/paste semantics).
  #
  # Unlike copying a formula (where only relative addresses are adjusted to
  # their new location), moving cells re-targets every reference that points
  # inside the moved range, including absolute ($A$1) ones, because the target
  # cell itself moved. References that only partially overlap the moved range,
  # references to other sheets, and anything inside string literals (even if it
  # looks like a cell address) are preserved verbatim.
  class FormulaShifter
    MAX_ROW = 1_048_576 # 2 ** 20
    MAX_COL = 16_384    # 2 ** 14 (column 'XFD')

    CELL_REF = /\A(\$?)([A-Z]{1,3})(\$?)([0-9]+)(?::(\$?)([A-Z]{1,3})(\$?)([0-9]+))?/
    SHEET_PREFIX = /\A[A-Za-z_][A-Za-z0-9_.]*!/
    IDENTIFIER_CHAR = /[A-Za-z0-9_.$]/
    STRING_LITERAL = /"(?:[^"]|"")*"/

    attr_reader :sheet_name, :row_shift, :col_shift

    def initialize(sheet_name, source_range, row_shift, col_shift)
      @sheet_name  = sheet_name
      @source_rows = source_range.row_range
      @source_cols = source_range.col_range
      @row_shift   = row_shift
      @col_shift   = col_shift
    end

    # Returns +true+ if the expression uses reference types this class cannot
    # rewrite: table structured references (+Table1[Column]+) or external
    # workbook links (+[1]Sheet1!A1+).
    def self.unsupported_expression?(expression)
      return false unless expression.is_a?(String)
      expression.gsub(STRING_LITERAL, '').match?(/[\[\]]/)
    end

    # Returns a copy of +expression+ with all references to the moved range
    # remapped to its new location. +current_sheet_name+ is the name of the
    # sheet the expression belongs to (used to resolve unqualified references);
    # pass +nil+ for expressions that are not tied to a sheet.
    def shift(expression, current_sheet_name = nil)
      return expression unless expression.is_a?(String)

      result = +''
      pos = 0
      while pos < expression.length
        chunk, pos = next_chunk(expression, pos, current_sheet_name)
        result << chunk
      end
      result
    end

    private

    def next_chunk(expression, pos, current_sheet_name)
      case expression[pos]
      when '"'
        stop = quoted_end(expression, pos, '"')
        [expression[pos...stop], stop]
      when "'"
        stop = quoted_end(expression, pos, "'")
        if expression[stop] == '!' then
          sheet = expression[(pos + 1)...(stop - 1)].gsub("''", "'")
          rewritten, ref_stop = shift_reference(expression, stop + 1, sheet)
          return [expression[pos..stop] + rewritten, ref_stop] if ref_stop
        end
        [expression[pos...stop], stop]
      else
        if (match = SHEET_PREFIX.match(expression[pos..-1])) then
          rewritten, ref_stop = shift_reference(expression, pos + match[0].length, match[0][0..-2])
          return [match[0] + rewritten, ref_stop] if ref_stop
        end

        rewritten, ref_stop = shift_reference(expression, pos, current_sheet_name)
        return [rewritten, ref_stop] if ref_stop

        [expression[pos], pos + 1]
      end
    end

    # If a valid A1-style reference starts at +pos+, returns the (possibly
    # remapped) reference text and the index right after it; otherwise returns
    # [nil, nil]. +ref_sheet_name+ is the sheet the reference points to
    # (explicit prefix or the sheet the expression lives on).
    def shift_reference(expression, pos, ref_sheet_name)
      match = CELL_REF.match(expression[pos..-1])
      return [nil, nil] unless match

      stop = pos + match[0].length

      # Not a reference if glued to an identifier, a number, or a function call.
      following = expression[stop]
      return [nil, nil] if following && following.match?(/[A-Za-z0-9_.(]/)

      preceding = pos.positive? ? expression[pos - 1] : nil
      return [nil, nil] if preceding && preceding.match?(IDENTIFIER_CHAR)

      row_from = match[4].to_i - 1
      col_from = self.class.col_index(match[2])
      row_to   = match[8] ? match[8].to_i - 1 : row_from
      col_to   = match[6] ? self.class.col_index(match[6]) : col_from

      # Anything outside the A1 grid is a defined name, not a reference.
      return [nil, nil] if row_from >= MAX_ROW || row_to >= MAX_ROW ||
                           col_from >= MAX_COL || col_to >= MAX_COL

      if same_sheet?(ref_sheet_name) && covered?(row_from, col_from, row_to, col_to) then
        [remap(match, row_from, col_from, row_to, col_to), stop]
      else
        [match[0], stop]
      end
    end

    def same_sheet?(ref_sheet_name)
      !ref_sheet_name.nil? && !@sheet_name.nil? && ref_sheet_name.casecmp(@sheet_name).zero?
    end

    def covered?(row_from, col_from, row_to, col_to)
      @source_rows.cover?(row_from) && @source_rows.cover?(row_to) &&
        @source_cols.cover?(col_from) && @source_cols.cover?(col_to)
    end

    # Shifts both endpoints of the reference, preserving absolute/relative
    # markers: even absolute addresses move when their target cell moves.
    def remap(match, row_from, col_from, row_to, col_to)
      first = RubyXL::Reference.ind2ref(row_from + @row_shift, col_from + @col_shift,
                                        !match[3].empty?, !match[1].empty?)
      return first unless match[6]

      first + ':' + RubyXL::Reference.ind2ref(row_to + @row_shift, col_to + @col_shift,
                                              !match[7].empty?, !match[5].empty?)
    end

    # Returns the index right after the closing quote of a string literal
    # ("..." with "" escapes) or quoted sheet name ('...' with '' escapes).
    def quoted_end(expression, pos, quote)
      i = pos + 1
      while i < expression.length
        if expression[i] == quote then
          if expression[i + 1] == quote then i += 2
          else return i + 1
          end
        else
          i += 1
        end
      end
      expression.length
    end

    def self.col_index(letters)
      letters.each_byte.inject(0) { |acc, byte| (acc * 26) + (byte - 64) } - 1
    end
  end
end
