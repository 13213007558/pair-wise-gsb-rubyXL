# frozen_string_literal: true

require 'rubyXL/objects/reference'

module RubyXL
  class PrintPlanner
    POINTS_PER_INCH = 72r
    PIXELS_PER_INCH = 96r
    MAX_DIGIT_PIXELS = 7r
    DEFAULT_COLUMN_WIDTH = 8r
    DEFAULT_ROW_HEIGHT = 13r
    DEFAULT_MARGINS = {
      :left => 0.7r, :right => 0.7r, :top => 0.75r, :bottom => 0.75r,
      :header => 0.3r, :footer => 0.3r
    }.freeze
    SCALE_TICKS_PER_PERCENT = 100
    MIN_SCALE_TICK = 1000
    MAX_SCALE_TICK = 40_000
    FIT_MAX_SCALE_TICK = 10_000

    PAPER_SIZES = {
      1 => [8.5r, 11r], 5 => [8.5r, 14r], 8 => [8.27r, 11.69r],
      9 => [8.27r, 11.69r], 11 => [8.27r, 11.69r], 12 => [8.5r, 11r],
      6 => [5.5r, 8.5r], 7 => [7.25r, 10.5r],
      24 => [11.69r, 16.54r], 26 => [12.4r, 9.6r],
      27 => [11.69r, 16.54r], 28 => [11.69r, 16.54r],
      64 => [8.5r, 13r], 65 => [8.125r, 11r],
      70 => [8.5r, 14r], 72 => [8.5r, 11r],
      73 => [11.69r, 16.54r], 74 => [11.69r, 16.54r]
    }.freeze

    Entry = Struct.new(:index, :size, keyword_init: true)
    Chunk = Struct.new(:entries, :start_index, :finish_index, :overflow, keyword_init: true)

    attr_reader :worksheet, :options

    def self.plan(worksheet, options = {})
      new(worksheet, options).plan
    end

    def initialize(worksheet, options = {})
      @worksheet = worksheet
      @options = options
      @errors = []

      setup_page
      setup_areas
      setup_titles
      setup_dimensions
    rescue ArgumentError => error
      @errors << error.message
    end

    def plan
      return conflict(@errors) unless @errors.empty?
      return empty_plan if @areas.empty?

      if fit_mode?
        plan_fit
      else
        plan_fixed
      end
    end

    private

    def setup_page
      setup = page_setup
      @custom_page_size = !options[:page_size_points].nil? || !options[:page_size].nil?
      @paper_size_code = integer_option(:paper_size, setup.paper_size || (@custom_page_size ? 0 : 1))
      dimensions = options[:page_size_points] || options[:page_size] || PAPER_SIZES[@paper_size_code]
      raise ArgumentError, "unsupported paper size: #{@paper_size_code}" if dimensions.nil?

      @orientation = options.fetch(:orientation, setup.orientation || 'default').to_s
      @orientation = 'portrait' if @orientation == 'default'
      unless %w[portrait landscape].include?(@orientation)
        raise ArgumentError, "orientation must be portrait or landscape"
      end

      @page_width = dimension_value(dimensions[0])
      @page_height = dimension_value(dimensions[1])
      @page_width, @page_height = @page_height, @page_width if landscape?

      @margins = current_margins
      @printable_width = @page_width - @margins[:left] - @margins[:right]
      @printable_height = @page_height - @margins[:top] - @margins[:bottom]
      raise ArgumentError, 'margins exceed page width' if @printable_width <= 0
      raise ArgumentError, 'margins exceed page height' if @printable_height <= 0

      @fit_mode = option?(:fit, sheet_fit_enabled?) ||
                  options.key?(:fit_to_width) || options.key?(:fit_to_height)
      @fit_to_width = fit_target(:fit_to_width, setup.fit_to_width)
      @fit_to_height = fit_target(:fit_to_height, setup.fit_to_height)
      @page_order = options.fetch(:page_order, setup.page_order || 'downThenOver').to_s
      unless %w[downThenOver overThenDown].include?(@page_order)
        raise ArgumentError, 'page_order must be downThenOver or overThenDown'
      end

      return if fit_mode?

      scale = options.fetch(:scale, setup.scale || 100)
      @scale_tick = Integer(Rational(scale.to_s) * SCALE_TICKS_PER_PERCENT)
      unless @scale_tick.between?(MIN_SCALE_TICK, MAX_SCALE_TICK)
        raise ArgumentError, 'scale must be between 10 and 400 percent'
      end
    end

    def setup_areas
      raw_areas = options.key?(:print_area) ? options[:print_area] : default_print_area
      normalized_areas = normalize_reference_value(raw_areas)
      sheet_range = used_range
      @used_range = normalized_areas.reduce(sheet_range) { |result, range| union_ranges(result, range) }
      @areas = normalized_areas.any? ? normalized_areas : [sheet_range]
    rescue StandardError
      raise ArgumentError, "invalid print area: #{raw_areas.inspect}"
    end

    def setup_titles
      title_value = options.key?(:print_titles) ? options[:print_titles] : default_print_titles
      @top_title_ranges = []
      @left_title_ranges = []
      if title_value
        title_value.to_s.split(/[\s]+/).each { |reference| parse_title_reference(reference) }
      end
      @top_title_indices = title_indices(@top_title_ranges, :rows)
      @left_title_indices = title_indices(@left_title_ranges, :cols)
    rescue StandardError
      raise ArgumentError, "invalid print titles: #{title_value.inspect}"
    end

    def parse_title_reference(reference)
      text = reference.to_s.sub(/\A(?:'.*?'|[^!]+)!/, '')
      split_title_parts(text).each do |part|
        parsed = parse_one_reference(part)
        if part =~ /\A\$?\d+(:\$?\d+)?\z/
          range = normalize_limited_range(parsed)
          @top_title_ranges << [range[0], range[1], @used_range[2], @used_range[3]]
        elsif part =~ /\A\$?[A-Z]+(:\$?[A-Z]+)?\z/i
          range = normalize_limited_range(parsed)
          @left_title_ranges << [@used_range[0], @used_range[1], range[2], range[3]]
        else
          raise ArgumentError, 'print titles must be whole rows or columns'
        end
      end
    end

    def split_title_parts(text)
      row_part = text[/\A\$?\d+(?::\$?\d+)?(?=,|\z)/]
      column_part = text[/(?<=,)\$?[A-Z]+(?::\$?[A-Z]+)?\z/i]
      parts = []
      parts << row_part if row_part
      parts << column_part if column_part
      raise ArgumentError, 'invalid print titles' if parts.empty?
      parts
    end

    def setup_dimensions
      row_end = @used_range[1]
      col_end = @used_range[3]
      @row_sizes = Array.new(row_end + 1) { |index| row_height(index) }
      @column_sizes = Array.new(col_end + 1) { |index| column_width(index) }
      @row_breaks = manual_breaks(worksheet.row_breaks, row_end)
      @column_breaks = manual_breaks(worksheet.col_breaks, col_end)
    end

    def plan_fit
      reasons = fit_conflict_reasons
      return conflict(reasons) unless reasons.empty?

      tick = best_fit_tick
      unless tick
        return conflict(['content cannot fit at the minimum supported scale of 10 percent'])
      end

      pages = paginate_all(tick)
      build_plan(pages, tick, true)
    end

    def plan_fixed
      build_plan(paginate_all(@scale_tick), @scale_tick, false)
    end

    def fit_conflict_reasons
      reasons = []
      reasons << 'manual column breaks require more pages than fitToWidth' if forced_pages(:cols) > constrained_target(@fit_to_width)
      reasons << 'manual row breaks require more pages than fitToHeight' if forced_pages(:rows) > constrained_target(@fit_to_height)
      reasons
    end

    def constrained_target(value)
      value.to_i.positive? ? value.to_i : Float::INFINITY
    end

    def forced_pages(direction)
      breaks = direction == :rows ? @row_breaks : @column_breaks
      @areas.map { |area| forced_parts(area, direction, breaks).count(&:any?) }.max || 0
    end

    def best_fit_tick
      constrained = []
      constrained << :cols if @fit_to_width.to_i.positive?
      constrained << :rows if @fit_to_height.to_i.positive?
      return FIT_MAX_SCALE_TICK if constrained.empty?
      return nil unless scale_feasible?(MIN_SCALE_TICK)
      return FIT_MAX_SCALE_TICK if scale_feasible?(FIT_MAX_SCALE_TICK)

      low = MIN_SCALE_TICK
      high = FIT_MAX_SCALE_TICK
      while low < high
        middle = (low + high + 1) / 2
        if scale_feasible?(middle)
          low = middle
        else
          high = middle - 1
        end
      end
      low
    end

    def scale_feasible?(tick)
      [@fit_to_width, @fit_to_height].each_with_index.all? do |target, index|
        direction = index.zero? ? :cols : :rows
        next true unless target.to_i.positive?
        target_pages(direction, tick) <= target.to_i
      end
    end

    def target_pages(direction, tick)
      breaks = direction == :rows ? @row_breaks : @column_breaks
      @areas.map { |area| paginate_axis(area, direction, breaks, tick) }.map do |chunks, overflow|
        next Float::INFINITY if overflow
        chunks.size
      end.max || 0
    end

    def paginate_all(tick)
      pages = []
      @areas.each_with_index do |area, area_index|
        col_chunks = paginate_axis(area, :cols, @column_breaks, tick).first
        row_chunks = paginate_axis(area, :rows, @row_breaks, tick).first
        col_chunks.each_with_index do |col_chunk, x|
          row_chunks.each_with_index do |row_chunk, y|
            pages << build_page(area, area_index, row_chunk, col_chunk, x, y, tick)
          end
        end
      end
      pages = sort_pages(pages)
    end

    def sort_pages(pages)
      ordered = if @page_order == 'overThenDown'
                  pages.sort_by { |page| [page[:area_index], page[:tile_row], page[:tile_column]] }
                else
                  pages.sort_by { |page| [page[:area_index], page[:tile_column], page[:tile_row]] }
                end
      ordered.each_with_index { |page, index| page[:page_number] = index + 1 }
      ordered
    end

    def build_page(area, area_index, row_chunk, col_chunk, tile_column, tile_row, tick)
      body_range = range_from_array(row_chunk.start_index, row_chunk.finish_index,
                                    col_chunk.start_index, col_chunk.finish_index)
      segments = title_segments(row_chunk, col_chunk, tick)
      {
        :area_index => area_index,
        :tile_row => tile_row,
        :tile_column => tile_column,
        :body_range => reference_to_s(body_range),
        :title_ranges => title_range_strings(segments),
        :offset => page_offsets(area, body_range, tick),
        :actual_scale_percent => scale_percent(tick),
        :overflow => row_chunk.overflow || col_chunk.overflow
      }
    end

    def title_segments(row_chunk, col_chunk, tick)
      scale = Rational(tick, SCALE_TICKS_PER_PERCENT * 100)
      segments = []
      grouped_ranges(@top_title_ranges).each do |range|
        row_entries = entries(range[0], range[1], :rows)
        column_entries = col_chunk.entries
        segments << segment_info(:top, row_entries, column_entries,
                                 @margins[:top] + title_offset(range[0], :rows) * scale,
                                 @margins[:left] + repeated_size(:cols) * scale)
      end
      grouped_ranges(@left_title_ranges).each do |range|
        row_entries = row_chunk.entries
        column_entries = entries(range[2], range[3], :cols)
        segments << segment_info(:left, row_entries, column_entries,
                                 @margins[:top] + repeated_size(:rows) * scale,
                                 @margins[:left] + title_offset(range[2], :cols) * scale)
      end
      grouped_ranges(@top_title_ranges).each do |top_range|
        grouped_ranges(@left_title_ranges).each do |left_range|
          row_entries = entries(top_range[0], top_range[1], :rows)
          column_entries = entries(left_range[2], left_range[3], :cols)
          segments << segment_info(:corner, row_entries, column_entries,
                                   @margins[:top] + title_offset(top_range[0], :rows) * scale,
                                   @margins[:left] + title_offset(left_range[2], :cols) * scale)
        end
      end
      segments.reject { |segment| segment[:range].nil? }
    end

    def segment_info(kind, row_entries, column_entries, top_offset, left_offset)
      range = if row_entries.any? && column_entries.any?
                range_from_array(row_entries.first.index, row_entries.last.index,
                                 column_entries.first.index, column_entries.last.index)
              end
      {
        :kind => kind,
        :range => range,
        :page_top_points => top_offset,
        :page_left_points => left_offset
      }
    end

    def title_range_strings(segments)
      segments.map do |segment|
        {
          :kind => segment[:kind],
          :range => reference_to_s(segment[:range]),
          :page_top_points => segment[:page_top_points].to_f,
          :page_left_points => segment[:page_left_points].to_f
        }
      end
    end

    def page_offsets(area, body_range, tick)
      row_offset = sum_sizes(@used_range[0], body_range[0], :rows)
      col_offset = sum_sizes(@used_range[2], body_range[2], :cols)
      body_row_start = body_range[0] - area[0]
      body_col_start = body_range[2] - area[2]
      scale = Rational(tick, SCALE_TICKS_PER_PERCENT * 100)
      {
        :row_index => body_range[0],
        :column_index => body_range[2],
        :sheet_row_offset_points => row_offset.to_f,
        :sheet_column_offset_points => col_offset.to_f,
        :area_row_offset_index => body_row_start,
        :area_column_offset_index => body_col_start,
        :page_body_top_points => (@margins[:top] + repeated_size(:rows) * scale).to_f,
        :page_body_left_points => (@margins[:left] + repeated_size(:cols) * scale).to_f,
        :scaled_sheet_row_offset_points => (row_offset * scale).to_f,
        :scaled_sheet_column_offset_points => (col_offset * scale).to_f,
        :scaled_page_body_top_points => (@margins[:top] + repeated_size(:rows) * scale).to_f,
        :scaled_page_body_left_points => (@margins[:left] + repeated_size(:cols) * scale).to_f
      }
    end

    def repeated_size(direction)
      ranges = direction == :rows ? @top_title_ranges : @left_title_ranges
      sum_entries(title_indices(ranges, direction == :rows ? :rows : :cols), direction)
    end

    def title_offset(index, direction)
      indexes = direction == :rows ? @top_title_indices : @left_title_indices
      sum_entries(indexes.select { |item| item < index }, direction)
    end

    def paginate_axis(area, direction, breaks, tick)
      capacity = axis_capacity(direction, tick)
      parts = forced_parts(area, direction, breaks)
      chunks = parts.reject(&:empty?).map do |part_entries|
        pack_entries(part_entries, capacity, part_entries.first.index, part_entries.last.index)
      end.flatten(1)
      [chunks, chunks.any?(&:overflow)]
    end

    def axis_capacity(direction, tick)
      title = repeated_size(direction)
      available = direction == :rows ? @printable_height : @printable_width
      available * SCALE_TICKS_PER_PERCENT * 100 / tick - title
    end

    def forced_parts(area, direction, breaks)
      all_entries = entries(area[0], area[1], :rows) if direction == :rows
      all_entries = entries(area[2], area[3], :cols) if direction == :cols
      visible = all_entries.reject do |entry|
        title_indices(nil, direction).include?(entry.index)
      end
      split_by_boundaries(visible, breaks, area, direction)
    end

    def split_by_boundaries(entries_to_split, breaks, area, direction)
      start_index = direction == :rows ? area[0] : area[2]
      finish_index = direction == :rows ? area[1] : area[3]
      boundaries = breaks.select { |value| value > start_index && value <= finish_index }
      parts = []
      current = []
      entries_to_split.each do |entry|
        while boundaries.any? && boundaries.first <= entry.index
          parts << current
          current = []
          boundaries.shift
        end
        current << entry
      end
      parts << current
      parts
    end

    def pack_entries(entries_to_pack, capacity, part_start = nil, part_finish = nil)
      return [empty_chunk] if entries_to_pack.empty?
      chunks = []
      current = []
      used = 0r
      overflow_current = false
      chunk_start = entries_to_pack.first.index
      entries_to_pack.each do |entry|
        if current.any? && used + entry.size > capacity
          chunks << Chunk.new(:entries => current,
                              :start_index => chunk_start,
                              :finish_index => entry.index - 1,
                              :overflow => overflow_current)
          current = []
          used = 0r
          overflow_current = false
          chunk_start = entry.index
        end
        overflow_current = true if current.empty? && entry.size > capacity
        current << entry
        used += entry.size
      end
      chunks << Chunk.new(:entries => current,
                          :start_index => chunk_start,
                          :finish_index => overflow_current ? chunk_start : (part_finish || current.last.index),
                          :overflow => overflow_current)
      chunks
    end

    def empty_chunk
      Chunk.new(:entries => [], :start_index => nil, :finish_index => nil, :overflow => false)
    end

    def entries(start_index, finish_index, direction)
      sizes = direction == :rows ? @row_sizes : @column_sizes
      return [] if start_index.nil? || finish_index.nil?
      (start_index..finish_index).filter_map do |index|
        next if hidden_index?(index, direction)
        size = sizes[index].to_r
        next if size <= 0
        Entry.new(:index => index, :size => size)
      end
    end

    def sum_entries(indexes, direction)
      indexes.sum { |index| direction == :rows ? @row_sizes[index].to_r : @column_sizes[index].to_r }
    end

    def sum_sizes(start_index, finish_index, direction)
      return 0r if start_index.nil? || finish_index.nil? || finish_index < start_index
      (start_index...finish_index).sum { |index| direction == :rows ? @row_sizes[index].to_r : @column_sizes[index].to_r }
    end

    def hidden_index?(index, direction)
      if direction == :rows
        row = worksheet.sheet_data&.rows&.[](index)
        return true if row&.hidden
      else
        range = worksheet.cols&.locate_range(index)
        return true if range&.hidden
      end
      false
    end

    def row_height(index)
      row = worksheet.sheet_data&.rows&.[](index)
      return 0r if row&.hidden
      return Rational(options[:row_heights_points][index].to_s) if options[:row_heights_points]&.key?(index)
      height = row&.ht || sheet_format.default_row_height || DEFAULT_ROW_HEIGHT
      Rational(height.to_s)
    end

    def column_width(index)
      range = worksheet.cols&.locate_range(index)
      return 0r if range&.hidden
      return Rational(options[:column_widths_points][index].to_s) if options[:column_widths_points]&.key?(index)
      width = range&.width
      width ||= sheet_format.default_col_width
      width ||= (sheet_format.base_col_width || DEFAULT_COLUMN_WIDTH) + Rational(5, MAX_DIGIT_PIXELS)
      pixels = (Rational(width.to_s) * MAX_DIGIT_PIXELS).floor
      pixels * POINTS_PER_INCH / PIXELS_PER_INCH
    end

    def title_indices(ranges, direction)
      return @top_title_indices if ranges.nil? && direction == :rows
      return @left_title_indices if ranges.nil? && direction == :cols
      positions = direction == :rows ? [0, 1] : [2, 3]
      ranges.flat_map { |range| (range[positions[0]]..range[positions[1]]).to_a }.uniq.sort
    end

    def manual_breaks(break_list, last_index)
      return [] if break_list.nil?
      break_list.select(&:man)
                .map { |break_item| break_item.id.to_i }
                .select { |index| index >= 0 && index <= last_index }
                .uniq.sort
    end

    def sheet_format
      worksheet.sheet_format_pr || RubyXL::WorksheetFormatProperties.new(
        :default_row_height => DEFAULT_ROW_HEIGHT,
        :base_col_width => DEFAULT_COLUMN_WIDTH
      )
    end

    def page_setup
      worksheet.page_setup || RubyXL::PageSetup.new
    end

    def current_margins
      margins = worksheet.page_margins
      DEFAULT_MARGINS.keys.each_with_object({}) do |key, result|
        if options[:margins_points]&.key?(key)
          result[key] = Rational(options[:margins_points][key].to_s)
        else
          value = options.dig(:margins, key)
          value = margins&.public_send(key) if value.nil?
          result[key] = value.nil? ? DEFAULT_MARGINS[key] * POINTS_PER_INCH : Rational(value.to_s) * POINTS_PER_INCH
        end
      end
    end

    def sheet_fit_enabled?
      properties = worksheet.sheet_pr
      properties&.page_set_up_pr&.fit_to_page == true
    end

    def fit_mode?
      @fit_mode || @fit_to_width.to_i.positive? || @fit_to_height.to_i.positive?
    end

    def landscape?
      @orientation == 'landscape'
    end

    def option?(key, default = false)
      options.key?(key) ? options[key] : default
    end

    def integer_option(key, default_value, fallback = nil)
      value = options.fetch(key, default_value || fallback)
      value.nil? ? fallback : Integer(value)
    end

    def fit_target(key, worksheet_value)
      value = options.fetch(key, worksheet_value)
      value = 1 if fit_mode? && value.nil?
      value = 0 unless fit_mode?
      value = Integer(value)
      raise ArgumentError, "#{key} cannot be negative" if value.negative?
      value
    end

    def physical_dimension(value)
      Rational(value.to_s) * POINTS_PER_INCH
    end

    def dimension_value(value)
      @custom_page_size ? Rational(value.to_s) : physical_dimension(value)
    end

    def scale_percent(tick)
      Rational(tick, SCALE_TICKS_PER_PERCENT).to_f
    end

    def build_plan(pages, tick, fit)
      {
        :feasible => pages.none? { |page| page[:overflow] },
        :conflict_reasons => pages.any? { |page| page[:overflow] } ? ['content exceeds the printable area at the selected scale'] : [],
        :page_count => pages.size,
        :orientation => @orientation,
        :paper_size => @paper_size_code,
        :page_size_points => { :width => @page_width.to_f, :height => @page_height.to_f },
        :printable_size_points => { :width => @printable_width.to_f, :height => @printable_height.to_f },
        :mode => fit ? 'fit' : 'scale',
        :fit_to_width => @fit_to_width,
        :fit_to_height => @fit_to_height,
        :actual_scale_percent => scale_percent(tick),
        :scale_search => scale_search(fit),
        :pages => pages
      }
    end

    def scale_search(fit)
      return nil unless fit
      {
        :rule => 'binary search over integer hundredths of a percent',
        :minimum_percent => 10.0,
        :maximum_percent => 100.0,
        :step_percent => 0.01,
        :fit_only_shrinks => true
      }
    end

    def empty_plan
      {
        :feasible => true,
        :conflict_reasons => [],
        :page_count => 0,
        :orientation => @orientation,
        :paper_size => @paper_size_code,
        :page_size_points => { :width => @page_width.to_f, :height => @page_height.to_f },
        :printable_size_points => { :width => @printable_width.to_f, :height => @printable_height.to_f },
        :mode => fit_mode? ? 'fit' : 'scale',
        :fit_to_width => @fit_to_width,
        :fit_to_height => @fit_to_height,
        :actual_scale_percent => scale_percent(fit_mode? ? FIT_MAX_SCALE_TICK : @scale_tick.to_i),
        :scale_search => scale_search(fit_mode?),
        :pages => []
      }
    end

    def conflict(reasons)
      {
        :feasible => false,
        :conflict_reasons => Array(reasons),
        :page_count => 0,
        :pages => [],
        :actual_scale_percent => nil,
        :scale_search => scale_search(fit_mode?)
      }
    end

    def default_print_area
      defined_name = matching_defined_name?('_xlnm.Print_Area')
      defined_name ? defined_name.reference : used_range_reference
    end

    def default_print_titles
      defined_name = matching_defined_name?('_xlnm.Print_Titles')
      defined_name ? defined_name.reference : nil
    end

    def matching_defined_name?(name)
      return nil unless worksheet.workbook&.respond_to?(:defined_names)
      worksheet.workbook.defined_names&.find do |defined_name|
        next false unless defined_name.name == name
        next references_this_sheet?(defined_name.reference.to_s) if defined_name.local_sheet_id.nil?
        defined_name.local_sheet_id.to_s == worksheet.sheet_id.to_s
      end
    end

    def references_this_sheet?(reference)
      split_references(reference).any? { |item| item =~ /\A('?#{Regexp.escape(worksheet.sheet_name.to_s)}'?)!/ }
    end

    def used_range_reference
      range = used_range
      range.nil? ? nil : reference_to_s(range)
    end

    def used_range
      dimension = worksheet.dimension&.ref
      return parse_one_reference(dimension) if dimension
      rows = worksheet.sheet_data&.rows || []
      last_row = rows.rindex { |row| row && row.cells.any? }
      return [0, 0, 0, 0] if last_row.nil?
      last_col = rows[0..last_row].map { |row| row ? row.cells.rindex { |cell| !cell.nil? } : nil }.compact.max || 0
      [0, last_row, 0, last_col]
    end

    def normalize_reference_value(value)
      return [] if value.nil?
      if value.is_a?(Array) && value.length == 4 && value.all? { |item| item.nil? || item.is_a?(Numeric) }
        value = [value]
      end
      values = value.is_a?(Array) ? value.map(&:to_s) : split_references(value.to_s)
      values.map { |item| parse_one_reference(item) }
    end

    def split_references(value)
      value.split(/[\s,]+(?=(?:[^']*'[^']*')*[^']*$)/).map(&:strip).reject(&:empty?)
    end

    def parse_one_reference(reference)
      text = reference.to_s.strip.sub(/\A(?:'.*?'|[^!]+)!/, '')
      from, to = text.split(':', 2)
      first = parse_cell_or_axis(from)
      second = to ? parse_cell_or_axis(to) : first
      [first[0].nil? ? second[0] : first[0], second[0].nil? ? first[0] : second[0],
       first[1].nil? ? second[1] : first[1], second[1].nil? ? first[1] : second[1]]
    end

    def parse_cell_or_axis(text)
      case text
      when /\A\$?([A-Z]+)\$?(\d+)\z/i
        [Regexp.last_match(2).to_i - 1, column_letter_to_index(Regexp.last_match(1))]
      when /\A\$?([A-Z]+)\$?\z/i
        [nil, column_letter_to_index(Regexp.last_match(1))]
      when /\A\$?(\d+)\$?\z/
        [Regexp.last_match(1).to_i - 1, nil]
      else
        raise ArgumentError, "invalid reference: #{text}"
      end
    end

    def column_letter_to_index(letters)
      letters.upcase.each_char.reduce(-1) { |result, letter| (result + 1) * 26 + letter.ord - 'A'.ord }
    end

    def normalize_limited_range(range)
      range_from_array(range[0].nil? ? 0 : range[0],
                       range[1].nil? ? @used_range[1] : range[1],
                       range[2].nil? ? 0 : range[2],
                       range[3].nil? ? @used_range[3] : range[3])
    end

    def range_from_array(row_start, row_end, col_start, col_end)
      values = [row_start, row_end, col_start, col_end]
      raise ArgumentError, 'invalid range' if values.any? { |value| value.nil? }
      values = values.map(&:to_i)
      raise ArgumentError, 'invalid range' if values[0] > values[1] || values[2] > values[3] || values.any?(&:negative?)
      values
    end

    def union_ranges(first, second)
      [[first[0], second[0]].min, [first[1], second[1]].max,
       [first[2], second[2]].min, [first[3], second[3]].max]
    end

    def grouped_ranges(ranges)
      ranges.sort_by { |range| [range[0].to_i, range[2].to_i] }
    end

    def reference_to_s(range)
      return nil if range.nil?
      "#{cell_reference(range[0], range[2])}:#{cell_reference(range[1], range[3])}"
    end

    def cell_reference(row, col)
      letters = ''
      value = col
      while value >= 0
        letters = ((value % 26) + 'A'.ord).chr + letters
        value = value / 26 - 1
      end
      "#{letters}#{row + 1}"
    end
  end
end
