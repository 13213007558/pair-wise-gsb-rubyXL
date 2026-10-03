# frozen_string_literal: true

require 'rubyXL/objects/color'
require 'rubyXL/convenience_methods/color'

module RubyXL
  # Consolidates equivalent stylesheet records while preserving OOXML semantics.
  class StyleCompressor
    XF_FIELDS = {
      :num_fmt_id => :apply_number_format,
      :font_id => :apply_font,
      :fill_id => :apply_fill,
      :border_id => :apply_border
    }.freeze

    def self.compress(workbook, preserve_theme_colors: true)
      new(workbook, preserve_theme_colors).compress
    end

    def initialize(workbook, preserve_theme_colors)
      @workbook = workbook
      @preserve_theme_colors = preserve_theme_colors
      @styles = workbook.stylesheet
      @styles.fonts ||= Fonts.default
      @styles.fills ||= Fills.default
      @styles.borders ||= Borders.default
      @styles.cell_style_xfs ||= CellStyleXFs.default
      @styles.cell_xfs ||= CellXFs.default
      @styles.cell_styles ||= CellStyles.default

      @before = Hash.new(0)
      @maps = Hash.new { |hash, key| hash[key] = {} }
    end

    def compress
      count_before
      compress_number_formats
      old_font_size = @styles.fonts.size
      compress_resources
      old_style_xfs = @styles.cell_style_xfs.dup
      old_cell_xfs = @styles.cell_xfs.dup
      old_dxf_count = Array(@styles.dxfs).size
      compress_style_xfs(old_style_xfs)
      compress_cell_xfs(old_style_xfs)
      compress_dxfs
      rewrite_references(old_style_xfs.size, old_cell_xfs.size, old_dxf_count, old_font_size)
      stats = count_after
      { :mappings => @maps, :statistics => stats }
    end

    private

    def count_before
      @before[:num_fmts] = Array(@styles.number_formats).size
      @before[:fonts] = @styles.fonts.size
      @before[:fills] = @styles.fills.size
      @before[:borders] = @styles.borders.size
      @before[:style_xfs] = @styles.cell_style_xfs.size
      @before[:cell_xfs] = @styles.cell_xfs.size
      @before[:dxfs] = Array(@styles.dxfs).size
    end

    def count_after
      after_counts = {
        :num_fmts => Array(@styles.number_formats).size,
        :fonts => @styles.fonts.size,
        :fills => @styles.fills.size,
        :borders => @styles.borders.size,
        :style_xfs => @styles.cell_style_xfs.size,
        :cell_xfs => @styles.cell_xfs.size,
        :dxfs => Array(@styles.dxfs).size
      }
      removed = @before.keys.each_with_object({}) { |key, hash|
        hash[key] = @before[key] - after_counts[key]
      }
      after_counts.merge(:removed => removed)
    end

    def compress_number_formats
      custom = Array(@styles.number_formats)
      by_code = {}
      custom.each { |fmt| (by_code[normalize_format(fmt.format_code)] ||= []) << fmt }

      canonical = custom.map { |fmt|
        code = normalize_format(fmt.format_code)
        next 0 if code == 'General'
        built_in = NumberFormats::DEFAULT_NUMBER_FORMATS.find { |default_fmt|
          normalize_format(default_fmt.format_code) == code
        }
        built_in ? built_in.num_fmt_id : by_code[code].min_by(&:num_fmt_id).num_fmt_id
      }

      identity_mapping([ 0 ] + NumberFormats::DEFAULT_NUMBER_FORMATS.map(&:num_fmt_id) + custom.map(&:num_fmt_id))
      custom.each_with_index { |fmt, index| @maps[:num_fmts][fmt.num_fmt_id] = canonical[index] }

      kept = custom.select { |fmt| @maps[:num_fmts][fmt.num_fmt_id] == fmt.num_fmt_id }
      @styles.number_formats = kept.empty? ? nil : NumberFormats.new(:_ => kept)
    end

    def compress_resources
      compact_container(:fonts, @styles.fonts) { |font| canonical_font(font); semantic(font) }
      compact_container(:fills, @styles.fills) { |fill| canonical_fill(fill); fill_semantic(fill) }
      compact_container(:borders, @styles.borders) { |border| canonical_border(border); border_semantic(border) }
    end

    def compress_style_xfs(old_style_xfs)
      # Named styles have no parent XF; explicit apply=false means use the default.
      canonical_xfs = old_style_xfs.map { |xf| canonical_xf(xf, nil) }
      compact_canonical(:style_xfs, canonical_xfs)
    end

    def compress_cell_xfs(old_style_xfs)
      # Resolve xfId inheritance before comparing cell XFs.
      canonical_xfs = @styles.cell_xfs.map do |xf|
        parent = xf.xf_id.nil? ? nil : old_style_xfs[xf.xf_id.to_i]
        canonical_xf(xf, parent)
      end
      compact_canonical(:cell_xfs, canonical_xfs)
    end

    def compress_dxfs
      return if Array(@styles.dxfs).empty?
      compact_container(:dxfs, @styles.dxfs) do |dxf|
        canonical_dxf(dxf)
        dxf_semantic(dxf)
      end
      @styles.dxfs = nil if @styles.dxfs.empty?
    end

    def compact_container(map_name, collection)
      groups = {}
      new_items = []
      mapping = @maps[map_name]

      collection.each_with_index { |item, old_id|
        if item.nil? then
          mapping[old_id] = new_items.size
          new_items << nil
          next
        end

        key = yield(item)
        new_id = groups[key]
        if new_id.nil? then
          new_id = new_items.size
          groups[key] = new_id
          new_items << item
        end
        mapping[old_id] = new_id
      }

      collection.replace(new_items)
    end

    def compact_canonical(map_name, items)
      groups = {}
      new_items = []
      mapping = @maps[map_name]

      items.each_with_index { |item, old_id|
        key = semantic(item)
        new_id = groups[key]
        if new_id.nil? then
          new_id = new_items.size
          groups[key] = new_id
          new_items << item
        end
        mapping[old_id] = new_id
      }

      assign_container(map_name, new_items)
    end

    def assign_container(name, items)
      case name
      when :fonts then @styles.fonts = Fonts.new(:_ => items)
      when :fills then @styles.fills = Fills.new(:_ => items)
      when :borders then @styles.borders = Borders.new(:_ => items)
      when :style_xfs then @styles.cell_style_xfs = CellStyleXFs.new(:_ => items)
      when :cell_xfs then @styles.cell_xfs = CellXFs.new(:_ => items)
      when :dxfs then @styles.dxfs = DXFs.new(:_ => items)
      end
    end

    def canonical_xf(xf, parent)
      result = XF.new
      result.num_fmt_id = mapped_id(:num_fmts, xf_component(xf, parent, :num_fmt_id, 0))
      result.font_id = mapped_id(:fonts, xf_component(xf, parent, :font_id, 0))
      result.fill_id = mapped_id(:fills, xf_component(xf, parent, :fill_id, 0))
      result.border_id = mapped_id(:borders, xf_component(xf, parent, :border_id, 0))
      XF_FIELDS.values.each { |field| result.public_send("#{field}=", true) }
      result.quote_prefix = xf.quote_prefix == true || parent&.quote_prefix == true
      result.pivot_button = xf.pivot_button == true || parent&.pivot_button == true

      if applies?(xf, parent, :apply_alignment) then
        alignment = xf.alignment || parent&.alignment
        result.alignment = alignment unless blank?(alignment)
        result.apply_alignment = !result.alignment.nil?
      end

      if applies?(xf, parent, :apply_protection) then
        protection = canonical_protection(xf.protection || parent&.protection)
        result.protection = protection
        result.apply_protection = !protection.nil?
      end

      result
    end

    def xf_component(xf, parent, field, default)
      apply_field = XF_FIELDS[field]
      if parent.nil? && xf.public_send(apply_field) == false then
        default
      elsif parent && xf.public_send(apply_field) == false then
        parent.public_send(field) || default
      else
        xf.public_send(field) || parent&.public_send(field) || default
      end
    end

    def applies?(xf, parent, apply_field)
      value = xf.public_send(apply_field)
      value = parent.public_send(apply_field) if value.nil? && parent
      value != false
    end

    def canonical_protection(protection)
      return nil if protection.nil?
      locked = boolean_value(protection.locked) ? true : nil
      hidden = boolean_value(protection.hidden) ? true : nil
      return nil if locked.nil? && hidden.nil?
      Protection.new(:locked => locked, :hidden => hidden)
    end

    def rewrite_references(style_size, cell_size, dxf_size, font_size)
      @styles.cell_styles.each { |style| style.xf_id = mapped_id(:style_xfs, style.xf_id, style_size) }

      @workbook.worksheets.each do |worksheet|
        next unless worksheet.respond_to?(:sheet_data)
        rewrite_worksheet(worksheet, cell_size, dxf_size, font_size)
      end

      rewrite_shared_strings(font_size)
    end

    def rewrite_worksheet(worksheet, cell_size, dxf_size, font_size)
      worksheet.cols&.each { |col| col.style_index = mapped_id(:cell_xfs, col.style_index, cell_size) }
      worksheet.sheet_data&.rows&.each do |row|
        next if row.nil?
        row.style_index = mapped_id(:cell_xfs, row.style_index, cell_size)
        row.cells.each do |cell|
          next if cell.nil?
          cell.style_index = mapped_id(:cell_xfs, cell.style_index, cell_size)
          rewrite_rich_text(cell.is, font_size)
        end
      end

      Array(worksheet.conditional_formatting).each do |formatting|
        next if formatting.nil?
        if formatting.is_a?(RubyXL::ConditionalFormattingRule)
          formatting.dxf_id = mapped_id(:dxfs, formatting.dxf_id, dxf_size)
        else
          Array(formatting.cf_rule).each { |rule| rule.dxf_id = mapped_id(:dxfs, rule.dxf_id, dxf_size) }
        end
      end

      rewrite_auto_filter(worksheet.auto_filter, dxf_size)
      rewrite_scenarios(worksheet.scenarios, cell_size)
      rewrite_phonetic(worksheet.phonetic_pr, font_size)
    end

    def rewrite_auto_filter(auto_filter, dxf_size)
      return if auto_filter.nil?
      Array(auto_filter.filter_column).each do |column|
        next if column.nil?
        if column.color_filter && column.color_filter.dxf_id
          column.color_filter.dxf_id = map_dxf_string(column.color_filter.dxf_id, dxf_size)
        end
      end
      Array(auto_filter.sort_state&.sort_condition).each do |condition|
        condition.dxf_id = mapped_id(:dxfs, condition.dxf_id, dxf_size) unless condition.dxf_id.nil?
      end
    end

    def rewrite_scenarios(scenarios, cell_size)
      Array(scenarios).each do |scenario|
        next if scenario.nil?
        Array(scenario).each do |input_cells|
          next if input_cells.nil?
          Array(input_cells).each do |input_cell|
            input_cell.num_fmt_id = mapped_id(:cell_xfs, input_cell.num_fmt_id, cell_size) unless input_cell.num_fmt_id.nil?
          end
        end
      end
    end

    def map_dxf_string(value, size)
      return value if value.nil?
      value =~ /\A\d+\Z/ ? mapped_id(:dxfs, value.to_i, size).to_s : value
    end

    def rewrite_shared_strings(font_size)
      shared = @workbook.shared_strings_container
      return if shared.nil?
      shared.strings.each do |rich_text|
        next if rich_text.nil?
        rewrite_rich_text(rich_text, font_size)
      end
    end

    def rewrite_rich_text(rich_text, font_size)
      return if rich_text.nil?
      rewrite_phonetic(rich_text.phonetic_pr, font_size)
      Array(rich_text.r).each { |run| rewrite_phonetic(run&.r_pr&.phonetic_pr, font_size) }
    end

    def rewrite_phonetic(phonetic, font_size)
      return if phonetic.nil?
      phonetic.font_id = mapped_id(:fonts, phonetic.font_id, font_size)
    end

    def mapped_id(name, id, valid_size = nil)
      return id if valid_size && !id.nil? && (id < 0 || id >= valid_size)
      @maps[name].fetch(id.to_i, id.to_i)
    end

    def identity_mapping(ids)
      ids.uniq.each { |id| @maps[:num_fmts][id] ||= id }
    end

    def normalize_format(code)
      code.to_s.downcase == 'general' ? 'General' : code
    end

    def boolean_value(value)
      value == true
    end

    def semantic(object)
      return nil if object.nil?
      [ object.class.name, semantic_attributes(object), semantic_children(object) ]
    end

    def semantic_attributes(object)
      object.class.obtain_class_variable(:@@ooxml_attributes).values.map { |params|
        value = object.public_send(params[:accessor])
        canonical_attribute(value, params[:attr_type])
      }
    end

    def semantic_children(object)
      object.class.obtain_class_variable(:@@ooxml_child_nodes).values.map { |params|
        child = object.public_send(params[:accessor])
        if params[:is_array]
          Array(child).map { |item| semantic(item) }
        else
          semantic_special_child(child, params)
        end
      }
    end

    def semantic_special_child(child, params = nil)
      return nil if child.nil?
      case child
      when Color then color_semantic(child)
      when BooleanValue then boolean_node_semantic(child, params)
      when StringValue then value_node_semantic(child, params, :string)
      when IntegerValue then value_node_semantic(child, params, :int)
      when FloatValue then value_node_semantic(child, params, :double)
      else semantic(child)
      end
    end

    def boolean_node_semantic(node, params)
      return nil if node.val == false
      [ :bool, true ] if node.val.nil? || node.val == true
    end

    def value_node_semantic(node, params, type)
      return nil if node.val.nil?
      return nil if type == :string && node.val == ''
      value = type == :string ? node.val.to_s : node.val.public_send(type == :int ? :to_i : :to_f)
      [ type, value ]
    end

    def canonical_attribute(value, type)
      return nil if value.nil?
      case type
      when :bool then value == true
      when :int, :uint then value.to_i
      when :double then value.to_f
      else value.to_s
      end
    end

    def color_semantic(color)
      if color.auto == true
        [ Color.name, :auto, true, color.tint.to_f ]
      elsif color.theme && @preserve_theme_colors
        # Keep the color dynamic even if the current theme resolves it to an RGB value.
        [ Color.name, :theme, color.theme.to_i, color.tint.to_f ]
      elsif color.theme
        rgb = color.get_rgb(@workbook).to_s.upcase
        [ Color.name, :rgb, rgb, 0.0 ]
      elsif color.indexed
        [ Color.name, :indexed, color.indexed.to_i, color.tint.to_f ]
      elsif color.rgb
        [ Color.name, :rgb, color.rgb.to_s.upcase, color.tint.to_f ]
      else
        [ Color.name, :empty, color.tint.to_f ]
      end
    end

    def dxf_semantic(dxf)
      [
        semantic(dxf.font),
        dxf_number_format(dxf.num_fmt),
        dxf_fill(dxf.fill),
        blank?(dxf.alignment) ? nil : semantic(dxf.alignment),
        blank?(dxf.border) ? nil : border_semantic(dxf.border),
        canonical_protection(dxf.protection) ? semantic(canonical_protection(dxf.protection)) : nil
      ]
    end

    def dxf_number_format(format)
      format.nil? ? nil : [ :num_fmt, normalize_format(format.format_code).to_s ]
    end

    def canonical_dxf(dxf)
      canonical_font(dxf.font) if dxf.font
      canonical_fill(dxf.fill) if dxf.fill
      canonical_border(dxf.border) if dxf.border
    end

    def dxf_fill(fill)
      return nil if fill.nil?
      return nil if fill.pattern_fill && blank?(fill.pattern_fill)
      fill_semantic(fill)
    end

    def fill_semantic(fill)
      return semantic(fill) unless fill.pattern_fill
      pattern = fill.pattern_fill
      bg_color = pattern.pattern_type == 'solid' ? nil : semantic_special_child(pattern.bg_color)
      [
        Fill.name,
        [],
        [ [
          PatternFill.name,
          semantic_attributes(pattern),
          [ semantic_special_child(pattern.fg_color), bg_color ]
        ], nil ]
      ]
    end

    def canonical_fill(fill)
      return unless fill.pattern_fill
      [ fill.pattern_fill.fg_color, fill.pattern_fill.bg_color ].each { |color| canonical_color(color) }
    end

    def canonical_font(font)
      canonical_color(font.color)
    end

    def canonical_border(border)
      border.class.obtain_class_variable(:@@ooxml_child_nodes).values.each do |params|
        edge = border.public_send(params[:accessor])
        canonical_color(edge.color) if edge
      end
    end

    def canonical_color(color)
      return if color.nil? || @preserve_theme_colors || color.theme.nil?
      rgb = color.get_rgb(@workbook).to_s
      return if rgb.empty?
      color.theme = nil
      color.tint = nil
      color.rgb = rgb
    end

    def border_semantic(border)
      return semantic(border) if blank?(border)
      attrs = semantic_attributes(border)
      edges = border.class.obtain_class_variable(:@@ooxml_child_nodes).values.map do |params|
        edge = border.public_send(params[:accessor])
        edge_semantic(edge)
      end
      [ Border.name, attrs, edges ]
    end

    def edge_semantic(edge)
      return nil if edge.nil?
      style = edge.style || 'none'
      return nil if style == 'none'
      [
        BorderEdge.name,
        semantic_attributes(edge),
        [ semantic_special_child(edge.color) ]
      ]
    end

    def blank?(object)
      return true if object.nil?
      semantic(object) == semantic(object.class.new)
    end
  end
end
