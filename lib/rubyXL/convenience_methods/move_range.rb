require 'rubyXL/formula_rewriter'

module RubyXL
  # Raised when a rectangular move cannot be completed. The workbook is
  # guaranteed to be left unmodified when this error is raised.
  class MoveRangeError < StandardError; end

  module WorkbookMoveRange
    # Moves a rectangular block of cells to another location (Excel-style
    # cut/paste, as opposed to copy/paste) and updates every reference to the
    # moved cells throughout the workbook: cell formulas on all worksheets,
    # defined names, data validations (formulas and sqref) and chart series
    # formulas.
    #
    # Unlike copying, +$+ anchors do NOT prevent references to moved cells
    # from being updated: they follow the cells to the new location.
    #
    # Semantics:
    # * +source+ and +destination+ are A1-style references, optionally
    #   sheet-qualified (<tt>"Sheet1!B2:D8"</tt>, <tt>"'My Sheet'!E5"</tt>).
    #   +destination+ may be a single cell (its top-left corner) or a range
    #   of the same size as +source+. If the sheet is omitted, the source
    #   worksheet (for +destination+) or the first worksheet (for +source+)
    #   is assumed.
    # * If the source and destination rectangles intersect, ArgumentError
    #   is raised and nothing is changed.
    # * Cells in the destination rectangle are overwritten; the source
    #   rectangle is cleared. References to destination-area cells are NOT
    #   modified (matching Excel behavior).
    # * References pointing into the source range are repointed to the
    #   destination regardless of +$+ anchors. References from moved cells
    #   to cells outside the source range are left unchanged.
    # * Ranges that partially intersect the source range are split into a
    #   union of rectangles (+on_partial+ = :split, the default) or abort
    #   the move (+on_partial+ = :raise).
    # * Formulas containing external workbook references ([1]Sheet!A1),
    #   structured (table) references or 3D references cannot be rewritten;
    #   they are reported via MoveRangeError before anything is modified.
    # * The move is atomic: all formulas are validated before any
    #   modification takes place, so a failed move leaves the workbook
    #   unmodified and usable.
    #
    # Returns a RubyXL::Reference describing the destination rectangle.
    def move_range(source, destination, on_partial: :split)
      RubyXL::RangeMover.new(self, source, destination, on_partial: on_partial).execute
    end
  end

  module WorksheetMoveRange
    # Moves a rectangular block of cells, see Workbook#move_range.
    # +source_ref+ is interpreted on this worksheet; +destination_ref+ may
    # carry a sheet name for cross-sheet moves.
    def move_range(source_ref, destination_ref, on_partial: :split)
      validate_workbook
      qualified_source = "#{RubyXL::FormulaRewriter.quote_sheet_name(sheet_name)}!#{source_ref}"
      workbook.move_range(qualified_source, destination_ref.to_s, on_partial: on_partial)
    end
  end

  # Implements Workbook#move_range. See the documentation of that method
  # for the exact semantics.
  class RangeMover
    CHART_FORMULA_PATTERN = /(<(?:[A-Za-z][A-Za-z0-9]*:)?f>)(.*?)(<\/(?:[A-Za-z][A-Za-z0-9]*:)?f>)/m.freeze

    def initialize(workbook, source, destination, on_partial: :split)
      @workbook = workbook

      unless %i[split raise].include?(on_partial)
        raise ArgumentError, "on_partial must be :split or :raise, got #{on_partial.inspect}"
      end
      @on_partial = on_partial

      src_sheet_name, src_a1 = RubyXL::FormulaRewriter.split_sheet_reference(source.to_s)
      dst_sheet_name, dst_a1 = RubyXL::FormulaRewriter.split_sheet_reference(destination.to_s)

      src_ref = parse_bounded_ref(src_a1, 'source')
      dst_ref = parse_bounded_ref(dst_a1, 'destination')

      @src_sheet = find_sheet(src_sheet_name)
      @dst_sheet = dst_sheet_name.nil? ? @src_sheet : find_sheet(dst_sheet_name)

      @height = src_ref.row_range.size
      @width  = src_ref.col_range.size

      unless dst_ref.single_cell?
        unless dst_ref.row_range.size == @height && dst_ref.col_range.size == @width
          raise ArgumentError, "destination range #{dst_a1.inspect} does not match " \
                               "source size (#{@height} rows x #{@width} cols)"
        end
      end

      @dst_row = dst_ref.first_row
      @dst_col = dst_ref.first_col

      if @dst_row + @height - 1 >= RubyXL::Reference::ROW_MAX ||
           @dst_col + @width - 1 >= RubyXL::Reference::COL_MAX
        raise ArgumentError, "destination #{dst_a1.inspect} is out of worksheet bounds"
      end

      @src_rect = [src_ref.first_row, src_ref.first_col, src_ref.last_row, src_ref.last_col]
      @row_delta = @dst_row - @src_rect[0]
      @col_delta = @dst_col - @src_rect[1]

      if @src_sheet.equal?(@dst_sheet) && rect_intersection(@src_rect, dst_rect)
        raise ArgumentError, "source #{source.inspect} and destination #{destination.inspect} overlap"
      end
    end

    def execute
      problems = []
      process_workbook(problems) # Validation pass: collects problems, modifies nothing.

      unless problems.empty?
        message = (["cannot move #{describe}:"] + problems.uniq.map { |problem| "  * #{problem}" }).join("\n")
        raise RubyXL::MoveRangeError, message
      end

      process_workbook(nil) # Apply pass (nil = perform modifications).
      move_cells
      move_merged_cells
      invalidate_calculation

      RubyXL::Reference.new(@dst_row, @dst_row + @height - 1, @dst_col, @dst_col + @width - 1)
    end

    private

    def parse_bounded_ref(a1, role)
      ref = RubyXL::Reference.new(a1)
      unless ref.valid? && ref.row_range.end < RubyXL::Reference::ROW_MAX &&
               ref.col_range.end < RubyXL::Reference::COL_MAX
        raise ArgumentError, "#{role} must be a bounded rectangular range, got #{a1.inspect}"
      end
      ref
    end

    def find_sheet(name)
      return @workbook.worksheets.first if name.nil?

      sheet = @workbook.worksheets.find { |ws| ws.sheet_name == name } ||
              @workbook.worksheets.find { |ws| ws.sheet_name.to_s.casecmp(name.to_s).zero? }
      raise ArgumentError, "worksheet #{name.inspect} not found" if sheet.nil?
      sheet
    end

    def describe
      "#{@src_sheet.sheet_name}!#{reference_from_rect(@src_rect)}"
    end

    #
    # Reference rewriting
    #

    def process_workbook(problems)
      apply = problems.nil?

      @workbook.worksheets.each do |worksheet|
        worksheet.sheet_data.rows.each do |row|
          next if row.nil?
          row.cells.each do |cell|
            next if cell.nil? || cell.formula.nil?

            formula = cell.formula
            unless formula.expression.nil?
              rewritten = rewrite_expression(formula.expression, worksheet.sheet_name,
                                             "cell #{worksheet.sheet_name}!#{cell.r}", problems)
              formula.expression = rewritten if apply
            end

            # Shared/array formulas carry their own range; move it with the cell.
            if apply && !formula.ref.nil? && worksheet.equal?(@src_sheet) then
              rect = rect_of(formula.ref)
              formula.ref = reference_from_rect(translate_rect(rect)) if rect_contained?(rect, @src_rect)
            end
          end
        end

        process_data_validations(worksheet, problems, apply)
      end

      process_defined_names(problems, apply)
      process_charts(problems, apply)
    end

    def rewrite_expression(expression, host_sheet_name, context, problems)
      RubyXL::FormulaRewriter.rewrite(expression) do |token|
        if token.is_a?(RubyXL::FormulaRewriter::UnsupportedToken) then
          record_problem(problems, "#{context}: unsupported reference #{token.text.inspect} " \
                                   '(external, structured and 3D references cannot be rewritten)')
        else
          remap_token(token, host_sheet_name, context, problems)
        end
      end
    end

    def remap_token(token, host_sheet_name, context, problems)
      # Cannot determine the sheet (e.g. unqualified reference in a global
      # defined name or a chart) - leave such references untouched.
      effective_sheet = token.sheet_name || host_sheet_name
      return nil if effective_sheet.nil?
      return nil unless effective_sheet.casecmp(@src_sheet.sheet_name).zero?

      rect = normalize_rect([token.row1, token.col1,
                             token.range? ? token.row2 : token.row1,
                             token.range? ? token.col2 : token.col1])
      intersection = rect_intersection(rect, @src_rect)
      return nil if intersection.nil?

      if rect_contained?(rect, @src_rect) then
        build_token_reference(token, translate_rect(rect))
      elsif @on_partial == :raise then
        record_problem(problems, "#{context}: range #{token.matched_text.inspect} " \
                                 'partially overlaps the moved range')
        nil
      else
        ([translate_rect(intersection)] + rect_subtract(rect, intersection)).map { |part|
          build_token_reference(token, part)
        }.join(',')
      end
    end

    def build_token_reference(token, rect)
      single_cell = (rect[0] == rect[2]) && (rect[1] == rect[3])
      RubyXL::FormulaRewriter.build_reference(
        :sheet_name => @dst_sheet.sheet_name,
        :qualified  => token.qualified? || !@src_sheet.equal?(@dst_sheet),
        :row1 => rect[0], :col1 => rect[1],
        :row1_abs => token.row1_abs, :col1_abs => token.col1_abs,
        :row2 => single_cell ? nil : rect[2],
        :col2 => single_cell ? nil : rect[3],
        :row2_abs => token.row2_abs, :col2_abs => token.col2_abs
      )
    end

    def record_problem(problems, message)
      raise RubyXL::MoveRangeError, "cannot move #{describe}: #{message}" if problems.nil?
      problems << message
      nil
    end

    #
    # Data validations
    #

    def process_data_validations(worksheet, problems, apply)
      validations = worksheet.data_validations
      return if validations.nil?

      validations_to_move = []

      validations.each do |validation|
        [validation.formula1, validation.formula2].each do |formula|
          next if formula.nil? || formula.expression.nil?
          rewritten = rewrite_expression(formula.expression, worksheet.sheet_name,
                                         "data validation on #{worksheet.sheet_name}", problems)
          formula.expression = rewritten if apply
        end

        next if validation.sqref.nil? || !worksheet.equal?(@src_sheet)

        if @src_sheet.equal?(@dst_sheet) then
          new_refs = remap_reference_list(validation.sqref,
                                          "data validation sqref on #{worksheet.sheet_name}", problems)
          validation.sqref.replace(new_refs) if apply
        else
          process_cross_sheet_validation(validation, worksheet, problems, apply, validations_to_move)
        end
      end

      return unless apply && !validations_to_move.empty?

      validations_to_move.each { |validation| validations.delete(validation) }
      @dst_sheet.data_validations ||= RubyXL::DataValidations.new
      @dst_sheet.data_validations.concat(validations_to_move)
    end

    def process_cross_sheet_validation(validation, worksheet, problems, apply, validations_to_move)
      moved_refs = []
      remainder_refs = []

      validation.sqref.each do |ref|
        rect = rect_of(ref)
        intersection = rect_intersection(rect, @src_rect)

        if intersection.nil? then
          remainder_refs << ref
        elsif rect_contained?(rect, @src_rect) then
          moved_refs << reference_from_rect(translate_rect(rect))
        elsif @on_partial == :split then
          moved_refs << reference_from_rect(translate_rect(intersection))
          rect_subtract(rect, intersection).each { |part| remainder_refs << reference_from_rect(part) }
        else
          record_problem(problems, "data validation sqref on #{worksheet.sheet_name}: " \
                                   "range #{ref} partially overlaps the moved range")
          remainder_refs << ref
        end
      end

      return if moved_refs.empty?

      if remainder_refs.empty? then
        if apply then
          validation.sqref.replace(moved_refs)
          validations_to_move << validation
        end
      else
        record_problem(problems, "data validation sqref on #{worksheet.sheet_name} " \
                                 'cannot be split across worksheets')
      end
    end

    def remap_reference_list(refs, context, problems)
      new_refs = []

      refs.each do |ref|
        rect = rect_of(ref)
        intersection = rect_intersection(rect, @src_rect)

        if intersection.nil? then
          new_refs << ref
        elsif rect_contained?(rect, @src_rect) then
          new_refs << reference_from_rect(translate_rect(rect))
        elsif @on_partial == :split then
          new_refs << reference_from_rect(translate_rect(intersection))
          rect_subtract(rect, intersection).each { |part| new_refs << reference_from_rect(part) }
        else
          record_problem(problems, "#{context}: range #{ref} partially overlaps the moved range")
          new_refs << ref
        end
      end

      new_refs
    end

    #
    # Defined names
    #

    def process_defined_names(problems, apply)
      defined_names = @workbook.defined_names
      return if defined_names.nil?

      defined_names.each do |defined_name|
        next if defined_name.reference.nil?

        host_sheet_name = nil
        if defined_name.local_sheet_id then
          local_sheet = @workbook.worksheets[defined_name.local_sheet_id.to_i]
          host_sheet_name = local_sheet && local_sheet.sheet_name
        end

        rewritten = rewrite_expression(defined_name.reference, host_sheet_name,
                                       "defined name #{defined_name.name.inspect}", problems)
        defined_name.reference = rewritten if apply
      end
    end

    #
    # Charts
    #

    def process_charts(problems, apply)
      each_chart_file do |chart_file|
        next if chart_file.data.nil?
        rewritten = chart_file.data.gsub(CHART_FORMULA_PATTERN) do
          open_tag, expression, close_tag = $1, $2, $3
          open_tag + rewrite_expression(expression, nil, 'chart series formula', problems) + close_tag
        end
        chart_file.data = rewritten if apply
      end
    end

    def each_chart_file
      seen = {}
      stack = []
      stack.concat(@workbook.generic_storage) if @workbook.generic_storage
      @workbook.worksheets.each { |ws| stack.concat(ws.generic_storage) if ws.generic_storage }

      until stack.empty?
        obj = stack.pop
        next if obj.nil? || seen[obj.object_id]
        seen[obj.object_id] = true

        if obj.is_a?(RubyXL::ChartFile) then
          yield obj
        elsif obj.respond_to?(:generic_storage) && obj.generic_storage then
          stack.concat(obj.generic_storage)
        end
      end
    end

    #
    # Cell movement
    #

    def move_cells
      moved_cells = []

      (@src_rect[0]..@src_rect[2]).each do |row_index|
        row = @src_sheet.sheet_data.rows[row_index]
        moved_row = []
        (@src_rect[1]..@src_rect[3]).each do |col_index|
          moved_row << (row && row.cells[col_index])
          row.cells[col_index] = nil if row
        end
        moved_cells << moved_row
      end

      moved_cells.each_with_index do |moved_row, row_offset|
        dst_row_index = @dst_row + row_offset
        dst_row = @dst_sheet.sheet_data.rows[dst_row_index] || @dst_sheet.add_row(dst_row_index)

        moved_row.each_with_index do |cell, col_offset|
          next if cell.nil?
          cell.worksheet = @dst_sheet
          cell.row = dst_row_index
          cell.column = @dst_col + col_offset
          dst_row.cells[@dst_col + col_offset] = cell
        end
      end
    end

    def move_merged_cells
      merged_cells = @src_sheet.merged_cells
      return if merged_cells.nil?

      merged_cells.each do |merged_cell|
        rect = rect_of(merged_cell.ref)
        next unless rect_contained?(rect, @src_rect)
        merged_cell.ref = reference_from_rect(translate_rect(rect))
      end
    end

    # Moved formulas keep stale cached values and the calculation chain
    # points at old addresses; drop the chain and ask Excel to recalculate.
    def invalidate_calculation
      @workbook.calculation_chain = nil
      if @workbook.calc_pr.nil? then
        @workbook.calc_pr = RubyXL::CalculationProperties.new(:full_calc_on_load => true)
      else
        @workbook.calc_pr.full_calc_on_load = true
      end
    end

    #
    # Rectangle geometry (rects are [first_row, first_col, last_row, last_col], inclusive)
    #

    def rect_of(ref)
      normalize_rect([ref.first_row, ref.first_col, ref.last_row, ref.last_col])
    end

    def reference_from_rect(rect)
      RubyXL::Reference.new(rect[0], rect[2], rect[1], rect[3])
    end

    def normalize_rect(rect)
      [[rect[0], rect[2]].min, [rect[1], rect[3]].min,
       [rect[0], rect[2]].max, [rect[1], rect[3]].max]
    end

    def rect_intersection(a, b)
      first_row = [a[0], b[0]].max
      first_col = [a[1], b[1]].max
      last_row  = [a[2], b[2]].min
      last_col  = [a[3], b[3]].min
      (first_row <= last_row && first_col <= last_col) ? [first_row, first_col, last_row, last_col] : nil
    end

    def rect_contained?(inner, outer)
      outer[0] <= inner[0] && inner[2] <= outer[2] &&
        outer[1] <= inner[1] && inner[3] <= outer[3]
    end

    def rect_subtract(rect, hole)
      parts = []
      parts << [rect[0], rect[1], hole[0] - 1, rect[3]] if hole[0] > rect[0]
      parts << [hole[2] + 1, rect[1], rect[2], rect[3]] if hole[2] < rect[2]
      parts << [hole[0], rect[1], hole[2], hole[1] - 1] if hole[1] > rect[1]
      parts << [hole[0], hole[3] + 1, hole[2], rect[3]] if hole[3] < rect[3]
      parts
    end

    def translate_rect(rect)
      [rect[0] + @row_delta, rect[1] + @col_delta,
       rect[2] + @row_delta, rect[3] + @col_delta]
    end

    def dst_rect
      [@dst_row, @dst_col, @dst_row + @height - 1, @dst_col + @width - 1]
    end
  end

  RubyXL::Workbook.send(:include, RubyXL::WorkbookMoveRange)
  RubyXL::Worksheet.send(:include, RubyXL::WorksheetMoveRange)
end
