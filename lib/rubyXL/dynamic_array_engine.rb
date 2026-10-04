require 'strscan'
require 'rubyXL/objects/sheet_data'
require 'rubyXL/objects/formula'
require 'rubyXL/objects/reference'

module RubyXL
  # A deliberately small, but fully functional, dynamic-array calculation engine.
  #
  # Supported formula language:
  #   * constant matrices:        {1,2;3,4}        (columns separated by ',', rows by ';')
  #   * SEQUENCE(rows, cols, start, step)
  #   * FILTER(array, include)    (include is a row/column vector of booleans/numbers)
  #   * TRANSPOSE(array)
  #   * element-wise arithmetic:  + - * /          (with scalar/vector broadcasting)
  #   * cell references:          A1, A1:B2, and spilled-range references A1#
  #
  # Grid semantics:
  #   * The anchor cell owns its spill range. The dynamic formula is stored on the
  #     anchor as <f t="array" aca="1" ref="A1:B2">...</f>; spill cells carry only
  #     cached values, so saving and re-loading a workbook preserves both the
  #     formulas and the cached results, and spill membership can be recovered
  #     from the anchor's +ref+.
  #   * When a spill shrinks, the cells it used to occupy are released.
  #   * When a spill grows into user values, merged cells, or another spill,
  #     the anchor gets a #SPILL! error and the old spill is released atomically:
  #     no half-written results are ever left behind, and user cells are never
  #     overwritten.
  #   * A1# dependencies are re-evaluated whenever the anchor's shape changes.
  #   * Circular dependencies between anchors are reported separately as #CYCLE!.
  class DynamicArrayEngine
    SPILL_ERROR_CODE = '#SPILL!'
    CYCLE_ERROR_CODE = '#CYCLE!'
    VALUE_ERROR_CODE = '#VALUE!'
    REF_ERROR_CODE   = '#REF!'
    CALC_ERROR_CODE  = '#CALC!'
    DIV0_ERROR_CODE  = '#DIV/0!'
    NAME_ERROR_CODE  = '#NAME?'

    # In-memory representation of an Excel-style error literal.
    class ErrorValue
      attr_reader :code

      def initialize(code)
        @code = code
      end

      def ==(other)
        other.is_a?(ErrorValue) && other.code == code
      end

      def eql?(other)
        self == other
      end

      def hash
        code.hash
      end

      def to_s
        code
      end

      def inspect
        code
      end
    end

    SPILL_ERROR = ErrorValue.new(SPILL_ERROR_CODE)
    CYCLE_ERROR = ErrorValue.new(CYCLE_ERROR_CODE)
    VALUE_ERROR = ErrorValue.new(VALUE_ERROR_CODE)
    REF_ERROR   = ErrorValue.new(REF_ERROR_CODE)
    CALC_ERROR  = ErrorValue.new(CALC_ERROR_CODE)
    DIV0_ERROR  = ErrorValue.new(DIV0_ERROR_CODE)
    NAME_ERROR  = ErrorValue.new(NAME_ERROR_CODE)

    # Raised during parsing/evaluation; carries the ErrorValue to cache on the anchor.
    class EvaluationError < StandardError
      attr_reader :error_value

      def initialize(error_value)
        @error_value = error_value
        super(error_value.code)
      end
    end

    Anchor = Struct.new(:row, :col, :expression, :ast, :ref, :parse_error) do
      def key
        [row, col]
      end
    end

    attr_reader :worksheet, :anchors, :user_overrides, :errors, :cyclic_keys

    def initialize(worksheet)
      @worksheet = worksheet
      @anchors = nil
      @user_overrides = []
      @errors = {}
      @cyclic_keys = []
    end

    # Rebuilds the anchor map from the worksheet. Anchors are cells carrying a
    # dynamic-array formula (<f t="array" aca="1" ref="...">); the +ref+ is the
    # currently committed spill range, so spill membership survives a save/load.
    def scan
      @anchors = {}
      rows = @worksheet.sheet_data && @worksheet.sheet_data.rows
      return if rows.nil?

      rows.each_with_index do |row_obj, r|
        next if row_obj.nil?

        row_obj.cells.each_with_index do |cell, c|
          next if cell.nil?

          formula = cell.formula
          next if formula.nil? || formula.t != 'array' || !formula.aca

          ref = formula.ref || RubyXL::Reference.new(r, c)
          @anchors[[r, c]] = Anchor.new(r, c, formula.expression, nil, ref)
        end
      end
    end

    def ensure_scanned
      scan if @anchors.nil?
    end

    # Sets (or replaces) the dynamic-array formula anchored at (+row+, +col+)
    # and recalculates the whole sheet. Raises EvaluationError on unparsable
    # expressions; evaluation failures are cached on the anchor as error values.
    def set_formula(row, col, expression)
      FormulaParser.new(expression).parse # Validate before touching the sheet.
      ensure_scanned

      cell = ensure_cell(row, col)
      existing = @anchors[[row, col]]
      ref = existing ? existing.ref : RubyXL::Reference.new(row, col)
      cell.formula = RubyXL::Formula.new(
        :expression => expression.to_s,
        :t          => 'array',
        :aca        => true,
        :ref        => ref
      )
      recalculate
    end

    # Recalculates every dynamic-array formula on the worksheet in dependency
    # order. Returns a Hash of { [row, col] => ErrorValue } for failed anchors.
    def recalculate
      scan
      @errors = {}
      @cyclic_keys = []
      return @errors if @anchors.empty?

      @anchors.each_value do |anchor|
        begin
          anchor.ast = FormulaParser.new(anchor.expression).parse
          anchor.parse_error = nil
        rescue EvaluationError => e
          anchor.ast = nil
          anchor.parse_error = e.error_value
        end
      end

      deps = build_dependencies
      @cyclic_keys = deps.keys.select { |key| cyclic?(key, deps) }

      @anchors.each_value do |anchor|
        commit_error(anchor, anchor.parse_error) if anchor.parse_error
      end
      @cyclic_keys.each { |key| commit_error(@anchors[key], CYCLE_ERROR) }

      topo_order(deps, @cyclic_keys).each do |key|
        anchor = @anchors[key]
        begin
          commit_result(anchor, evaluate(anchor.ast))
        rescue EvaluationError => e
          commit_error(anchor, e.error_value)
        end
      end

      cleanup_overrides
      @errors
    end

    # Returns the [row, col] of the anchor owning the spill covering (+row+, +col+),
    # or nil if the cell is not part of any spill. A cell that is itself an anchor
    # maps to its own key.
    def anchor_at(row, col)
      ensure_scanned
      owner_of(row, col)
    end

    # Returns the RubyXL::Reference of the spill range covering (+row+, +col+), or nil.
    def spill_range_at(row, col)
      ensure_scanned
      owner = owner_of(row, col)
      owner && @anchors[owner].ref
    end

    # Called by LegacyWorksheet#add_cell when the user writes a cell directly.
    # A user value landing inside an existing spill must not be silently
    # overwritten on the next recalculation: it starts blocking the spill instead.
    def note_user_write(row, col)
      return if @anchors.nil?

      key = [row, col]
      owner = owner_of(row, col)
      @user_overrides << key if owner && owner != key && !@user_overrides.include?(key)
    end

    private

    def build_dependencies
      deps = {}
      @anchors.each do |key, anchor|
        next if anchor.parse_error

        collected = []
        collect_deps(anchor.ast, collected)
        deps[key] = collected.uniq.select { |dep| @anchors.key?(dep) }
      end
      deps
    end

    def collect_deps(node, collected)
      case node[0]
      when :cell
        owner = owner_of(node[1], node[2])
        collected << owner if owner
      when :range
        @anchors.each_value do |anchor|
          collected << anchor.key if rects_intersect?(node[1], node[2], node[3], node[4], anchor.ref)
        end
      when :spill
        collected << [node[1], node[2]]
      when :matrix
        node[1].each { |row| row.each { |element| collect_deps(element, collected) } }
      when :neg
        collect_deps(node[1], collected)
      when :binop
        collect_deps(node[2], collected)
        collect_deps(node[3], collected)
      when :call
        node[2].each { |arg| collect_deps(arg, collected) }
      end
    end

    def rects_intersect?(row_from, col_from, row_to, col_to, ref)
      row_from <= ref.last_row && ref.first_row <= row_to &&
        col_from <= ref.last_col && ref.first_col <= col_to
    end

    def cyclic?(key, deps)
      stack = (deps[key] || []).dup
      seen = {}
      until stack.empty?
        node = stack.pop
        return true if node == key
        next if seen[node]

        seen[node] = true
        stack.concat(deps[node] || [])
      end
      false
    end

    def topo_order(deps, cyclic_keys)
      eligible = deps.keys - cyclic_keys
      indegree = {}
      dependents = Hash.new { |hash, key| hash[key] = [] }
      eligible.each do |key|
        local_deps = deps[key] & eligible
        indegree[key] = local_deps.size
        local_deps.each { |dep| dependents[dep] << key }
      end

      queue = eligible.select { |key| indegree[key] == 0 }
      order = []
      until queue.empty?
        key = queue.shift
        order << key
        dependents[key].each do |dependent|
          indegree[dependent] -= 1
          queue << dependent if indegree[dependent] == 0
        end
      end
      order + (eligible - order) # Defensive: leftovers can only come from cycles.
    end

    def cleanup_overrides
      @user_overrides.reject! { |(r, c)| owner_of(r, c).nil? }
    end

    # ---------------------------------------------------------------------
    # Evaluation
    # ---------------------------------------------------------------------

    def evaluate(node)
      case node[0]
      when :number, :string, :boolean then node[1]
      when :name then raise EvaluationError, NAME_ERROR
      when :cell then read_cell_value(node[1], node[2])
      when :range then read_range(node[1], node[2], node[3], node[4])
      when :spill then read_spill(node[1], node[2])
      when :matrix
        node[1].map { |row| row.map { |element| scalarize(evaluate(element)) } }
      when :neg
        elementwise_unary(evaluate(node[1]))
      when :binop
        elementwise_binary(node[1], evaluate(node[2]), evaluate(node[3]))
      when :call
        call_function(node[1], node[2].map { |arg| evaluate(arg) })
      else
        raise EvaluationError, NAME_ERROR
      end
    end

    def call_function(name, args)
      case name
      when 'SEQUENCE'  then fn_sequence(args)
      when 'TRANSPOSE' then fn_transpose(args)
      when 'FILTER'    then fn_filter(args)
      else raise EvaluationError, NAME_ERROR
      end
    end

    def fn_sequence(args)
      raise EvaluationError, VALUE_ERROR if args.empty? || args.size > 4

      rows  = numeric_scalar(args[0]).to_i
      cols  = args.size > 1 ? numeric_scalar(args[1]).to_i : 1
      start = args.size > 2 ? numeric_scalar(args[2]) : 1
      step  = args.size > 3 ? numeric_scalar(args[3]) : 1
      raise EvaluationError, CALC_ERROR if rows < 1 || cols < 1

      Array.new(rows) do |i|
        Array.new(cols) do |j|
          normalize_number(start + (i * cols + j) * step)
        end
      end
    end

    def fn_transpose(args)
      raise EvaluationError, VALUE_ERROR unless args.size == 1

      to_matrix(args[0]).transpose
    end

    def fn_filter(args)
      raise EvaluationError, VALUE_ERROR unless args.size == 2 || args.size == 3

      array = to_matrix(args[0])
      include = to_matrix(args[1])
      if_empty = args.size == 3 ? args[2] : nil

      result =
        if include.size == array.size && include[0].size == 1
          kept = []
          array.each_with_index do |row, i|
            kept << row if truthy?(include[i][0])
          end
          kept
        elsif include.size == 1 && include[0].size == array[0].size
          kept_cols = []
          array[0].size.times do |j|
            kept_cols << j if truthy?(include[0][j])
          end
          array.map { |row| kept_cols.map { |j| row[j] } }
        else
          raise EvaluationError, VALUE_ERROR
        end

      if result.empty? || result[0].empty?
        raise EvaluationError, CALC_ERROR if if_empty.nil?

        return if_empty
      end
      result
    end

    def truthy?(value)
      raise EvaluationError, value if value.is_a?(ErrorValue)

      case value
      when Numeric then value != 0
      when true    then true
      when false   then false
      else raise EvaluationError, VALUE_ERROR
      end
    end

    def elementwise_unary(value)
      matrix = to_matrix(value)
      result = matrix.map do |row|
        row.map do |element|
          if element.is_a?(ErrorValue) then element
          else
            number = coerce_number(element)
            number.nil? ? VALUE_ERROR : normalize_number(-number)
          end
        end
      end
      result.size == 1 && result[0].size == 1 ? result[0][0] : result
    end

    def elementwise_binary(op, left, right)
      left_matrix = to_matrix(left)
      right_matrix = to_matrix(right)
      rows = [left_matrix.size, right_matrix.size].max
      cols = [left_matrix[0].size, right_matrix[0].size].max

      compatible = [left_matrix, right_matrix].all? { |m| m.size == rows || m.size == 1 } &&
                   [left_matrix, right_matrix].all? { |m| m[0].size == cols || m[0].size == 1 }
      raise EvaluationError, VALUE_ERROR unless compatible

      result = Array.new(rows) do |i|
        Array.new(cols) do |j|
          arith(op, broadcast_fetch(left_matrix, i, j), broadcast_fetch(right_matrix, i, j))
        end
      end
      rows == 1 && cols == 1 ? result[0][0] : result
    end

    def broadcast_fetch(matrix, i, j)
      matrix[matrix.size == 1 ? 0 : i][matrix[0].size == 1 ? 0 : j]
    end

    def arith(op, left, right)
      return left if left.is_a?(ErrorValue)
      return right if right.is_a?(ErrorValue)

      ln = coerce_number(left)
      rn = coerce_number(right)
      return VALUE_ERROR if ln.nil? || rn.nil?

      case op
      when :+ then normalize_number(ln + rn)
      when :- then normalize_number(ln - rn)
      when :* then normalize_number(ln * rn)
      when :/
        return DIV0_ERROR if rn == 0

        normalize_number(ln.to_f / rn)
      end
    end

    def coerce_number(value)
      case value
      when Numeric then value
      when true    then 1
      when false   then 0
      when nil     then 0
      when String
        stripped = value.strip
        if stripped =~ /\A[+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\z/
          stripped.include?('.') || stripped =~ /[eE]/ ? stripped.to_f : stripped.to_i
        end
      end
    end

    def normalize_number(value)
      value.is_a?(Float) && value.finite? && value == value.to_i ? value.to_i : value
    end

    def to_matrix(value)
      value.is_a?(Array) ? value : [[value]]
    end

    def scalarize(value)
      return value unless value.is_a?(Array)
      raise EvaluationError, VALUE_ERROR unless value.size == 1 && value[0].size == 1

      value[0][0]
    end

    def numeric_scalar(value)
      scalar = scalarize(value)
      raise EvaluationError, scalar if scalar.is_a?(ErrorValue)

      number = coerce_number(scalar)
      raise EvaluationError, VALUE_ERROR if number.nil?

      number
    end

    # ---------------------------------------------------------------------
    # Grid reads
    # ---------------------------------------------------------------------

    def cell_at(row, col)
      row_obj = @worksheet.sheet_data.rows[row]
      row_obj && row_obj.cells[col]
    end

    def read_cell_value(row, col)
      cell = cell_at(row, col)
      return 0 if cell.nil?

      case cell.datatype
      when RubyXL::DataType::ERROR
        ErrorValue.new(cell.raw_value.to_s)
      when RubyXL::DataType::RAW_STRING
        cell.raw_value.to_s
      when RubyXL::DataType::INLINE_STRING
        cell.is ? cell.is.to_s : cell.raw_value.to_s
      when RubyXL::DataType::BOOLEAN
        cell.raw_value.to_i != 0
      when RubyXL::DataType::SHARED_STRING
        cell.value
      else
        raw = cell.raw_value
        case raw
        when Numeric then raw
        when nil     then 0
        when String
          if raw =~ RubyXL::Cell::NUMBER_REGEXP
            Regexp.last_match(1) == '' ? raw.to_i : raw.to_f
          else
            raw
          end
        else raw
        end
      end
    end

    def read_range(row_from, col_from, row_to, col_to)
      (row_from..row_to).map do |r|
        (col_from..col_to).map do |c|
          read_cell_value(r, c)
        end
      end
    end

    def read_spill(row, col)
      anchor = @anchors[[row, col]]
      raise EvaluationError, REF_ERROR if anchor.nil?

      read_range(anchor.ref.first_row, anchor.ref.first_col,
                 anchor.ref.last_row, anchor.ref.last_col)
    end

    # ---------------------------------------------------------------------
    # Committing results to the grid
    # ---------------------------------------------------------------------

    def commit_result(anchor, value)
      matrix = to_matrix(value)
      rows = matrix.size
      cols = matrix[0].size
      new_ref = RubyXL::Reference.new(anchor.row, anchor.row + rows - 1,
                                      anchor.col, anchor.col + cols - 1)

      if spill_blocked?(anchor, new_ref)
        commit_error(anchor, SPILL_ERROR)
        return
      end

      release_spill(anchor, new_ref)
      new_ref.row_range.each do |r|
        new_ref.col_range.each do |c|
          cell = ensure_cell(r, c)
          cell.formula = nil unless r == anchor.row && c == anchor.col
          write_cached_value(cell, matrix[r - anchor.row][c - anchor.col])
        end
      end
      update_committed_ref(anchor, new_ref)
    end

    def commit_error(anchor, error_value)
      release_spill(anchor, nil)
      anchor_only = RubyXL::Reference.new(anchor.row, anchor.col)
      update_committed_ref(anchor, anchor_only)
      write_cached_value(ensure_cell(anchor.row, anchor.col), error_value)
      @errors[anchor.key] = error_value
    end

    def update_committed_ref(anchor, new_ref)
      anchor.ref = new_ref
      cell = cell_at(anchor.row, anchor.col)
      cell.formula.ref = new_ref if cell && cell.formula
    end

    # Checks every cell of the candidate spill range before anything is
    # written, so a blocked spill never leaves partial results behind.
    def spill_blocked?(anchor, new_ref)
      new_ref.row_range.each do |r|
        new_ref.col_range.each do |c|
          return true if merged_covering?(r, c)
          next if r == anchor.row && c == anchor.col
          return true if @user_overrides.include?([r, c])
          return true if @anchors.key?([r, c]) # Another anchor's anchor cell.

          owner = owner_of(r, c)
          next if owner == anchor.key # Own previously committed spill cell.
          return true if owner        # Another anchor's spill.
          return true if cell_has_content?(r, c)
        end
      end
      false
    end

    # Removes the cells of the anchor's previously committed spill that are not
    # part of +keep_ref+. User-overwritten cells and other anchors are kept.
    def release_spill(anchor, keep_ref)
      old_ref = anchor.ref
      return if old_ref.nil?

      old_ref.row_range.each do |r|
        old_ref.col_range.each do |c|
          next if r == anchor.row && c == anchor.col
          next if keep_ref && keep_ref.row_range.cover?(r) && keep_ref.col_range.cover?(c)
          next if @user_overrides.include?([r, c])
          next if @anchors.key?([r, c])

          delete_cell(r, c)
        end
      end
    end

    def owner_of(row, col)
      @anchors.each do |key, anchor|
        return key if anchor.ref.row_range.cover?(row) && anchor.ref.col_range.cover?(col)
      end
      nil
    end

    def merged_covering?(row, col)
      merged = @worksheet.merged_cells
      return false if merged.nil?

      merged.any? { |mc| mc.ref.row_range.cover?(row) && mc.ref.col_range.cover?(col) }
    end

    def cell_has_content?(row, col)
      cell = cell_at(row, col)
      return false if cell.nil?
      return true if cell.formula || cell.is

      raw = cell.raw_value
      !(raw.nil? || raw == '')
    end

    def ensure_cell(row, col)
      sheet_data = @worksheet.sheet_data
      row_obj = sheet_data.rows[row]
      if row_obj.nil?
        row_obj = RubyXL::Row.new
        row_obj.worksheet = @worksheet
        sheet_data.rows[row] = row_obj
      end

      cell = row_obj.cells[col]
      if cell.nil?
        cell = RubyXL::Cell.new
        cell.worksheet = @worksheet
        cell.row = row
        cell.column = col
        row_obj.cells[col] = cell
      end
      cell
    end

    def delete_cell(row, col)
      row_obj = @worksheet.sheet_data.rows[row]
      row_obj.cells[col] = nil if row_obj
    end

    def write_cached_value(cell, value)
      case value
      when ErrorValue
        cell.datatype = RubyXL::DataType::ERROR
        cell.raw_value = value.code
      when Numeric
        cell.datatype = RubyXL::DataType::NUMBER
        cell.raw_value = value
      when true, false
        cell.datatype = RubyXL::DataType::BOOLEAN
        cell.raw_value = value ? 1 : 0
      when nil
        cell.datatype = RubyXL::DataType::NUMBER
        cell.raw_value = nil
      else
        cell.datatype = RubyXL::DataType::RAW_STRING
        cell.raw_value = value.to_s
      end
    end

    # Recursive-descent parser for the limited formula language. Produces a
    # small AST made of arrays: [:number, v], [:string, v], [:boolean, v],
    # [:cell, r, c], [:range, r1, c1, r2, c2], [:spill, r, c],
    # [:matrix, [[...]]], [:neg, e], [:binop, op, l, r], [:call, name, args],
    # [:name, ident].
    class FormulaParser
      CELL_REF_REGEX = /\A\$?[A-Za-z]{1,3}\$?\d+\z/

      def initialize(source)
        text = source.to_s.strip
        text = text[1..-1] if text.start_with?('=')
        @tokens = tokenize(text)
        @pos = 0
      end

      def parse
        node = parse_additive
        raise EvaluationError, NAME_ERROR unless @pos == @tokens.length

        node
      end

      private

      def tokenize(text)
        tokens = []
        scanner = StringScanner.new(text)
        until scanner.eos?
          scanner.skip(/\s+/)
          break if scanner.eos?

          if (token = scanner.scan(/\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/))
            tokens << [:number, token.include?('.') || token =~ /[eE]/ ? token.to_f : token.to_i]
          elsif (token = scanner.scan(/"(?:[^"]|"")*"/))
            tokens << [:string, token[1..-2].gsub('""', '"')]
          elsif (token = scanner.scan(/\$?[A-Za-z]{1,3}\$?\d+/))
            tokens << [:cellref, token]
          elsif (token = scanner.scan(/[A-Za-z_][A-Za-z0-9_.]*/))
            tokens << [:ident, token]
          elsif (token = scanner.scan(/[()+\-*\/{},;:#]/))
            tokens << [:op, token]
          else
            raise EvaluationError, NAME_ERROR
          end
        end
        tokens
      end

      def peek
        @tokens[@pos]
      end

      def advance
        @pos += 1
      end

      def accept_op(*ops)
        token = peek
        return nil unless token && token[0] == :op && ops.include?(token[1])

        advance
        token[1]
      end

      def expect_op(op)
        raise EvaluationError, NAME_ERROR unless accept_op(op)
      end

      def expect_cellref
        token = peek
        raise EvaluationError, NAME_ERROR if token.nil? || token[0] != :cellref

        advance
        token[1]
      end

      def parse_additive
        left = parse_multiplicative
        while (op = accept_op('+', '-'))
          left = [:binop, op.to_sym, left, parse_multiplicative]
        end
        left
      end

      def parse_multiplicative
        left = parse_unary
        while (op = accept_op('*', '/'))
          left = [:binop, op.to_sym, left, parse_unary]
        end
        left
      end

      def parse_unary
        if accept_op('-')
          [:neg, parse_unary]
        elsif accept_op('+')
          parse_unary
        else
          parse_postfix
        end
      end

      def parse_postfix
        node = parse_primary
        while accept_op('#')
          raise EvaluationError, REF_ERROR unless node[0] == :cell

          node = [:spill, node[1], node[2]]
        end
        node
      end

      def parse_primary
        token = peek
        raise EvaluationError, NAME_ERROR if token.nil?

        case token[0]
        when :number
          advance
          [:number, token[1]]
        when :string
          advance
          [:string, token[1]]
        when :cellref
          advance
          row, col = ref_to_indices(token[1])
          if accept_op(':')
            row2, col2 = ref_to_indices(expect_cellref)
            [:range, [row, row2].min, [col, col2].min, [row, row2].max, [col, col2].max]
          else
            [:cell, row, col]
          end
        when :ident
          advance
          name = token[1].upcase
          if accept_op('(')
            args = []
            unless accept_op(')')
              loop do
                args << parse_additive
                if accept_op(',')
                  next
                elsif accept_op(')')
                  break
                else
                  raise EvaluationError, NAME_ERROR
                end
              end
            end
            [:call, name, args]
          elsif name == 'TRUE'
            [:boolean, true]
          elsif name == 'FALSE'
            [:boolean, false]
          else
            [:name, name]
          end
        when :op
          case token[1]
          when '('
            advance
            node = parse_additive
            expect_op(')')
            node
          when '{'
            advance
            parse_matrix
          else
            raise EvaluationError, NAME_ERROR
          end
        else
          raise EvaluationError, NAME_ERROR
        end
      end

      def parse_matrix
        rows = []
        loop do
          row = [parse_additive]
          row << parse_additive while accept_op(',')
          rows << row
          if accept_op(';')
            next
          elsif accept_op('}')
            break
          else
            raise EvaluationError, NAME_ERROR
          end
        end
        raise EvaluationError, VALUE_ERROR if rows.map(&:size).uniq.size > 1

        [:matrix, rows]
      end

      def ref_to_indices(ref_string)
        ref = RubyXL::Reference.new(ref_string.delete('$'))
        [ref.first_row, ref.first_col]
      end
    end
  end

  # Worksheet-level entry points for the dynamic-array engine.
  module WorksheetDynamicArrays
    def dynamic_array_engine
      @dynamic_array_engine ||= RubyXL::DynamicArrayEngine.new(self)
    end

    # Anchors a dynamic-array formula at (+row+, +col+) and recalculates.
    def set_dynamic_formula(row, col, expression)
      dynamic_array_engine.set_formula(row, col, expression)
    end

    # Recalculates all dynamic-array formulas on this worksheet.
    # Returns a Hash of { [row, col] => ErrorValue } for failed anchors.
    def recalculate_dynamic_arrays
      dynamic_array_engine.recalculate
    end

    # Returns the [row, col] key of the anchor whose spill covers (+row+, +col+), or nil.
    def spill_anchor_at(row, col)
      dynamic_array_engine.anchor_at(row, col)
    end

    # Returns the RubyXL::Reference of the spill range covering (+row+, +col+), or nil.
    def spill_range_at(row, col)
      dynamic_array_engine.spill_range_at(row, col)
    end

    # True if (+row+, +col+) hosts a dynamic-array formula.
    def dynamic_anchor?(row, col)
      dynamic_array_engine.anchor_at(row, col) == [row, col]
    end
  end

  RubyXL::Worksheet.send(:include, RubyXL::WorksheetDynamicArrays) # ruby 2.1 compat
end
