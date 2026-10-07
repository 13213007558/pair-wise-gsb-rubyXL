# frozen_string_literal: true

module RubyXL
  module ConditionalFormatRules
    # Resolved (materialised) cell style: differential style layers are merged
    # into these concrete objects instead of style table indexes.
    ResolvedStyle = Struct.new(:xf, :font, :fill, :border, :number_format,
                               :alignment, :protection, keyword_init: true)

    # Merges differential formatting (dxf) into an already materialised style.
    #
    # A dxf only overrides the style properties it actually declares. For
    # example, a dxf that declares a red <font> but no <fill> changes the
    # font colour only and leaves the base fill untouched; within the font
    # only the present children (colour, bold, size, ...) override anything.
    module StyleMerger
      module_function

      def dup_style(style)
        ResolvedStyle.new(
          xf:            safe_dup(style.xf),
          font:          safe_dup(style.font),
          fill:          safe_dup(style.fill),
          border:        safe_dup(style.border),
          number_format: safe_dup(style.number_format),
          alignment:     safe_dup(style.alignment),
          protection:    safe_dup(style.protection)
        )
      end

      # Returns a Hash describing which style families changed.
      def apply_dxf(style, dxf)
        changes = { font_changed: false, fill_changed: false, border_changed: false,
                    number_format_changed: false, alignment_changed: false, protection_changed: false }
        return changes if dxf.nil?

        changes[:font_changed] = merge_font(style, dxf.font) if dxf.font
        changes[:fill_changed] = merge_fill(style, dxf.fill) if dxf.fill
        changes[:border_changed] = merge_border(style, dxf.border) if dxf.border
        changes[:number_format_changed] = merge_number_format(style, dxf) if dxf.num_fmt
        changes[:alignment_changed] = merge_alignment(style, dxf.alignment) if dxf.alignment
        changes[:protection_changed] = merge_protection(style, dxf.protection) if dxf.protection
        changes
      end

      def solid_fill(rgb)
        RubyXL::Fill.new(pattern_fill: RubyXL::PatternFill.new(
          pattern_type: 'solid',
          fg_color: RubyXL::Color.new(rgb: rgb)
        ))
      end

      # ----- fonts --------------------------------------------------------

      FONT_PROPERTY_ACCESSORS = %i[name charset family b i strike outline shadow
                                   condense extend color sz u vert_align scheme].freeze

      def merge_font(style, dxf_font)
        style.font ||= RubyXL::Font.new
        changed = false
        FONT_PROPERTY_ACCESSORS.each do |accessor|
          value = dxf_font.public_send(accessor)
          next if value.nil?
          style.font.public_send("#{accessor}=", safe_dup(value))
          changed = true
        end
        changed
      end

      # ----- fills --------------------------------------------------------

      def merge_fill(style, dxf_fill)
        if dxf_fill.pattern_fill
          merge_pattern_fill(style, dxf_fill.pattern_fill)
        elsif dxf_fill.gradient_fill
          style.fill = safe_dup(dxf_fill)
          true
        else
          false
        end
      end

      def merge_pattern_fill(style, pattern)
        style.fill ||= RubyXL::Fill.new
        target = style.fill.pattern_fill ||= RubyXL::PatternFill.new
        changed = false

        if pattern.pattern_type
          target.pattern_type = pattern.pattern_type
          changed = true
        end
        if pattern.fg_color
          target.fg_color = safe_dup(pattern.fg_color)
          changed = true
        end
        if pattern.bg_color
          target.bg_color = safe_dup(pattern.bg_color)
          changed = true
        end
        changed
      end

      # ----- borders ------------------------------------------------------

      BORDER_EDGES = %i[left right top bottom diagonal vertical horizontal].freeze

      def merge_border(style, dxf_border)
        style.border ||= RubyXL::Border.new
        changed = false

        BORDER_EDGES.each do |edge_name|
          edge = dxf_border.public_send(edge_name)
          next if edge.nil?
          style.border.public_send("#{edge_name}=", merge_border_edge(style.border.public_send(edge_name), edge))
          changed = true
        end

        %i[diagonal_up diagonal_down outline].each do |flag|
          value = dxf_border.public_send(flag)
          next if value.nil?
          style.border.public_send("#{flag}=", value)
          changed = true
        end
        changed
      end

      def merge_border_edge(target, source)
        target ||= RubyXL::BorderEdge.new
        target.style = source.style unless source.style.nil?
        target.color = safe_dup(source.color) unless source.color.nil?
        target
      end

      # ----- remaining families ------------------------------------------

      def merge_number_format(style, dxf)
        style.number_format = RubyXL::NumberFormat.new(
          num_fmt_id: dxf.num_fmt.num_fmt_id,
          format_code: dxf.num_fmt.format_code
        )
        true
      end

      ALIGNMENT_ACCESSORS = %i[horizontal vertical text_rotation wrap_text indent
                                relative_indent justify_last_line shrink_to_fit reading_order].freeze

      def merge_alignment(style, dxf_alignment)
        style.alignment ||= RubyXL::Alignment.new
        ALIGNMENT_ACCESSORS.each do |accessor|
          value = dxf_alignment.public_send(accessor)
          style.alignment.public_send("#{accessor}=", value) unless value.nil?
        end
        true
      end

      def merge_protection(style, dxf_protection)
        style.protection ||= RubyXL::Protection.new
        style.protection.locked = dxf_protection.locked unless dxf_protection.locked.nil?
        style.protection.hidden = dxf_protection.hidden unless dxf_protection.hidden.nil?
        true
      end

      def safe_dup(object)
        return nil if object.nil?
        Marshal.load(Marshal.dump(object))
      rescue TypeError
        object.dup
      end
    end

    # Interpolates the colour of a colorScale rule for a numeric cell value.
    #
    # Supported cfvo kinds: +min+, +max+, +num+, +percent+ and +percentile+.
    # Formula cfvos are not evaluable (there is no calculation engine) and
    # make the whole scale unevaluable. Non-numeric/blank cells get no colour.
    class ColorScaleResolver
      def initialize(rule, worksheet, numeric_cells_with_values)
        @rule = rule
        @worksheet = worksheet
        @entries = numeric_cells_with_values # array of [row, col, Numeric]
      end

      # Returns Hash [row, col] => 6- or 8-digit uppercase RGB string.
      def colors
        result = {}
        scale = prepared_scale
        return result if scale.nil?

        @entries.each do |row, col, value|
          rgb = interpolate(value, scale)
          result[[row, col]] = rgb if rgb
        end
        result
      end

      def unevaluable?
        prepared_scale.nil?
      end

      private

      def color_scale
        @rule.color_scale
      end

      def prepared_scale
        @prepared_scale ||= begin
          cfvos = color_scale&.cfvo
          colors = color_scale_colors
          return nil if cfvos.nil? || cfvos.size < 2 || colors.size != cfvos.size

          values = @entries.map(&:last)
          min = values.min
          max = values.max
          return nil if min.nil? || max.nil?

          stops = cfvos.zip(colors).map do |cfvo, color|
            numeric = stop_value_boundary(cfvo, min, max, values)
            return nil if numeric.nil?
            rgb = resolve_color(color)
            return nil if rgb.nil?
            { numeric: numeric, rgb: rgb, gte: cfvo.gte.nil? ? true : cfvo.gte }
          end

          stops.sort_by { |stop| stop[:numeric] }
        end
      end

      def color_scale_colors
        @color_scale_colors ||= color_scale.color || []
      end

      # Absolute numeric value at which the cfvo stop sits.
      def stop_value_boundary(cfvo, min, max, values)
        case cfvo.type
        when 'min' then min.to_f
        when 'max' then max.to_f
        when 'num'
          return nil if cfvo.val.nil? || max == min
          cfvo.val.to_f
        when 'percent'
          return nil if cfvo.val.nil? || max == min
          min + (max - min) * cfvo.val.to_f / 100.0
        when 'percentile'
          return nil if cfvo.val.nil?
          percentile_value(values.sort, cfvo.val.to_f)
        else
          nil # 'formula' and anything else are not evaluable.
        end
      end

      def percentile_value(sorted, percentile)
        fraction = percentile / 100.0
        index = fraction * (sorted.size - 1)
        lower = index.floor
        upper = index.ceil
        if lower == upper
          sorted[lower].to_f
        else
          sorted[lower] + (sorted[upper] - sorted[lower]) * (index - lower)
        end
      end

      def resolve_color(color)
        rgb = color.rgb
        rgb ||= begin
          workbook = @worksheet.workbook
          color.get_rgb(workbook) if workbook
        end
        rgb
      end

      def interpolate(value, stops)
        below = stops[0]
        above = stops[-1]
        stops.each_cons(2) do |left, right|
          if value >= left[:numeric] && value <= right[:numeric]
            below = left
            above = right
            break
          end
        end

        return below[:rgb] if value <= below[:numeric]
        return above[:rgb] if value >= above[:numeric]

        span = above[:numeric] - below[:numeric]
        weight = span.zero? ? 0.0 : (value - below[:numeric]).to_f / span
        blend_rgb(below[:rgb], above[:rgb], weight)
      end

      def blend_rgb(left_rgb, right_rgb, weight)
        la = rgba(left_rgb)
        lb = rgba(right_rgb)
        channels = la.zip(lb).map { |a, b| (a + (b - a) * weight).round }
        format('%02X%02X%02X%02X', *channels).then do |argb|
          # Drop fully opaque alpha so results stay comparable to RGB dxf colours.
          channels[0] == 255 ? argb[2..-1] : argb
        end
      end

      def rgba(rgb)
        hex = rgb.to_s.upcase
        hex = "FF#{hex}" if hex.size == 6
        hex.chars.each_slice(2).map { |pair| pair.join.to_i(16) }
      end
    end
  end
end
