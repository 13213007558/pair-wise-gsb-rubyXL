require 'rubyXL/formula_rewriter'

module RubyXL
  # Raised when a rectangular range move (cut/paste) cannot be performed.
  # The workbook is guaranteed to be left unmodified when this error is raised.
  class MoveError < StandardError; end

  # Moves a rectangular range of cells to another location (cut/paste semantics),
  # updating every reference to the moved cells throughout the workbook.
  #
  # Unlike copying, moving ignores the +$+ (absolute) markers: a reference that
  # points to a moved cell is always updated to the cell's new address, while
  # the formula text of the moved cells themselves is carried over verbatim
  # (except references to cells that moved along, which follow the move).
  #
  # === Semantics
  # * The destination is specified by its top-left cell; existing contents of the
  #   destination rectangle are replaced, and the source cells are cleared.
  # * If the destination rectangle overlaps the source rectangle (on the same
  #   sheet), the move is rejected with RubyXL::MoveError; moving a range onto
  #   itself exactly is a no-op.
  # * Cell formulas on every worksheet, defined names, data validation formulas,
  #   data validation +sqref+ ranges, merged cell ranges and chart series
  #   formulas are updated uniformly.
  # * References inside string constants (e.g. +"A1"+) are never rewritten.
  # * Ranges that partially intersect the moved range are split into a union of
  #   rectangles where the context allows it (cell formulas, defined names and
  #   +sqref+ lists); everywhere else (data validation formulas, chart series,
  #   shared/array formula ranges, merged cells) a partial overlap is rejected
  #   with RubyXL::MoveError rather than producing an incorrect rectangle.
  # * External workbook references (+[1]Sheet1!A1+), 3-D references
  #   (+Sheet1:Sheet3!A1+) and structured (table) references (+Table1[Column]+)
  #   are not supported: they are reported via RubyXL::MoveError before any
  #   change is made.
  # * The move is atomic: the workbook is scanned and all rewrites are computed
  #   before anything is modified, so a failed move leaves the workbook usable.
  class RangeMove
    MAX_ROW = RubyXL::FormulaRewriter::MAX_ROW
    MAX_COL = RubyXL::FormulaRewriter::MAX_COL

    attr_reader :workbook, :src_sheet, :dst_sheet

    # +workbook+    - RubyXL::Workbook
    # +source+      - RubyXL::Reference or String, e.g. "Sheet1!B2:D8"
    #                 (sheet name optional, defaults to the first worksheet)
    # +destination+ - RubyXL::Reference or String with the top-left cell of the
    #                 target, e.g. "Sheet2!A1" (sheet defaults to source sheet)
    def initialize(workbook, source, destination)
      @workbook = workbook
      @errors = []

      src = source.is_a?(RubyXL::Reference) ? source : RubyXL::Reference.new(source.to_s)
      dst = destination.is_a?(RubyXL::Reference) ? destination : RubyXL::Reference.new(destination.to_s)

      @src_sheet = resolve_sheet(src.sheet_name)
      raise MoveError, "move_range: unknown source sheet #{src.sheet_name.inspect}" if @src_sheet.nil?
      @dst_sheet = dst.sheet_name ? resolve_sheet(dst.sheet_name) : @src_sheet
      raise MoveError, "move_range: unknown destination sheet #{dst.sheet_name.inspect}" if @dst_sheet.nil?
      unless dst.valid? && dst.single_cell? then
        raise MoveError, 'move_range: destination must be a single cell (the top-left cell of the target)'
      end

      @row1 = src.row_range.begin
      @row2 = src.row_range.end
      @col1 = src.col_range.begin
      @col2 = src.col_range.end

      unless src.valid? && @row2 < MAX_ROW && @col2 < MAX_COL then
        raise MoveError, "move_range: source #{src} is not a bounded rectangular range"
      end

      @dst_row = dst.row_range.begin
      @dst_col = dst.col_range.begin
      @drow = @dst_row - @row1
      @dcol = @dst_col - @col1

      if @dst_row + height > MAX_ROW || @dst_col + width > MAX_COL then
        raise MoveError, 'move_range: destination range exceeds worksheet bounds'
      end

      @noop = false
      if @src_sheet.equal?(@dst_sheet) && intersect_rectangles(src_rect, dst_rect) then
        if @drow.zero? && @dcol.zero? then
          @noop = true # Moving a range onto itself: nothing to do.
        else
          raise MoveError, 'move_range: destination overlaps the source range'
        end
      end
    end

    def height
      @row2 - @row1 + 1
    end

    def width
      @col2 - @col1 + 1
    end

    def execute
      return self if @noop
      plan = build_plan
      unless @errors.empty? then
        raise MoveError, "move_range cannot be performed, the workbook was left unchanged:\n" +
                         @errors.collect { |e| "  * #{e}" }.join("\n")
      end
      apply_plan(plan)
      self
    end

    # Returns the A1-style sheet prefix (e.g. +Sheet1!+ or +'My Sheet'!+) for a sheet name.
    def self.sheet_prefix(sheet_name)
      name = sheet_name.to_s
      if name =~ /\A[A-Za-z_][A-Za-z0-9_.]*\z/ && name !~ /\A\$?[A-Za-z]{1,3}\$?[0-9]+\z/i then
        "#{name}!"
      else
        "'#{name.gsub("'", "''")}'!"
      end
    end

    private

    def src_rect
      [@row1, @col1, @row2, @col2]
    end

    def dst_rect
      [@dst_row, @dst_col, @dst_row + height - 1, @dst_col + width - 1]
    end

    def intersect_rectangles(rect1, rect2)
      r1 = [rect1[0], rect2[0]].max
      c1 = [rect1[1], rect2[1]].max
      r2 = [rect1[2], rect2[2]].min
      c2 = [rect1[3], rect2[3]].min
      (r1 <= r2 && c1 <= c2) ? [r1, c1, r2, c2] : nil
    end

    def intersect_source(r1, c1, r2, c2)
      intersect_rectangles([r1, c1, r2, c2], src_rect)
    end

    # Decomposes +rect minus hole+ (both [r1, c1, r2, c2]) into up to 4 rectangles.
    def subtract_rectangle(r1, c1, r2, c2, hole)
      hr1, hc1, hr2, hc2 = hole
      pieces = []
      pieces << [r1, c1, hr1 - 1, c2] if hr1 > r1
      pieces << [hr2 + 1, c1, r2, c2] if hr2 < r2
      pieces << [hr1, c1, hr2, hc1 - 1] if hc1 > c1
      pieces << [hr1, hc2 + 1, hr2, c2] if hc2 < c2
      pieces
    end

    def rect_ref(row1, col1, row2, col2)
      RubyXL::Reference.new(row1, row2, col1, col2)
    end

    def resolve_sheet(name)
      return @workbook.worksheets.first if name.nil?
      find_sheet(name)
    end

    def find_sheet(name)
      @workbook.worksheets.find { |ws| ws.sheet_name.to_s.casecmp(name.to_s).zero? }
    end

    def each_cell(ws)
      data = ws.sheet_data
      return if data.nil?
      data.rows.each_with_index do |row, row_index|
        next if row.nil? || row.cells.nil?
        row.cells.each_with_index do |cell, col_index|
          yield(cell, row_index, col_index) unless cell.nil?
        end
      end
    end

    # === Planning (computes all rewrites without mutating anything) ===

    def build_plan
      plan = {
        :cell_expressions   => [], # [[cell, new_expression]]
        :formula_refs       => [], # [[RubyXL::Formula, RubyXL::Reference]]
        :defined_names      => [], # [[DefinedName, new_reference_string]]
        :validation_updates => [], # [[worksheet, DataValidation, sqref, f1, f2, delete]]
        :validation_adds    => [], # [[worksheet, DataValidation(template), [Reference]]]
        :merge_updates      => [], # [[worksheet, MergedCell, new_ref_or_nil]]
        :charts             => [], # [[ChartFile, new_data]]
      }

      plan_cell_formulas(plan)
      plan_defined_names(plan)
      plan_data_validations(plan)
      plan_merged_cells(plan)
      plan_charts(plan)
      plan
    end

    def plan_cell_formulas(plan)
      @workbook.worksheets.each do |ws|
        each_cell(ws) do |cell, row_index, col_index|
          formula = cell.formula
          next if formula.nil?
          location = "cell #{ws.sheet_name}!#{RubyXL::Reference.ind2ref(row_index, col_index)}"

          unless formula.expression.nil? then
            # A formula that moves to another sheet has to qualify its references
            # to unmoved cells with the source sheet name, so that they keep
            # pointing at the same cells (cut/paste semantics).
            moved_cell = ws.equal?(@src_sheet) &&
                         row_index.between?(@row1, @row2) && col_index.between?(@col1, @col2)
            emission_sheet = moved_cell ? @dst_sheet : ws
            new_expression = rewrite_expression(formula.expression, ws, emission_sheet, true, location)
            plan[:cell_expressions] << [cell, new_expression] if new_expression
          end

          # Range of a shared or array formula.
          if ws.equal?(@src_sheet) && (ref = formula.ref) then
            r1, r2 = ref.row_range.begin, ref.row_range.end
            c1, c2 = ref.col_range.begin, ref.col_range.end
            inter = intersect_source(r1, c1, r2, c2)
            next if inter.nil?
            if inter == [r1, c1, r2, c2] then
              plan[:formula_refs] << [formula, rect_ref(r1 + @drow, c1 + @dcol, r2 + @drow, c2 + @dcol)]
            else
              @errors << "#{location}: shared/array formula range #{ref} only partially overlaps" \
                           ' the moved range and cannot be split'
            end
          end
        end
      end
    end

    def plan_defined_names(plan)
      names = @workbook.defined_names
      return if names.nil?
      names.each do |defined_name|
        expression = defined_name.reference
        next if expression.nil?
        context = defined_name.local_sheet_id ? @workbook.worksheets[defined_name.local_sheet_id.to_i] : nil
        new_expression = rewrite_expression(expression, context, context, true, "defined name #{defined_name.name.inspect}")
        plan[:defined_names] << [defined_name, new_expression] if new_expression
      end
    end

    def plan_data_validations(plan)
      @workbook.worksheets.each do |ws|
        validations = ws.data_validations
        next if validations.nil?
        validations.each do |validation|
          location = "data validation #{validation.sqref} on sheet #{ws.sheet_name.inspect}"
          new_f1 = rewrite_optional_expression(validation.formula1, ws, location)
          new_f2 = rewrite_optional_expression(validation.formula2, ws, location)

          kept_refs = []
          moved_refs = []
          sqref_refs(validation).each do |ref|
            r1, r2 = ref.row_range.begin, ref.row_range.end
            c1, c2 = ref.col_range.begin, ref.col_range.end
            inter = ws.equal?(@src_sheet) ? intersect_source(r1, c1, r2, c2) : nil
            if inter.nil? then
              kept_refs << ref
            elsif inter == [r1, c1, r2, c2] then
              moved_refs << rect_ref(r1 + @drow, c1 + @dcol, r2 + @drow, c2 + @dcol)
            else
              subtract_rectangle(r1, c1, r2, c2, inter).each { |p| kept_refs << rect_ref(p[0], p[1], p[2], p[3]) }
              moved_refs << rect_ref(inter[0] + @drow, inter[1] + @dcol, inter[2] + @drow, inter[3] + @dcol)
            end
          end

          next if moved_refs.empty? && new_f1.nil? && new_f2.nil?

          if moved_refs.empty? || @dst_sheet.equal?(ws) then
            kept_refs.concat(moved_refs)
            plan[:validation_updates] << [ws, validation, build_sqref(kept_refs), new_f1, new_f2, false]
          else
            # The validated cells are moving to another sheet: the validation
            # (or the moved part of it) has to move along.
            plan[:validation_updates] << [ws, validation, build_sqref(kept_refs), new_f1, new_f2, kept_refs.empty?]
            plan[:validation_adds] << [@dst_sheet, validation, moved_refs]
          end
        end
      end
    end

    def plan_merged_cells(plan)
      [@src_sheet, @dst_sheet].uniq.each do |ws|
        merges = ws.merged_cells
        next if merges.nil?
        merges.each do |merge|
          ref = merge.ref
          r1, r2 = ref.row_range.begin, ref.row_range.end
          c1, c2 = ref.col_range.begin, ref.col_range.end
          inter = ws.equal?(@src_sheet) ? intersect_source(r1, c1, r2, c2) : nil
          if inter then
            if inter == [r1, c1, r2, c2] then
              plan[:merge_updates] << [ws, merge, rect_ref(r1 + @drow, c1 + @dcol, r2 + @drow, c2 + @dcol)]
            else
              @errors << "merged cell range #{ref} on sheet #{ws.sheet_name.inspect} only partially" \
                           ' overlaps the moved range and cannot be split'
            end
          elsif intersect_rectangles([r1, c1, r2, c2], dst_rect) then
            # Contents of the destination are replaced, so the merge is dropped.
            plan[:merge_updates] << [ws, merge, nil]
          end
        end
      end
    end

    def plan_charts(plan)
      each_chart_file do |chart|
        next if chart.data.nil?
        changed = false
        new_data = chart.data.gsub(%r{<c:f>([^<]*)</c:f>}m) { |match|
          rewritten = rewrite_expression(Regexp.last_match(1), nil, nil, false, "chart #{chart.xlsx_path}")
          if rewritten then
            changed = true
            "<c:f>#{rewritten}</c:f>"
          else
            match
          end
        }
        plan[:charts] << [chart, new_data] if changed
      end
    end

    def each_chart_file(&block)
      seen = {}
      walk = nil
      walk = lambda { |obj|
        storage = obj.respond_to?(:generic_storage) ? obj.generic_storage : nil
        next if storage.nil?
        storage.each { |child|
          next if child.nil? || seen[child.object_id]
          seen[child.object_id] = true
          if child.is_a?(RubyXL::ChartFile) then block.call(child)
          else walk.call(child) end
        }
      }
      walk.call(@workbook)
      @workbook.worksheets.each { |ws| walk.call(ws) }
    end

    # === Reference rewriting ===

    def rewrite_optional_expression(formula, context_sheet, location)
      return nil if formula.nil? || formula.expression.nil?
      rewrite_expression(formula.expression, context_sheet, context_sheet, false, location)
    end

    # Returns the rewritten expression, or nil if nothing changed.
    # Problems are accumulated in @errors.
    # +context_sheet+ is the sheet the expression currently lives on (used to
    # resolve unprefixed references); +emission_sheet+ is the sheet it will live
    # on after the move (used to decide whether a sheet prefix is needed).
    def rewrite_expression(expression, context_sheet, emission_sheet, allow_split, location)
      changed = false
      out = +''
      RubyXL::FormulaRewriter.tokenize(expression).each do |token|
        if token.unsupported? then
          @errors << "#{location}: unsupported reference #{token.text.inspect}" \
                       ' (external, 3-D and structured references are not supported by move_range)'
          out << token.text
        elsif token.reference? then
          new_text = remap_token(token, context_sheet, emission_sheet, allow_split, location)
          changed ||= (new_text != token.text)
          out << new_text
        else
          out << token.text
        end
      end
      changed ? out : nil
    end

    def remap_token(token, context_sheet, emission_sheet, allow_split, location)
      sheet = token.sheet_name ? find_sheet(token.sheet_name) : context_sheet
      return token.text if sheet.nil? || !sheet.equal?(@src_sheet)

      r1, c1, r2, c2 = token_bounds(token)
      inter = intersect_source(r1, c1, r2, c2)

      if inter.nil? then
        if emission_sheet.equal?(context_sheet) || token.sheet_name then
          return token.text
        else
          # The formula is moving to another sheet: an unprefixed reference to an
          # unmoved cell has to be qualified with the source sheet name.
          return emit_reference(token, emission_sheet, @src_sheet, r1, c1, r2, c2)
        end
      end

      if inter == [r1, c1, r2, c2] then
        emit_reference(token, emission_sheet, @dst_sheet,
                       r1 + @drow, c1 + @dcol, r2 + @drow, c2 + @dcol)
      elsif allow_split then
        moved = emit_reference(token, emission_sheet, @dst_sheet,
                               inter[0] + @drow, inter[1] + @dcol, inter[2] + @drow, inter[3] + @dcol)
        kept = subtract_rectangle(r1, c1, r2, c2, inter).collect { |p|
                 emit_reference(token, emission_sheet, @src_sheet, p[0], p[1], p[2], p[3])
               }
        (kept << moved).join(',')
      else
        @errors << "#{location}: reference #{token.text} only partially overlaps the moved range" \
                     ' and cannot be split here'
        token.text
      end
    end

    def token_bounds(token)
      case token.kind
      when :col_range then [0, token.first_col, MAX_ROW - 1, token.last_col]
      when :row_range then [token.first_row, 0, token.last_row, MAX_COL - 1]
      else [token.first_row, token.first_col, token.last_row, token.last_col]
      end
    end

    def emit_reference(token, context_sheet, target_sheet, r1, c1, r2, c2)
      prefix = sheet_prefix_for(target_sheet, context_sheet, token.sheet_prefix)
      body =
        case token.kind
        when :col_range then
          if r1 <= 0 && r2 >= MAX_ROW - 1 then
            "#{col_ref(c1, token.col_from_absolute)}:#{col_ref(c2, token.col_to_absolute)}"
          else
            bounded_ref(token, r1, c1, r2, c2)
          end
        when :row_range then
          if c1 <= 0 && c2 >= MAX_COL - 1 then
            "#{row_ref(r1, token.row_from_absolute)}:#{row_ref(r2, token.row_to_absolute)}"
          else
            bounded_ref(token, r1, c1, r2, c2)
          end
        else
          bounded_ref(token, r1, c1, r2, c2)
        end
      "#{prefix}#{body}"
    end

    def bounded_ref(token, r1, c1, r2, c2)
      from = RubyXL::Reference.ind2ref(r1, c1, token.row_from_absolute, token.col_from_absolute)
      return from if r1 == r2 && c1 == c2
      "#{from}:#{RubyXL::Reference.ind2ref(r2, c2, token.row_to_absolute, token.col_to_absolute)}"
    end

    def sheet_prefix_for(target_sheet, context_sheet, original_prefix)
      if target_sheet.equal?(context_sheet) then
        (original_prefix && target_sheet.equal?(@src_sheet)) ? original_prefix : ''
      else
        self.class.sheet_prefix(target_sheet.sheet_name)
      end
    end

    def col_ref(col, absolute)
      RubyXL::Reference.ind2ref(0, col, false, absolute).sub(/[0-9]+\z/, '')
    end

    def row_ref(row, absolute)
      "#{absolute ? '$' : ''}#{row + 1}"
    end

    # === Applying the plan ===

    def apply_plan(plan)
      plan[:cell_expressions].each { |cell, expression| cell.formula.expression = expression }
      plan[:formula_refs].each { |formula, ref| formula.ref = ref }
      plan[:defined_names].each { |defined_name, reference| defined_name.reference = reference }

      plan[:validation_updates].each do |ws, validation, sqref, f1, f2, delete|
        validation.sqref = sqref if sqref
        validation.formula1.expression = f1 if f1 && validation.formula1
        validation.formula2.expression = f2 if f2 && validation.formula2
        ws.data_validations.delete(validation) if delete
      end

      plan[:validation_adds].each do |ws, template, refs|
        ws.data_validations ||= RubyXL::DataValidations.new
        clone = template.dup
        clone.sqref = build_sqref(refs)
        ws.data_validations << clone
      end

      plan[:merge_updates].each do |ws, merge, new_ref|
        if new_ref then merge.ref = new_ref
        else ws.merged_cells.delete(merge) end
      end

      plan[:charts].each { |chart, data| chart.data = data }

      move_cells

      # Cached values of the rewritten formulas are now stale.
      @workbook.calc_pr ||= RubyXL::CalculationProperties.new
      @workbook.calc_pr.full_calc_on_load = true
      @workbook.calculation_chain = nil
    end

    def move_cells
      @src_sheet.sheet_data ||= RubyXL::SheetData.new
      @dst_sheet.sheet_data ||= RubyXL::SheetData.new
      src_data = @src_sheet.sheet_data
      dst_data = @dst_sheet.sheet_data

      (@row1..@row2).each do |row|
        src_row = src_data.rows[row]
        dst_row = dst_data.rows[row + @drow]
        next if src_row.nil? && dst_row.nil? # Nothing to move, nothing to clear.
        dst_row ||= @dst_sheet.add_row(row + @drow)
        dst_cells = (dst_row.cells ||= [])
        (@col1..@col2).each do |col|
          cell = src_row && src_row.cells ? src_row.cells[col] : nil
          dst_cells[col + @dcol] = cell
          src_row.cells[col] = nil if src_row && src_row.cells
          next if cell.nil?
          cell.r = RubyXL::Reference.new(row + @drow, col + @dcol)
          cell.worksheet = @dst_sheet
        end
      end
    end

    def sqref_refs(validation)
      sqref = validation.sqref
      case sqref
      when nil then []
      when RubyXL::Reference then [sqref]
      else sqref.to_a
      end
    end

    def build_sqref(refs)
      sqref = RubyXL::Sqref.new('')
      refs.each { |ref| sqref << ref }
      sqref
    end
  end

  module WorkbookMoveConvenienceMethods
    # Moves a rectangular range of cells to another location (cut/paste),
    # updating all references to the moved cells throughout the workbook.
    # See RubyXL::RangeMove for the exact semantics.
    #
    #   workbook.move_range('Sheet1!B2:D8', 'Sheet2!A1')
    def move_range(source, destination)
      RubyXL::RangeMove.new(self, source, destination).execute
    end
  end

  module WorksheetMoveConvenienceMethods
    # Moves a rectangular range of cells of this worksheet, updating all
    # references to the moved cells throughout the workbook.
    #
    #   worksheet.move_range('B2:D8', 'Sheet2!A1')
    def move_range(source, destination)
      workbook.move_range(qualify_move_reference(source), qualify_move_reference(destination))
    end

    private

    def qualify_move_reference(ref)
      return ref if ref.is_a?(RubyXL::Reference) && ref.sheet_name
      str = ref.to_s
      str.include?('!') ? str : "#{RubyXL::RangeMove.sheet_prefix(sheet_name)}#{str}"
    end
  end

  RubyXL::Workbook.send(:include, RubyXL::WorkbookMoveConvenienceMethods) # ruby 2.1 compat
  RubyXL::Worksheet.send(:include, RubyXL::WorksheetMoveConvenienceMethods) # ruby 2.1 compat
end
