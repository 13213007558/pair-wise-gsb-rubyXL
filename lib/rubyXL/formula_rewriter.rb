require 'rubyXL/objects/reference'

module RubyXL
  # Raised when a formula contains a reference kind that RubyXL cannot rewrite
  # (external workbook references, structured/table references, 3D references).
  class UnsupportedReferenceError < StandardError; end

  # Tokenizes A1-style formulas and rewrites cell/range references in them,
  # leaving string constants, number literals, function names and all other
  # tokens untouched.
  module FormulaRewriter
    # A single A1-style reference found in a formula. Rows and columns are
    # zero-based; +row2+/+col2+ are nil for single-cell references.
    class RefToken
      attr_reader :sheet_name, :matched_text
      attr_reader :row1, :col1, :row2, :col2
      attr_reader :row1_abs, :col1_abs, :row2_abs, :col2_abs

      def initialize(params)
        @sheet_name   = params[:sheet_name] # nil when the reference is not sheet-qualified
        @matched_text = params[:matched_text]
        @row1 = params[:row1]
        @col1 = params[:col1]
        @row2 = params[:row2]
        @col2 = params[:col2]
        @row1_abs = params[:row1_abs]
        @col1_abs = params[:col1_abs]
        @row2_abs = params[:row2_abs]
        @col2_abs = params[:col2_abs]
      end

      def qualified?
        !@sheet_name.nil?
      end

      def range?
        !@row2.nil?
      end
    end

    # A reference construct RubyXL does not support rewriting
    # (external/structured/3D references).
    class UnsupportedToken
      attr_reader :text

      def initialize(text)
        @text = text
      end
    end

    SHEET_NAME_BARE = /[\p{L}\p{N}_.]+/.freeze
    SHEET_NAME_QUOTED = /'(?:[^']|'')+'/.freeze

    CELL_REF_PATTERN = /\$?[A-Za-z]{1,3}\$?[0-9]+(?::\$?[A-Za-z]{1,3}\$?[0-9]+)?/.freeze

    TOKENIZER = /
      (?<string>"(?:[^"]|"")*")
      |
      (?<unsupported>
        \[[0-9]+\]
        (?:(?:#{SHEET_NAME_QUOTED}|#{SHEET_NAME_BARE})!#{CELL_REF_PATTERN}|![\p{L}\p{N}_.]+)?
        |
        \[(?:[^\[\]]|\[[^\[\]]*\])*\]
        |
        \[
      )
      |
      (?<threed>(?:#{SHEET_NAME_QUOTED}|#{SHEET_NAME_BARE}):(?:#{SHEET_NAME_QUOTED}|#{SHEET_NAME_BARE})!#{CELL_REF_PATTERN})
      |
      (?<number>[0-9]+(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?)
      |
      (?<![A-Za-z0-9_.!])
      (?<ref>
        (?:(?<qsheet>#{SHEET_NAME_QUOTED})|(?<bsheet>#{SHEET_NAME_BARE}))!
        \$?[A-Za-z]{1,3}\$?[0-9]+
        (?::\$?[A-Za-z]{1,3}\$?[0-9]+)?
        |
        \$?[A-Za-z]{1,3}\$?[0-9]+
        (?::\$?[A-Za-z]{1,3}\$?[0-9]+)?
      )
      (?![A-Za-z0-9_.(!])
    /x.freeze

    CELL_REF = /\A(?<cabs1>\$?)(?<col1>[A-Za-z]{1,3})(?<rabs1>\$?)(?<row1>[0-9]+)
                (?::(?<cabs2>\$?)(?<col2>[A-Za-z]{1,3})(?<rabs2>\$?)(?<row2>[0-9]+))?\z/x.freeze

    SHEET_PREFIX = /\A(?:#{SHEET_NAME_QUOTED}|#{SHEET_NAME_BARE})!/.freeze

    # Scans +expression+ and yields every reference token to the block.
    # The block may return a replacement String, or nil to keep the original text.
    # Returns the rewritten expression.
    #
    # Unsupported tokens (external/structured/3D references) are also yielded
    # (as UnsupportedToken); if no block is given, UnsupportedReferenceError is raised.
    def self.rewrite(expression)
      expression.to_s.gsub(TOKENIZER) do |matched|
        match = Regexp.last_match

        if match[:unsupported] || match[:threed] then
          token = UnsupportedToken.new(matched)
          if block_given? then
            replacement = yield(token)
            replacement.nil? ? matched : replacement
          else
            raise UnsupportedReferenceError,
                  "unsupported reference #{matched.inspect} in formula #{expression.inspect}"
          end
        elsif match[:ref] then
          replacement = block_given? ? yield(build_ref_token(match, matched)) : nil
          replacement.nil? ? matched : replacement
        else
          matched # string constants and number literals pass through untouched
        end
      end
    end

    # Splits "Sheet1!A1" / "'My Sheet'!A1" / "A1" into [sheet_name_or_nil, a1_part].
    def self.split_sheet_reference(str)
      if (match = str.match(/\A'((?:[^']|'')+)'!(.*)\z/m)) then
        [ match[1].gsub("''", "'"), match[2] ]
      elsif (match = str.match(/\A([^!]+)!(.*)\z/m)) then
        [ match[1], match[2] ]
      else
        [ nil, str ]
      end
    end

    # Quotes a sheet name for use in a formula, if quoting is necessary.
    def self.quote_sheet_name(name)
      if name =~ /\A[\p{L}_][\p{L}\p{N}_.]*\z/ && name !~ /\A\$?[A-Za-z]{1,3}\$?[0-9]+\z/ then
        name
      else
        "'#{name.gsub("'", "''")}'"
      end
    end

    # Builds an A1-style reference string from parts (zero-based indices).
    def self.build_reference(sheet_name: nil, qualified: false,
                             row1:, col1:, row1_abs: false, col1_abs: false,
                             row2: nil, col2: nil, row2_abs: false, col2_abs: false)
      result = +''
      result << quote_sheet_name(sheet_name) << '!' if qualified && sheet_name
      result << RubyXL::Reference.ind2ref(row1, col1, row1_abs, col1_abs)
      unless row2.nil?
        result << ':' << RubyXL::Reference.ind2ref(row2, col2, row2_abs, col2_abs)
      end
      result
    end

    def self.build_ref_token(match, matched)
      ref_text = match[:ref]
      sheet_name = nil

      if match[:qsheet] then
        sheet_name = match[:qsheet][1..-2].gsub("''", "'")
      elsif match[:bsheet] then
        sheet_name = match[:bsheet]
      end

      ref_text = ref_text.sub(SHEET_PREFIX, '') if sheet_name
      parts = ref_text.match(CELL_REF)

      RefToken.new(
        :sheet_name   => sheet_name,
        :matched_text => matched,
        :row1 => parts[:row1].to_i - 1,
        :col1 => col_name_to_index(parts[:col1]),
        :row1_abs => !parts[:rabs1].empty?,
        :col1_abs => !parts[:cabs1].empty?,
        :row2 => parts[:row2] && parts[:row2].to_i - 1,
        :col2 => parts[:col2] && col_name_to_index(parts[:col2]),
        :row2_abs => !parts[:rabs2].to_s.empty?,
        :col2_abs => !parts[:cabs2].to_s.empty?
      )
    end
    private_class_method :build_ref_token

    def self.col_name_to_index(col_name)
      col_name.each_byte.inject(0) { |col, chr| (col * 26) + (chr - 64) } - 1
    end
    private_class_method :col_name_to_index
  end
end
