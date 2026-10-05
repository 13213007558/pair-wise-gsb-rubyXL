module RubyXL
  # Tokenizes A1-style references inside formula expressions so that they can
  # be rewritten when a rectangular range of cells is moved (cut/paste semantics).
  #
  # The tokenizer understands:
  # * plain and sheet-qualified cell references and ranges
  #   (+A1+, +$B$2+, +Sheet1!A1:C3+, +'My Sheet'!$A$1+);
  # * full-column (+A:A+) and full-row (+1:1+) ranges;
  # * string constants (+"..."+ with doubled-quote escaping) - never rewritten;
  # * quoted sheet names (+'...'+ with doubled-quote escaping).
  #
  # External workbook references (+[1]Sheet1!A1+), 3-D references
  # (+Sheet1:Sheet3!A1+) and structured (table) references (+Table1[Column]+)
  # are recognized and returned as +:unsupported+ tokens - they are never
  # rewritten, and callers are expected to report them before making changes.
  class FormulaRewriter
    MAX_ROW = 1_048_576
    MAX_COL = 16_384

    # One lexical token of a formula expression.
    # +type+ is one of :reference, :unsupported, :other.
    # For :reference tokens, +kind+ is one of :cell, :range, :col_range, :row_range,
    # +sheet_name+ is the (unescaped) sheet name or +nil+, and +sheet_prefix+ is the
    # original prefix text (including the bang) or +nil+.
    class Token
      attr_accessor :type, :text, :kind, :sheet_name, :sheet_prefix,
                    :first_row, :first_col, :last_row, :last_col,
                    :row_from_absolute, :row_to_absolute,
                    :col_from_absolute, :col_to_absolute

      def initialize(type, text)
        @type = type
        @text = text
      end

      def reference?
        @type == :reference
      end

      def unsupported?
        @type == :unsupported
      end
    end

    CELL_PATTERN      = /\A(\$?)([A-Za-z]{1,3})(\$?)([0-9]+)/
    COL_RANGE_PATTERN = /\A(\$?)([A-Za-z]{1,3}):(\$?)([A-Za-z]{1,3})(?![0-9])/
    ROW_RANGE_PATTERN = /\A(\$?)([0-9]+):(\$?)([0-9]+)/
    WORD_PATTERN      = /\A[[:alpha:]_\\][[:alnum:]_.]*/
    THREE_D_PATTERN   = /\A[[:alpha:]_\\][[:alnum:]_.]*:[[:alpha:]_\\][[:alnum:]_.]*!/
    NUMBER_PATTERN    = /\A(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?/
    WORD_CHAR_PATTERN = /\A[[:alnum:]_.]/

    def self.tokenize(expression)
      new(expression).tokenize
    end

    def initialize(expression)
      @src = expression.to_s
      @pos = 0
      @tokens = []
    end

    def tokenize
      while @pos < @src.length
        ch = @src[@pos]
        case ch
        when '"' then scan_string_constant
        when "'" then scan_quoted_name
        when '[' then scan_bracket
        when '$' then scan_word_or_reference
        when /[[:alpha:]_\\]/ then scan_word_or_reference
        when /[0-9]/ then scan_number_or_row_range
        when '.'
          if @src[@pos + 1] =~ /[0-9]/ then scan_number_or_row_range
          else
            emit_other(ch)
            @pos += 1
          end
        else
          emit_other(ch)
          @pos += 1
        end
      end
      @tokens
    end

    private

    def emit_other(text)
      @tokens << Token.new(:other, text)
    end

    def emit_unsupported(text)
      @tokens << Token.new(:unsupported, text)
    end

    # Double-quoted string constant: copied verbatim, never rewritten.
    def scan_string_constant
      start = @pos
      @pos += 1
      while @pos < @src.length
        if @src[@pos] == '"'
          if @src[@pos + 1] == '"' then @pos += 2
          else
            @pos += 1
            break
          end
        else
          @pos += 1
        end
      end
      emit_other(@src[start...@pos])
    end

    # Single-quoted name, normally a quoted sheet name followed by '!'.
    def scan_quoted_name
      start = @pos
      @pos += 1
      name = +''
      while @pos < @src.length
        if @src[@pos] == "'"
          if @src[@pos + 1] == "'"
            name << "'"
            @pos += 2
          else
            @pos += 1
            break
          end
        else
          name << @src[@pos]
          @pos += 1
        end
      end

      if @src[@pos] == '!' then
        body = scan_ref_body(@pos + 1)
        if name.start_with?('[') || name.include?(':') then
          # External workbook ('[1]Sheet'!A1) or 3-D ('Sheet1:Sheet3'!A1) reference.
          @pos = body ? body[0] : @pos + 1
          emit_unsupported(@src[start...@pos])
        elsif body then
          end_pos, kind, matches = body
          token = build_reference_token(start, end_pos, kind, matches)
          token.sheet_name = name
          token.sheet_prefix = @src[start..@pos]
          @pos = end_pos
          @tokens << token
        else
          emit_other(@src[start...@pos])
        end
      else
        emit_other(@src[start...@pos])
      end
    end

    # '[' starts either an external workbook reference ([1]Sheet1!A1)
    # or a structured (table) reference ([Column], [@Column], [#This Row]).
    def scan_bracket
      rest = @src[@pos..-1]
      start = @pos

      if (m = rest.match(/\A\[[0-9]+\]/)) then
        pos = @pos + m[0].length
        if @src[pos] == "'" then
          # Quoted sheet name of an external reference, e.g. '[1]My Sheet'!A1
          pos += 1
          pos += 1 while pos < @src.length &&
                        !(@src[pos] == "'" && @src[pos + 1] != "'")
          pos += 1
        elsif (wm = @src[pos..-1].match(/\A[[:alnum:]_.]+/)) then
          pos += wm[0].length
        end
        pos += 1 if @src[pos] == '!'
        body = scan_ref_body(pos)
        pos = body[0] if body
        @pos = pos
        emit_unsupported(@src[start...pos])
      elsif (m = rest.match(/\A\[[^\]]*\]/)) then
        emit_unsupported(m[0])
        @pos += m[0].length
      else
        emit_other('[')
        @pos += 1
      end
    end

    def scan_word_or_reference
      start = @pos
      rest = @src[start..-1]
      word = (wm = rest.match(WORD_PATTERN)) ? wm[0] : nil

      if word then
        after = rest[word.length]
        case after
        when '!' then
          body = scan_ref_body(start + word.length + 1)
          if body then
            end_pos, kind, matches = body
            token = build_reference_token(start, end_pos, kind, matches)
            token.sheet_name = word
            token.sheet_prefix = @src[start..(start + word.length)]
            @pos = end_pos
            @tokens << token
            return
          end
        when '(' then
          # Function name
          emit_other(word)
          @pos = start + word.length
          return
        when '[' then
          # Structured (table) reference, e.g. Table1[Column]
          pos = start + word.length
          depth = 0
          while pos < @src.length
            depth += 1 if @src[pos] == '['
            depth -= 1 if @src[pos] == ']'
            pos += 1
            break if depth.zero?
          end
          emit_unsupported(@src[start...pos])
          @pos = pos
          return
        when ':' then
          if (dm = rest.match(THREE_D_PATTERN)) then
            # 3-D reference, e.g. Sheet1:Sheet3!A1
            body = scan_ref_body(start + dm[0].length)
            @pos = body ? body[0] : start + dm[0].length
            emit_unsupported(@src[start...@pos])
            return
          end
        end
      end

      body = scan_ref_body(start)
      if body then
        end_pos, kind, matches = body
        @tokens << build_reference_token(start, end_pos, kind, matches)
        @pos = end_pos
      elsif word then
        emit_other(word)
        @pos = start + word.length
      else
        emit_other(@src[start])
        @pos = start + 1
      end
    end

    def scan_number_or_row_range
      rest = @src[@pos..-1]
      if (m = rest.match(ROW_RANGE_PATTERN)) && valid_row?(m[2]) && valid_row?(m[4]) then
        token = Token.new(:reference, m[0])
        token.kind = :row_range
        token.first_row = m[2].to_i - 1
        token.last_row = m[4].to_i - 1
        token.row_from_absolute = !m[1].empty?
        token.row_to_absolute = !m[3].empty?
        @tokens << token
        @pos += m[0].length
      else
        m = rest.match(NUMBER_PATTERN)
        emit_other(m ? m[0] : @src[@pos])
        @pos += m ? m[0].length : 1
      end
    end

    # Attempts to parse a reference body (cell, range, column range or row range)
    # starting at +pos+. Returns [end_pos, kind, matches] or nil.
    def scan_ref_body(pos)
      str = @src[pos..-1]
      return nil if str.nil? || str.empty?

      if (m = str.match(CELL_PATTERN)) && valid_cell?(m[2], m[4]) &&
           !word_char?(str[m[0].length]) && str[m[0].length] != '(' then
        rest = str[m[0].length..-1]
        if rest.start_with?(':') &&
             (m2 = rest[1..-1].to_s.match(CELL_PATTERN)) && valid_cell?(m2[2], m2[4]) &&
             !word_char?(rest[1 + m2[0].length]) then
          [pos + m[0].length + 1 + m2[0].length, :range, [m, m2]]
        else
          [pos + m[0].length, :cell, [m]]
        end
      elsif (m = str.match(COL_RANGE_PATTERN)) && valid_col?(m[2]) && valid_col?(m[4]) then
        [pos + m[0].length, :col_range, [m]]
      elsif (m = str.match(ROW_RANGE_PATTERN)) && valid_row?(m[2]) && valid_row?(m[4]) then
        [pos + m[0].length, :row_range, [m]]
      end
    end

    def build_reference_token(start, end_pos, kind, matches)
      token = Token.new(:reference, @src[start...end_pos])
      token.kind = kind
      m = matches[0]
      case kind
      when :cell, :range then
        token.first_col = self.class.col_index(m[2])
        token.first_row = m[4].to_i - 1
        token.col_from_absolute = !m[1].empty?
        token.row_from_absolute = !m[3].empty?
        if kind == :range then
          m2 = matches[1]
          token.last_col = self.class.col_index(m2[2])
          token.last_row = m2[4].to_i - 1
          token.col_to_absolute = !m2[1].empty?
          token.row_to_absolute = !m2[3].empty?
        else
          token.last_col = token.first_col
          token.last_row = token.first_row
          token.col_to_absolute = token.col_from_absolute
          token.row_to_absolute = token.row_from_absolute
        end
      when :col_range then
        token.first_col = self.class.col_index(m[2])
        token.last_col = self.class.col_index(m[4])
        token.col_from_absolute = !m[1].empty?
        token.col_to_absolute = !m[3].empty?
      when :row_range then
        token.first_row = m[2].to_i - 1
        token.last_row = m[4].to_i - 1
        token.row_from_absolute = !m[1].empty?
        token.row_to_absolute = !m[3].empty?
      end
      token
    end

    def word_char?(ch)
      !ch.nil? && ch.match?(WORD_CHAR_PATTERN)
    end

    def valid_cell?(col_str, row_str)
      valid_col?(col_str) && valid_row?(row_str)
    end

    def valid_col?(col_str)
      self.class.col_index(col_str) < MAX_COL
    end

    def valid_row?(row_str)
      row = row_str.to_i
      row >= 1 && row <= MAX_ROW
    end

    # Converts a column name (+A+..+XFD+) to a zero-based column index.
    def self.col_index(letters)
      letters.upcase.each_byte.inject(0) { |n, byte| n * 26 + (byte - 64) } - 1
    end
  end
end
