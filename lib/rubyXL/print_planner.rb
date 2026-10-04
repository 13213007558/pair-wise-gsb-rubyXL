# frozen_string_literal: true

require 'rubyXL/objects/reference'
require 'rubyXL/objects/column_range'
require 'rubyXL/objects/font'
require 'rubyXL/objects/sheet_data'

module RubyXL
  # Geometric-only print pagination planner.
  #
  # The planner uses stored row heights and column widths plus paper and margin
  # dimensions. It does not render fonts or launch Excel/browser.
  #
  # In fit mode, manual row/column breaks remain hard boundaries. Each band is
  # independently fit to the requested fitToHeight/fitToWidth target; the
  # largest common integer percentage is returned. When the resulting bands
  # exceed the fit target, pages are still returned and a conflict reason is
  # recorded. Scale search tests integer percentages from 100 down to 10 using
  # upper-midpoint binary search, so the accepted percentages are a monotone
  # prefix and the returned value can be rechecked directly.
  class PrintPlanner
    Page = Struct.new(:number, :print_area_index, :body_ranges, :title_row_ranges,
                      :title_column_ranges, :row_offset, :column_offset,
                      :scaled_row_offset, :scaled_column_offset,
                      :body_top, :body_left, :page_row, :page_column, :scale,
                      keyword_init: true)

    Result = Struct.new(:pages, :scale, :mode, :printable_width, :printable_height,
                        :conflicts, :warnings, keyword_init: true)

    CellRange = Struct.new(:sheet_name, :first_row, :last_row, :first_column, :last_column,
                           keyword_init: true) do
      def to_s
        first = RubyXL::Reference.ind2ref(first_row, first_column)
        return first if first_row == last_row && first_column == last_column
        "#{first}:#{RubyXL::Reference.ind2ref(last_row, last_column)}"
      end
    end
    AxisRange = Struct.new(:first, :last, keyword_init: true)
    Segment = Struct.new(:indices, :ranges, :size, :offset, :source_offset,
                         :segment_index, :manual, keyword_init: true)
    Group = Struct.new(:segments, :size, :offset, :source_offset, :indices, :ranges, :band,
                       :band_segments, keyword_init: true)
    AreaPlan = Struct.new(:reference, :row_segments, :column_segments,
                          :body_rows, :body_columns, keyword_init: true)

    DEFAULT_MARGINS = {
      :left => 0.7, :right => 0.7, :top => 0.75, :bottom => 0.75,
      :header => 0.3, :footer => 0.3
    }.freeze

    PAPER_SIZES = {
      1 => [8.5, 11.0], # Letter
      5 => [8.5, 14.0], # Legal
      8 => [11.0, 17.0], # Tabloid
      9 => [Rational(1050, 127), Rational(1485, 127)], # A4
      11 => [Rational(1485, 127), Rational(2100, 127)], # A3
      12 => [Rational(1050, 127), Rational(1485, 127)], # A4 small
      13 => [Rational(740, 127), Rational(1050, 127)], # A5
      70 => [Rational(1250, 127), Rational(1765, 127)] # B5
    }.freeze

    MIN_SCALE = 10
    MAX_FIXED_SCALE = 400
    POINTS_PER_INCH = 72
    MAX_COLUMN_INDEX = 16_383
    MAX_ROW_INDEX = 1_048_575

    attr_reader :worksheet, :options, :conflicts, :warnings

    def self.plan(worksheet, options = {})
      new(worksheet, options).plan
    end

    def initialize(worksheet, options = {})
      @worksheet = worksheet
      @options = options
      @conflicts = []
      @warnings = []
    end

    def plan
      setup
      area_plans = build_area_plans

      if mode == :fit
        @scale = maximum_fit_scale(area_plans)
        unless scale
          return result([], area_plans)
        end
      else
        @scale = Rational(explicit_scale, 100)
      end

      pages = paginate_areas(area_plans, scale)
      result(pages, area_plans)
    end

    private

    attr_reader :mode, :fit_to_width, :fit_to_height, :scale
    attr_reader :printable_width, :printable_height
    attr_reader :print_area_refs, :title_rows, :title_columns

    def setup
      @mode = detect_mode
      @fit_to_width = options[:fit_to_width]
      @fit_to_height = options[:fit_to_height]
      setup_page
      setup_areas_and_titles
    end

    def detect_mode
      return options[:mode].to_sym if options.key?(:mode)
      return :scale if options.key?(:scale)
      return :fit if options.key?(:fit_to_width) || options.key?(:fit_to_height)
      if worksheet.sheet_pr&.page_setup_pr&.fit_to_page
        :fit
      else
        :scale
      end
    rescue NoMethodError
      :scale
    end

    def setup_page
      page_setup = worksheet.page_setup

      width, height = page_dimensions
      orientation = options.fetch(:orientation, page_setup&.orientation || 'default')
      width, height = height, width if orientation == 'landscape'

      margins = page_margins
      @printable_width = Rational(width) - (margins[:left] + margins[:right])
      @printable_height = Rational(height) - (margins[:top] + margins[:bottom])

      validate_page_capacity!

      if mode == :fit
        @fit_to_width = positive_option(:fit_to_width, page_setup&.fit_to_width || 1)
        @fit_to_height = positive_option(:fit_to_height, page_setup&.fit_to_height || 1)
      else
        @explicit_scale = positive_option(:scale, page_setup&.scale || 100)
        unless (MIN_SCALE..MAX_FIXED_SCALE).include?(explicit_scale)
          raise ArgumentError, "scale must be between #{MIN_SCALE} and #{MAX_FIXED_SCALE}"
        end
      end
    end

    def page_dimensions
      if options[:page_width] && options[:page_height]
        return [options[:page_width], options[:page_height]].map { |value| Rational(value) }
      end

      paper_size = options.fetch(:paper_size, worksheet.page_setup&.paper_size || 1)
      dimensions = PAPER_SIZES[paper_size]
      raise ArgumentError, "unsupported paper size: #{paper_size}" unless dimensions

      dimensions.map { |v| Rational(v) * POINTS_PER_INCH }
    end

    def page_margins
      source = options[:page_margins] || worksheet.page_margins || {}
      DEFAULT_MARGINS.each_with_object({}) do |(key, default), margins|
        value = options[key]
        value ||= source.public_send(key) if source.respond_to?(key)
        margins[key] = Rational(value || default) * POINTS_PER_INCH
      end
    end

    def validate_page_capacity!
      if printable_width <= 0 || printable_height <= 0
        raise ArgumentError, 'printable page area must be positive'
      end
    end

    def positive_option(key, default)
      value = options.key?(key) ? options[key] : default
      value = value.to_i
      raise ArgumentError, "#{key} must be non-negative" if value.negative?
      value
    end

    def explicit_scale
      @explicit_scale
    end

    def setup_areas_and_titles
      @print_area_refs = parse_refs(options.fetch(:print_area) { auto_print_area })
      @print_area_refs = @print_area_refs.map { |reference| clamp_unbounded_reference(reference) }
      @print_area_refs = @print_area_refs.select { |ref| within_sheet?(ref) }
      raise ArgumentError, 'print area must contain at least one range' if print_area_refs.empty?

      title_input = options.fetch(:repeat_rows) { auto_print_titles(:rows) }
      column_title_input = options.fetch(:repeat_columns) { auto_print_titles(:columns) }
      validate_title_input(title_input, true)
      validate_title_input(column_title_input, false)
      @title_rows = clamp_title_intervals(expand_title_input(filter_sheet_refs(title_input), true), true)
      @title_columns = clamp_title_intervals(expand_title_input(filter_sheet_refs(column_title_input), false), false)
    end

    def validate_title_input(input, rows)
      return if input.nil?
      return if input.is_a?(Array) && input.all? { |item| item.is_a?(Integer) }

      parse_refs(input).each do |reference|
        next unless within_sheet?(reference)
        if rows
          unless reference.first_column.zero? && reference.last_column == MAX_COLUMN_INDEX
            raise ArgumentError, 'repeat_rows requires full-row references, for example "$1:$2"'
          end
        else
          unless reference.first_row.zero? && reference.last_row == MAX_ROW_INDEX
            raise ArgumentError, 'repeat_columns requires full-column references, for example "$A:$B"'
          end
        end
      end
    end

    def filter_sheet_refs(input)
      return nil if input.nil?
      references = parse_refs(input)
      return input if references.size == input.length && input.all? { |item| item.is_a?(Integer) }
      references.select { |reference| within_sheet?(reference) }.map(&:to_s)
    end

    def clamp_title_intervals(intervals, rows)
      maximum = rows ? print_area_refs.map(&:last_row).max : print_area_refs.map(&:last_column).max
      intervals.map do |interval|
        next interval if interval.last <= maximum
        next nil if interval.first > maximum
        interval.first..maximum
      end.compact
    end

    def auto_print_area
      defined_name_value('_xlnm.Print_Area') || used_area_reference
    end

    def auto_print_titles(kind)
      value = defined_name_value('_xlnm.Print_Titles')
      return nil unless value

      value.split(',').select do |part|
        part =~ /\A\s*(?:[^!]+!)?\s*\$?\d+\s*:\s*\$?\d+\s*\z/ ? kind == :rows : kind == :columns
      end.join(',')
    end

    def defined_name_value(name)
      names = worksheet.workbook&.defined_names
      local_index = worksheet.workbook&.worksheets&.index(worksheet).to_s
      match = names&.find do |defined_name|
        defined_name.name == name &&
          (defined_name.local_sheet_id.nil? || defined_name.local_sheet_id == local_index)
      end
      match&.reference
    end

    def used_area_reference
      last_row = -1
      last_column = -1

      worksheet.sheet_data&.rows&.each_with_index do |row, row_index|
        next unless row
        last_row = row_index
        row.cells.each_with_index do |cell, column_index|
          last_column = column_index if cell
        end
      end

      return 'A1' if last_row.negative?
      last_column = 0 if last_column.negative?
      RubyXL::Reference.new(0, last_row, 0, last_column).to_s
    end

    def parse_refs(input)
      return [] if input.nil?
      input = input.reference if input.respond_to?(:reference)
      input = [input] unless input.is_a?(Array)
      input.flat_map { |item| split_reference_text(item) }.map { |text| parse_cell_range(text) }
    end

    def split_reference_text(value)
      text = value.to_s.strip
      return [] if text.empty?

      ranges = []
      buffer = +''
      quoted = false
      index = 0
      while index < text.length
        char = text[index]
        quoted = !quoted if char == "'"
        if char == ',' && !quoted
          ranges << buffer.strip
          buffer = +''
        else
          buffer << char
        end
        index += 1
      end
      ranges << buffer.strip
      ranges.reject(&:empty?)
    end

    def parse_cell_range(text)
      match = text.match(/\A(?:(?:'(?<quoted>[^']+)'|(?<sheet>[^!]+))!)?(?<range>.+)\z/m)
      raise ArgumentError, "invalid reference: #{text}" unless match

      range_text = match[:range].delete('$').tr(' ', '')
      from_text, to_text = range_text.split(':')
      first_row, last_row = row_endpoint(from_text, to_text)
      first_column, last_column = column_endpoint(from_text, to_text)
      if last_row < first_row || last_column < first_column
        raise ArgumentError, "invalid reference: #{text}"
      end

      CellRange.new(
        :sheet_name => match[:quoted] || match[:sheet],
        :first_row => first_row,
        :last_row => last_row,
        :first_column => first_column,
        :last_column => last_column
      )
    end

    def row_endpoint(from_text, to_text)
      if from_text =~ /\A[A-Z]+\d+\z/
        [from_text[/\d+\z/].to_i - 1, (to_text || from_text)[/\d+\z/].to_i - 1]
      elsif from_text =~ /\A\d+\z/
        [from_text.to_i - 1, (to_text || from_text).to_i - 1]
      else
        [0, MAX_ROW_INDEX]
      end
    end

    def column_endpoint(from_text, to_text)
      if from_text =~ /\A[A-Z]+\d+\z/
        [column_index(from_text[/\A[A-Z]+/]), column_index((to_text || from_text)[/\A[A-Z]+/])]
      elsif from_text =~ /\A[A-Z]+\z/
        [column_index(from_text), column_index(to_text || from_text)]
      else
        [0, MAX_COLUMN_INDEX]
      end
    end

    def column_index(text)
      text.each_byte.inject(0) { |value, byte| (value * 26) + (byte - 64) } - 1
    end

    def within_sheet?(range)
      range.sheet_name.nil? || range.sheet_name == worksheet.sheet_name
    end

    def clamp_unbounded_reference(reference)
      bounds = used_bounds
      CellRange.new(
        :sheet_name => reference.sheet_name,
        :first_row => reference.first_row,
        :last_row => reference.last_row == MAX_ROW_INDEX ? bounds[:last_row] : reference.last_row,
        :first_column => reference.first_column,
        :last_column => reference.last_column == MAX_COLUMN_INDEX ? bounds[:last_column] : reference.last_column
      )
    end

    def used_bounds
      @used_bounds ||= begin
        last_row = -1
        last_column = -1
        worksheet.sheet_data&.rows&.each_with_index do |row, row_index|
          next unless row
          last_row = row_index
          row.cells.each_with_index do |cell, column_index|
            last_column = column_index if cell
          end
        end
        { :last_row => [last_row, 0].max, :last_column => [last_column, 0].max }
      end
    end

    def expand_title_input(input, rows)
      input = integer_intervals(input, rows) if input.is_a?(Array) && input.all? { |item| item.is_a?(Integer) }
      refs = parse_refs(input)
      intervals = refs.map do |reference|
        rows ? [reference.first_row, reference.last_row] : [reference.first_column, reference.last_column]
      end.sort.uniq
      merge_intervals(intervals)
    end

    def integer_intervals(values, rows)
      values.map { |value| rows ? "#{value + 1}:#{value + 1}" : "#{column_letter(value)}:#{column_letter(value)}" }
    end

    def column_letter(index)
      RubyXL::Reference.ind2ref(0, index).sub(/\d+\z/, '')
    end

    def merge_intervals(intervals)
      intervals.each_with_object([]) do |interval, merged|
        if merged.empty? || interval.first > merged.last.last + 1
          merged << (interval.first..interval.last)
        else
          merged[-1] = (merged.last.first..[merged.last.last, interval.last].max)
        end
      end
    end

    def build_area_plans
      print_area_refs.map do |reference|
        build_area_plan(reference)
      end
    end

    def build_area_plan(reference)
      body_rows = visible_indices(reference.first_row..reference.last_row, row_dimensions, true, title_rows)
      body_columns = visible_indices(reference.first_column..reference.last_column,
                                     column_dimensions, false, title_columns)

      row_breaks = manual_breaks(options[:row_breaks] || worksheet.row_breaks)
      column_breaks = manual_breaks(options[:column_breaks] || worksheet.col_breaks)
      row_pivots = map_breaks(row_breaks, reference, body_rows, true)
      column_pivots = map_breaks(column_breaks, reference, body_columns, false)

      AreaPlan.new(
        :reference => reference,
        :body_rows => body_rows,
        :body_columns => body_columns,
        :row_segments => build_segments(body_rows, row_pivots, row_dimensions, true),
        :column_segments => build_segments(body_columns, column_pivots, column_dimensions, false)
      )
    end

    def visible_indices(interval, dimensions, rows, titles)
      title_intervals = titles
      interval.select do |index|
        !hidden?(index, dimensions, rows) && !title_intervals.any? { |title| title.cover?(index) }
      end
    end

    def manual_breaks(source)
      return source.to_a if source.is_a?(Array) && !source.first.respond_to?(:man)
      return [] unless source
      source.select { |break_node| break_node.man }.map { |break_node| break_node.id.to_i }
    end

    def map_breaks(breaks, reference, body_indices, rows)
      start = rows ? reference.first_row : reference.first_column
      finish = rows ? reference.last_row : reference.last_column
      title_intervals = rows ? title_rows : title_columns
      pivots = []

      breaks.sort.uniq.each do |break_id|
        next unless break_id > start && break_id <= finish

        pivot = body_indices.index { |index| index >= break_id }
        if pivot
          if title_intervals.any? { |title| title.cover?(break_id) }
            add_warning(:manual_break_in_repeated_titles, break_id)
            next
          elsif pivots.include?(pivot)
            add_warning(:duplicate_manual_break, break_id)
          else
            pivots << pivot
          end
        else
          add_warning(:manual_break_without_body, break_id)
        end
      end

      pivots.sort
    end

    def build_segments(indices, pivots, dimensions, rows)
      positions = segment_positions(indices, pivots)
      running = Rational(0)
      positions.each_with_index.map do |segment_indices, segment_index|
        ranges = contiguous_ranges(segment_indices, rows)
        manual = pivots.include?(indices.index(segment_indices.first))
        size = segment_indices.sum { |index| Rational(dimension(index, dimensions, rows)) }
        segment = Segment.new(
          :indices => segment_indices,
          :ranges => ranges,
          :size => size,
          :offset => running,
          :source_offset => running,
          :segment_index => segment_index,
          :manual => manual
        )
        running += size
        segment
      end
    end

    def segment_positions(indices, pivots)
      return [] if indices.empty?
      segments = [[]]
      indices.each_with_index do |index, position|
        boundary = position.positive? && segments.last.any? &&
                   pivots.include?(position)
        segments << [] if boundary
        segments.last << index
      end
      segments.reject(&:empty?)
    end

    def contiguous_ranges(indices, rows)
      ranges = []
      indices.each do |index|
        if ranges.empty? || index > ranges.last.last + 1
          ranges << (index..index)
        else
          ranges[-1] = (ranges.last.first..index)
        end
      end
      ranges.map { |interval| AxisRange.new(:first => interval.first, :last => interval.last) }
    end

    def row_dimensions
      @row_dimensions ||= begin
        explicit = options[:row_heights] || {}
        0.upto(max_used_index(true)).map do |index|
          value = if explicit.is_a?(Array)
                    explicit[index]
                  elsif explicit.is_a?(Hash)
                    explicit[index] || explicit[index.to_s]
                  end
          value = worksheet[index]&.ht if value.nil?
          Rational(value || worksheet.sheet_format_pr&.default_row_height || RubyXL::Row::DEFAULT_HEIGHT)
        end
      end
    end

    def column_dimensions
      @column_dimensions ||= begin
        explicit = options[:column_widths] || {}
        0.upto(max_used_index(false)).map do |index|
          value = if explicit.is_a?(Array)
                    explicit[index]
                  elsif explicit.is_a?(Hash)
                    explicit[index] || explicit[index.to_s]
                  end
          value = value.nil? ? column_width_in_points(index) : Rational(value)
          Rational(value)
        end
      end
    end

    def max_used_index(rows)
      references = print_area_refs
      if rows
        [references.map(&:last_row).max, title_rows.map(&:last).max || 0].max
      else
        [references.map(&:last_column).max, title_columns.map(&:last).max || 0].max
      end
    end

    def column_width_in_points(index)
      range = worksheet.cols&.locate_range(index)
      raw = range&.width
      raw ||= RubyXL::ColumnRange.chars2raw(worksheet.sheet_format_pr&.default_col_width ||
                                              RubyXL::ColumnRange::DEFAULT_WIDTH)
      pixels = Rational((raw * RubyXL::Font::MAX_DIGIT_WIDTH).round)
      pixels * Rational(POINTS_PER_INCH, 96)
    end

    def dimension(index, dimensions, rows)
      return dimensions[index] if dimensions[index]
      return RubyXL::Row::DEFAULT_HEIGHT if rows
      column_width_in_points(index)
    end

    def hidden?(index, _dimensions, rows)
      option = rows ? :hidden_rows : :hidden_columns
      explicit = options[option]
      return explicit.include?(index) if explicit.is_a?(Array)
      return explicit[index] || explicit[index.to_s] if explicit.is_a?(Hash)
      if rows
        worksheet[index]&.hidden
      else
        worksheet.cols&.locate_range(index)&.hidden
      end
    end

    def title_height
      visible_title_size(title_rows, row_dimensions, true)
    end

    def title_width
      visible_title_size(title_columns, column_dimensions, false)
    end

    def visible_title_size(intervals, dimensions, rows)
      intervals.sum do |interval|
        interval.select { |index| !hidden?(index, dimensions, rows) }
                .sum { |index| Rational(dimension(index, dimensions, rows)) }
      end
    end

    def maximum_fit_scale(area_plans)
      if title_height * Rational(MIN_SCALE, 100) >= printable_height ||
         title_width * Rational(MIN_SCALE, 100) >= printable_width
        add_conflict(:repeated_titles_do_not_fit)
        return nil
      end

      low = MIN_SCALE
      high = 100
      unless fit?(area_plans, low)
        pack_areas(area_plans, Rational(low, 100), false)
        return nil
      end
      while low < high
        middle = (low + high + 1) / 2
        if fit?(area_plans, middle)
          low = middle
        else
          high = middle - 1
        end
      end
      Rational(low, 100)
    end

    def fit?(area_plans, scale_percent)
      attempt = pack_areas(area_plans, Rational(scale_percent, 100), :skip_conflicts)
      attempt[:fit]
    end

    def pack_areas(area_plans, candidate_scale, overflow_mode)
      body_width = (printable_width / candidate_scale) - title_width
      body_height = (printable_height / candidate_scale) - title_height
      fit = body_width.positive? && body_height.positive?
      row_limit = fit_to_height || 0
      column_limit = fit_to_width || 0

      packed = area_plans.map do |area|
        row_groups = pack_segments(area.row_segments, body_height, row_limit, true, overflow_mode)
        column_groups = pack_segments(area.column_segments, body_width, column_limit, false, overflow_mode)
        fit &&= row_groups[:fit] && column_groups[:fit]
        { :area => area, :rows => row_groups, :columns => column_groups }
      end

      { :fit => fit, :packed => packed, :body_width => body_width, :body_height => body_height }
    end

    def pack_segments(segments, capacity, limit, rows, overflow_mode)
      groups = []
      fit = true
      band_index = 0

      segments.each_with_index do |segment, segment_index|
        band_index += 1 if segment.manual
        source_offset = segment.offset
        segment.indices.each do |index|
          size = Rational(rows ? row_dimensions[index] : column_dimensions[index])
          if size > capacity
            if overflow_mode == false
              add_conflict(:content_does_not_fit_at_minimum_scale)
            elsif overflow_mode == :fixed
              add_conflict(:fixed_scale_content_overflow)
            end
            fit = false
          end

          start_group = groups.empty? || segment.manual || groups.last.size + size > capacity
          if start_group
            groups << Group.new(:segments => [], :size => Rational(0), :offset => Rational(0),
                                :source_offset => source_offset, :indices => [], :band => band_index,
                                :band_segments => [], :ranges => [])
          end

          group = groups.last
          group.segments << { :index => index, :segment_index => segment_index, :size => size }
          group.band_segments << segment_index
          group.size += size
          group.indices << index
        end
      end

      groups = [empty_group] if groups.empty?
      manual_segments = segments.count(&:manual)
      group_counts_by_band = groups.reject { |group| group.indices.empty? }.group_by(&:band).values.map(&:size)
      largest_group_count = group_counts_by_band.max || 0
      if limit.positive? && (manual_segments + 1) > limit
        add_conflict(rows ? :manual_breaks_exceed_fit_to_height : :manual_breaks_exceed_fit_to_width)
      end
      if limit.positive? && largest_group_count > limit
        add_conflict(rows ? :fit_to_height_impossible : :fit_to_width_impossible) if overflow_mode == false
        fit = false
      end

      assign_group_offsets(groups)
      { :groups => groups, :fit => fit }
    end

    def empty_group
      Group.new(:segments => [], :size => Rational(0), :offset => Rational(0),
                :source_offset => Rational(0), :indices => [], :band => 0, :band_segments => [],
                :ranges => [])
    end

    def assign_group_offsets(groups)
      running = Rational(0)
      groups.each do |group|
        group.offset = running
        group.ranges = group.indices.slice_when { |previous, current| current != previous + 1 }
                            .map { |values| AxisRange.new(:first => values.first, :last => values.last) }
        group.source_offset = running
        running += group.size
      end
      groups
    end

    def paginate_areas(area_plans, candidate_scale)
      overflow_mode = mode == :fit ? :fit : :fixed
      packed = pack_areas(area_plans, candidate_scale, overflow_mode)[:packed]
      area_pages = packed.each_with_index.flat_map do |item, area_index|
        paginate_area(item, area_index, candidate_scale)
      end
      order_pages(area_pages)
    end

    def paginate_area(item, area_index, candidate_scale)
      row_groups = item[:rows][:groups]
      column_groups = item[:columns][:groups]
      pages = []

      row_groups.each_with_index do |row_group, row_page|
        column_groups.each_with_index do |column_group, column_page|
          next if row_group.indices.empty? || column_group.indices.empty?
          body_ranges = combine_ranges(row_group.ranges, column_group.ranges)
          pages << Page.new(
            :print_area_index => area_index,
            :body_ranges => body_ranges,
            :title_row_ranges => title_ranges_for(row_group, column_group),
            :title_column_ranges => title_columns_for(row_group, column_group),
            :row_offset => row_group.source_offset,
            :column_offset => column_group.source_offset,
            :scaled_row_offset => row_group.source_offset * candidate_scale,
            :scaled_column_offset => column_group.source_offset * candidate_scale,
            :body_top => title_height * candidate_scale,
            :body_left => title_width * candidate_scale,
            :page_row => row_page,
            :page_column => column_page,
            :scale => (candidate_scale * 100).to_i
          )
        end
      end
      pages
    end

    def combine_ranges(row_ranges, column_ranges)
      row_ranges.product(column_ranges).map do |row_range, column_range|
        CellRange.new(:first_column => column_range.first, :last_column => column_range.last,
                      :first_row => row_range.first, :last_row => row_range.last)
      end
    end

    def title_ranges_for(row_group, column_group)
      page_columns = visible_title_intervals(title_columns, false) + column_group.ranges
      visible_title_intervals(title_rows, true).product(merge_axis_ranges(page_columns)).map do |interval, columns|
        CellRange.new(:first_column => columns.first, :last_column => columns.last,
                      :first_row => interval.first, :last_row => interval.last)
      end
    end

    def title_columns_for(row_group, column_group)
      rows = visible_title_intervals(title_rows, true) + row_group.ranges
      visible_title_intervals(title_columns, false).product(merge_axis_ranges(rows)).map do |columns, row_interval|
        CellRange.new(:first_column => columns.first, :last_column => columns.last,
                      :first_row => row_interval.first, :last_row => row_interval.last)
      end
    end

    def merge_axis_ranges(ranges)
      sorted = ranges.sort_by(&:first)
      sorted.each_with_object([]) do |range, merged|
        if merged.empty? || range.first > merged.last.last + 1
          merged << AxisRange.new(:first => range.first, :last => range.last)
        else
          merged[-1] = AxisRange.new(:first => merged.last.first,
                                     :last => [merged.last.last, range.last].max)
        end
      end
    end

    def visible_title_intervals(intervals, rows)
      dimensions = rows ? row_dimensions : column_dimensions
      intervals.flat_map do |interval|
        interval.select { |index| !hidden?(index, dimensions, rows) }
                .slice_when { |previous, current| current != previous + 1 }
                .to_a
                .map { |values| AxisRange.new(:first => values.first, :last => values.last) }
      end
    end

    def order_pages(pages)
      ordered = pages.sort_by do |page|
        area = print_area_refs[page.print_area_index]
        if options[:page_order] == 'overThenDown' || worksheet.page_setup&.page_order == 'overThenDown'
          [area.first_column, area.first_row, page.print_area_index, page.page_column, page.page_row]
        else
          [area.first_row, area.first_column, page.print_area_index, page.page_row, page.page_column]
        end
      end
      ordered.each_with_index do |page, index|
        page.number = index + 1
      end
    end

    def result(pages, _area_plans)
      Result.new(
        :pages => pages,
        :scale => scale ? (scale * 100).to_i : nil,
        :mode => mode,
        :printable_width => printable_width,
        :printable_height => printable_height,
        :conflicts => conflicts.uniq,
        :warnings => warnings.uniq
      )
    end

    def add_conflict(reason, details = nil)
      conflicts << { :reason => reason, :details => details }
    end

    def add_warning(reason, details = nil)
      warnings << { :reason => reason, :details => details }
    end
  end
end
