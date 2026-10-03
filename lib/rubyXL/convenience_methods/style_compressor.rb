# frozen_string_literal: true

require 'set'
require 'nokogiri'
require 'rubyXL/convenience_methods/color'

module RubyXL
  # Merges stylesheet entries carrying identical visual semantics
  # (custom numFmts, fonts, fills, borders, cellStyleXfs, cellXfs and dxfs)
  # and rewrites every reference to the renumbered entries.
  #
  # Unlike plain XML-string deduplication, comparison is performed on the
  # resolved meaning of each entry:
  # * cellXfs are evaluated together with the cellStyleXfs they inherit
  #   from (via +xfId+) and their +apply*+ flags;
  # * custom number formats are matched by format code regardless of the
  #   local numFmtId, while built-in IDs are kept;
  # * theme, indexed and RGB colors are treated as distinct representations.
  #
  # In the default +:preserve_theme+ mode, two colors that happen to render
  # alike under the current theme are never merged: a theme reference keeps
  # depending on the workbook theme while an explicit RGB stays fixed.
  # Passing +:resolve_theme+ resolves theme and legacy indexed colors to RGB
  # before comparison, allowing such entries to merge at the cost of theme
  # dependency.
  module StyleCompressor
    PRESERVE_THEME = :preserve_theme
    RESOLVE_THEME  = :resolve_theme

    # ECMA-376 legacy palette (indexedColors), values for indexes 8..63.
    # Indexes 0..7 are aliases for 8..15; 64 (system background) and
    # 65 (system foreground) cannot be resolved without runtime settings.
    DEFAULT_INDEXED_COLORS = %w[
      000000 FFFFFF FF0000 00FF00 0000FF FFFF00 FF00FF 00FFFF
      000000 FFFFFF FF0000 00FF00 0000FF FFFF00 FF00FF 00FFFF
      800000 008000 000080 808000 800080 008080 C0C0C0 808080
      9999FF 993366 FFFFFF CCFFFF 660066 FF8080 0066CC CCCCFF
      000080 FF00FF FFFF00 00FFFF 800080 800000 008080 0000FF
      00CCFF CCFFFF CCFFCC FFFF99 99CCFF FF99CC CC99FF FFCC99
      3366FF 33CCCC 99CC00 FFCC00 FF9900 FF6666 666699 969696
      003366 339966 003300 333300 993300 993366 333399 333333
    ].freeze

    FIRST_CUSTOM_NUMFMT_ID = 164

    def self.compress(workbook, mode = PRESERVE_THEME)
      unless [PRESERVE_THEME, RESOLVE_THEME].include?(mode)
        raise ArgumentError, "unknown compression mode #{mode.inspect} " \
                            "(expected :preserve_theme or :resolve_theme)"
      end

      Compressor.new(workbook, mode).compress
    end

    attr_reader :workbook, :mode, :mappings, :stats

    def initialize(workbook, mode)
      @workbook = workbook
      @mode     = mode
      @mappings = {}
      @stats    = {}
    end

    def compress
      stylesheet = workbook.stylesheet ||= RubyXL::Stylesheet.default
      before     = snapshot_counts(stylesheet);

      canonicalize_number_formats(stylesheet)
      canonicalize_simple_collections(stylesheet)
      canonicalize_style_xfs(stylesheet)
      canonicalize_cell_xfs(stylesheet)
      canonicalize_dxfs(stylesheet)

      rewrite_references(stylesheet)

      stylesheet.instance_variable_set(:@format_hash, nil)

      @stats = build_stats(before, snapshot_counts(stylesheet))
      { :mappings => @mappings, :stats => @stats }
    end

    private

    def resolve_colors?
      mode == RESOLVE_THEME
    end

    # Fully detached copy of a parsed object graph.
    def deep_copy(obj)
      Marshal.load(Marshal.dump(obj))
    end

    # Value that compares equal exactly for objects with identical style
    # semantics. Colors receive dedicated handling; every other OOXML
    # object is reduced to its class, attributes and child nodes.
    def semantic_key(obj)
      case obj
      when nil then nil
      when RubyXL::Color then color_key(obj)
      when OOXMLObject
        attrs = obj.class.obtain_class_variable(:@@ooxml_attributes).values
        nodes = obj.class.obtain_class_variable(:@@ooxml_child_nodes).values

        attr_keys = attrs.map { |v|
          val = obj.send(v[:accessor])
          val = val.to_r if val.is_a?(Float)
          [v[:accessor], val]
        }
        node_keys = nodes.map { |v|
          val = obj.send(v[:accessor])
          key = val.is_a?(Array) ? val.map { |item| semantic_key(item) } : semantic_key(val)
          [v[:accessor], key]
        }

        [obj.class, attr_keys, node_keys]
      else obj
      end
    end

    def color_key(color)
      if resolve_colors?
        rgb = resolve_color(color)
        return [:rgb, rgb, 0r] if rgb
      end

      if color.rgb
        [:rgb, color.rgb.to_s.upcase, tint_rational(color)]
      elsif color.theme
        [:theme, color.theme, tint_rational(color)]
      elsif color.indexed
        idx = color.indexed
        # Legacy indexed aliases (0..7 duplicate 8..15) share one meaning.
        idx += 8 if (0..7).include?(idx)
        [:indexed, idx]
      elsif color.auto == true
        [:auto]
      else
        [:unspecified]
      end
    end

    def tint_rational(color)
      tint = color.tint
      (tint.nil? || tint == 0.0) ? 0r : tint.to_r
    end

    def resolve_indexed(index, stylesheet)
      custom = stylesheet.colors&.indexed_colors
      return custom[index].rgb&.to_s&.upcase if custom && index < custom.size

      if (8..63).include?(index) then DEFAULT_INDEXED_COLORS[index - 8]
      elsif (0..7).include?(index) then DEFAULT_INDEXED_COLORS[index]
      end
      # 64 and 65 (system foreground/background) stay unresolved.
    end

    # Resolve any color representation to a plain RGB string, applying the
    # tint so the result is the actual rendered color.
    def resolve_color(color)
      rgb = if color.rgb then color.rgb.to_s
            elsif color.theme then color.get_rgb(workbook)
            elsif color.indexed then resolve_indexed(color.indexed, workbook.stylesheet)
            end
      return nil if rgb.nil?

      rgb = rgb.upcase
      return rgb if color.tint.nil? || color.tint == 0.0 || rgb.length == 8

      RgbColor.parse(rgb).to_hls.apply_tint(color.tint).to_rgb.to_s.upcase
    end

    # Within a copied object graph, turn every resolvable color into an RGB
    # one (used only in :resolve_theme mode).
    def canonicalize_colors(obj)
      return obj unless resolve_colors?

      walk = lambda do |node|
        case node
        when RubyXL::Color
          rgb = resolve_color(node)
          if rgb && !(node.rgb && node.rgb.to_s.upcase == rgb)
            node.rgb     = rgb
            node.theme   = nil
            node.indexed = nil
            node.tint    = nil
          end
        when OOXMLObject
          each_child_object(node) { |child| walk.call(child) }
        end
      end

      walk.call(obj)
      obj
    end

    def each_child_object(obj)
      obj.class.obtain_class_variable(:@@ooxml_child_nodes).each_value do |v|
        value = obj.send(v[:accessor])
        if value.is_a?(Array)
          value.each { |item| yield(item) if item.is_a?(OOXMLObject) }
        elsif value.is_a?(OOXMLObject)
          yield(value)
        end
      end
    end

    # Group a homogeneous collection by semantic key, keeping the first
    # occurrence of each group as the canonical representative. Indices
    # referenced by raw (unparsed) XML parts are anchored so the renumbering
    # cannot leave dangling references there. Returns old-index => new-index.
    def canonicalize_collection(collection, anchors)
      representative = [] # [{ :key, :value }] in first-occurrence order
      position_by_old = {}

      collection.each_with_index do |entry, index|
        canonical = canonicalize_colors(deep_copy(entry))
        key = entry.is_a?(RubyXL::Color) ? color_key(entry) : semantic_key(canonical)
        position = representative.index { |rep| rep[:key] == key }
        if position.nil?
          position = representative.size
          representative << { :key => key, :value => canonical }
        end
        position_by_old[index] = position
      end

      values, new_by_position = arrange_representatives(representative, position_by_old, anchors, collection.size)
      collection.replace(values)

      position_by_old.each_with_object({}) { |(old_index, position), map|
        map[old_index] = new_by_position[position]
      }
    end

    # Lay representatives out into final indexes. Representatives whose
    # group contains an anchored index stay at that index; the rest fill the
    # remaining slots in first-occurrence order.
    def arrange_representatives(representative, position_by_old, anchors, original_size)
      anchor_old_by_position = {}
      anchors.each do |old_index|
        position = position_by_old[old_index]
        next if position.nil?
        previous = anchor_old_by_position[position]
        anchor_old_by_position[position] = previous.nil? ? old_index : [previous, old_index].min
      end

      values = []
      new_by_position = {}

      anchor_old_by_position.each do |position, old_index|
        values[old_index] = canonicalize_colors(deep_copy(representative[position]))
        new_by_position[position] = old_index
      end

      representative.each_with_index do |rep, position|
        next if anchor_old_by_position.key?(position)
        target = 0
        target += 1 until values[target].nil?
        values[target] = rep[:value]
        new_by_position[position] = target
      end

      [values.compact, new_by_position]
    end

    def canonicalize_simple_collections(stylesheet)
      anchors = raw_referenced_indices
      @mappings[:fonts] = canonicalize_collection(stylesheet.fonts, anchors[:font_id] || [])
      @mappings[:fills] = canonicalize_collection(stylesheet.fills, anchors[:fill_id] || [])
      @mappings[:borders] = canonicalize_collection(stylesheet.borders, anchors[:border_id] || [])
    end

    # Match custom number formats by format code (IDs are local to the
    # workbook); codes equal to a built-in collapse onto the built-in ID.
    def canonicalize_number_formats(stylesheet)
      map = {}
      builtins = NumberFormats::DEFAULT_NUMBER_FORMATS
      codes_in_order = []

      (stylesheet.number_formats || []).each do |numfmt|
        builtin = builtins.find { |fmt| fmt.format_code == numfmt.format_code }
        if builtin
          map[numfmt.num_fmt_id] = builtin.num_fmt_id
        else
          codes_in_order << numfmt.format_code unless codes_in_order.include?(numfmt.format_code)
        end
      end

      codes_in_order.each_with_index do |code, i|
        new_id = FIRST_CUSTOM_NUMFMT_ID + i
        (stylesheet.number_formats || []).each do |numfmt|
          map[numfmt.num_fmt_id] = new_id if numfmt.format_code == code
        end
      end

      if codes_in_order.empty?
        stylesheet.number_formats = nil
      else
        stylesheet.number_formats = NumberFormats.new(:_ => codes_in_order.map.with_index { |code, i|
          NumberFormat.new(:num_fmt_id => FIRST_CUSTOM_NUMFMT_ID + i, :format_code => code)
        })
      end

      @mappings[:num_fmts] = map
    end

    def canonical_numfmt_id(id)
      id.nil? ? id : (@mappings[:num_fmts][id] || id)
    end

    # Effective ID component of a cellXf, after inheritance:
    # * with a referenced cellStyleXf (xfId present), only an explicit
    #   apply*=true overrides the style definition; apply*=false or an
    #   omitted flag inherits from the style (explicit zero IDs in the XML
    #   are mere placeholders in that case);
    # * without xfId the XF stands alone, so its own ID is used (zero is a
    #   real reference to the default font/fill/border/format).
    def effective_id(xf, base_xf, attr, apply_attr, default = 0)
      if !xf.xf_id.nil? && xf.send(apply_attr) != true
        return (!base_xf.nil? && base_xf.send(attr)) || default
      end
      own = xf.send(attr)
      own.nil? ? ((!base_xf.nil? && base_xf.send(attr)) || default) : own
    end

    def effective_node(xf, base_xf, attr, apply_attr)
      has_base = !xf.xf_id.nil?
      if has_base && xf.send(apply_attr) != true
        return base_xf&.send(attr)
      end
      own = xf.send(attr)
      own.nil? ? base_xf&.send(attr) : own
    end

    def base_style_xf(stylesheet, xf)
      style_xfs = stylesheet.cell_style_xfs
      return nil if style_xfs.nil? || style_xfs.empty?
      style_xfs[xf.xf_id || 0]
    end

    # cellStyleXfs entries are standalone style definitions; their apply
    # flags carry no meaning (ECMA-376) and are excluded from comparison.
    def canonicalize_style_xfs(stylesheet)
      collection = stylesheet.cell_style_xfs
      if collection.nil? || collection.empty?
        @mappings[:cell_style_xfs] = {}
        return
      end

      representatives = []
      position_by_old = {}

      collection.each_with_index do |xf, index|
        copy = strip_apply_flags(deep_copy(xf))
        remap_simple_xf_ids(copy)
        key = xf_semantic_key(copy)
        position = representatives.index { |rep| rep[:key] == key }
        if position.nil?
          position = representatives.size
          representatives << { :key => key, :value => copy }
        end
        position_by_old[index] = position
      end

      collection.replace(representatives.map { |rep| rep[:value] })

      map = position_by_old.each_with_object({}) { |(old_index, position), h| h[old_index] = position }
      @mappings[:cell_style_xfs] = map

      # <cellStyles> entries point at cellStyleXfs via +xfId+.
      stylesheet.cell_styles&.each do |cell_style|
        cell_style.xf_id = map[cell_style.xf_id] unless cell_style.xf_id.nil?
      end
    end

    def strip_apply_flags(xf)
      %i[apply_number_format apply_font apply_fill apply_border apply_alignment apply_protection].each do |attr|
        xf.send("#{attr}=", nil)
      end
      xf
    end

    def remap_simple_xf_ids(xf)
      font_map   = @mappings[:fonts]
      fill_map   = @mappings[:fills]
      border_map = @mappings[:borders]
      xf.font_id   = font_map[xf.font_id]   unless xf.font_id.nil?   || font_map.nil?
      xf.fill_id   = fill_map[xf.fill_id]   unless xf.fill_id.nil?   || fill_map.nil?
      xf.border_id = border_map[xf.border_id] unless xf.border_id.nil? || border_map.nil?
      xf.num_fmt_id = canonical_numfmt_id(xf.num_fmt_id) unless xf.num_fmt_id.nil?
      xf
    end

    def xf_semantic_key(xf)
      [xf.num_fmt_id || 0, xf.font_id || 0, xf.fill_id || 0, xf.border_id || 0,
       semantic_key(xf.alignment), semantic_key(xf.protection)]
    end

    def canonicalize_cell_xfs(stylesheet)
      collection = stylesheet.cell_xfs
      if collection.nil? || collection.empty?
        stylesheet.cell_xfs = CellXFs.default
        @mappings[:cell_xfs] = {}
        return
      end

      style_map = @mappings[:cell_style_xfs]
      representatives = []
      position_by_old = {}

      collection.each_with_index do |xf, index|
        base_xf = base_style_xf(stylesheet, xf)
        canonical_xf, key = build_canonical_cell_xf(xf, base_xf, style_map)
        position = representatives.index { |rep| rep[:key] == key }
        if position.nil?
          position = representatives.size
          representatives << { :key => key, :value => canonical_xf }
        end
        position_by_old[index] = position
      end

      anchors = (raw_referenced_indices[:style_index] || [])
      values, new_by_position = arrange_representatives(representatives, position_by_old,
                                                        anchors, collection.size)
      collection.replace(values)

      @mappings[:cell_xfs] = position_by_old.each_with_object({}) { |(old_index, position), h|
        h[old_index] = new_by_position[position]
      }
    end

    def build_canonical_cell_xf(xf, base_xf, style_map)
      numfmt_id = canonical_numfmt_id(effective_id(xf, base_xf, :num_fmt_id, :apply_number_format))
      font_id   = @mappings[:fonts][effective_id(xf, base_xf, :font_id, :apply_font)] || 0
      fill_id   = @mappings[:fills][effective_id(xf, base_xf, :fill_id, :apply_fill)] || 0
      border_id = @mappings[:borders][effective_id(xf, base_xf, :border_id, :apply_border)] || 0
      alignment  = deep_copy(effective_node(xf, base_xf, :alignment, :apply_alignment))
      protection = deep_copy(effective_node(xf, base_xf, :protection, :apply_protection))

      xf_id = if xf.xf_id.nil? then nil
              elsif style_map.nil? then xf.xf_id
              else style_map.fetch(xf.xf_id, xf.xf_id)
              end

      new_xf = XF.new
      new_xf.num_fmt_id = numfmt_id
      new_xf.font_id    = font_id
      new_xf.fill_id    = fill_id
      new_xf.border_id  = border_id
      new_xf.xf_id      = xf_id
      new_xf.quote_prefix = true if xf.quote_prefix == true
      new_xf.pivot_button = true if xf.pivot_button == true
      new_xf.apply_number_format = true
      new_xf.apply_font          = true
      new_xf.apply_fill          = true
      new_xf.apply_border        = true
      new_xf.apply_alignment     = true unless alignment.nil?
      new_xf.apply_protection    = true unless protection.nil?
      new_xf.alignment  = alignment
      new_xf.protection = protection

      key = [:cell_xf, xf_id, numfmt_id, font_id, fill_id, border_id,
             semantic_key(alignment), semantic_key(protection),
             xf.quote_prefix == true, xf.pivot_button == true]
      [new_xf, key]
    end

    # Differential styles are standalone partial formats; compare them by
    # their own content (their embedded numFmt ID is canonicalized too).
    def canonicalize_dxfs(stylesheet)
      collection = stylesheet.dxfs
      if collection.nil? || collection.empty?
        @mappings[:dxfs] = {}
        return
      end

      representatives = []
      position_by_old = {}

      collection.each_with_index do |dxf, index|
        copy = canonicalize_colors(deep_copy(dxf))
        if copy.num_fmt && !copy.num_fmt.num_fmt_id.nil?
          copy.num_fmt.num_fmt_id = canonical_numfmt_id(copy.num_fmt.num_fmt_id)
        end
        key = [:dxf, semantic_key(copy)]
        position = representatives.index { |rep| rep[:key] == key }
        if position.nil?
          position = representatives.size
          representatives << { :key => key, :value => copy }
        end
        position_by_old[index] = position
      end

      anchors = (raw_referenced_indices[:dxf_id] || [])
      values, new_by_position = arrange_representatives(representatives, position_by_old,
                                                        anchors, collection.size)
      if values.empty?
        stylesheet.dxfs = nil
      else
        collection.replace(values)
      end

      @mappings[:dxfs] = position_by_old.each_with_object({}) { |(old_index, position), h|
        h[old_index] = new_by_position[position]
      }
    end

    # ------------------------------------------------------------------
    # Reference rewriting across the modeled parts of the workbook.
    # ------------------------------------------------------------------

    def rewrite_references(stylesheet)
      cell_xf_map = @mappings[:cell_xfs]
      dxf_map     = @mappings[:dxfs]
      font_map    = @mappings[:fonts]

      rewrite_shared_string_fonts(workbook.shared_strings_container, font_map)

      workbook.worksheets.to_a.each do |worksheet|
        next if worksheet.nil?
        rewrite_worksheet(worksheet, cell_xf_map, dxf_map, font_map)
      end
    end

    def remap_id(id, map)
      return id if id.nil? || map.nil? || map.empty?
      map.key?(id) ? map[id] : id
    end

    def rewrite_worksheet(worksheet, cell_xf_map, dxf_map, font_map)
      if worksheet.phonetic_pr && !worksheet.phonetic_pr.font_id.nil?
        worksheet.phonetic_pr.font_id = remap_id(worksheet.phonetic_pr.font_id, font_map)
      end

      worksheet.cols&.each do |range|
        range.style_index = remap_id(range.style_index, cell_xf_map) unless range.style_index.nil?
      end

      rows = worksheet.sheet_data&.rows
      rows&.each do |row|
        next if row.nil?
        row.style_index = remap_id(row.style_index, cell_xf_map) unless row.style_index.nil?
        row.cells.each do |cell|
          next if cell.nil?
          cell.style_index = remap_id(cell.style_index, cell_xf_map) unless cell.style_index.nil?
          rewrite_rich_text_fonts(cell.is, font_map) if cell.is
        end
      end

      worksheet.conditional_formatting&.each do |cf|
        cf.cf_rule&.each { |rule| rule.dxf_id = remap_id(rule.dxf_id, dxf_map) unless rule.dxf_id.nil? }
      end

      rewrite_autofilter(worksheet.auto_filter, dxf_map)
      rewrite_sort_state(worksheet.sort_state, dxf_map)
    end

    def rewrite_autofilter(auto_filter, dxf_map)
      return if auto_filter.nil?
      columns = auto_filter.filter_column
      [columns].flatten.compact.each do |column|
        next unless column.respond_to?(:color_filter)
        color_filter = column.color_filter
        if color_filter && !color_filter.dxf_id.nil? && color_filter.dxf_id != "" && color_filter.dxf_id =~ /\A\d+\Z/
          color_filter.dxf_id = remap_id(color_filter.dxf_id.to_i, dxf_map).to_s
        end
      end
      rewrite_sort_state(auto_filter.sort_state, dxf_map)
    end

    def rewrite_sort_state(sort_state, dxf_map)
      return if sort_state.nil?
      sort_state.sort_condition&.each do |condition|
        condition.dxf_id = remap_id(condition.dxf_id, dxf_map) unless condition.dxf_id.nil?
      end
    end

    def rewrite_shared_string_fonts(shared_strings, font_map)
      return if shared_strings.nil?
      shared_strings.strings&.each { |rich_text| rewrite_rich_text_fonts(rich_text, font_map) }
    end

    def rewrite_rich_text_fonts(rich_text, font_map)
      phonetic = rich_text.phonetic_pr
      if phonetic && !phonetic.font_id.nil?
        phonetic.font_id = remap_id(phonetic.font_id, font_map)
      end
    end

    # Style indexes used by parts RubyXL does not model into objects
    # (tables, pivot tables, charts). Such indexes must stay valid after
    # renumbering, so entries they reference are pinned to their old slot.
    def raw_referenced_indices
      @raw_referenced_indices ||= begin
        found = Hash.new { |h, k| h[k] = [] }
        each_raw_xml_part do |xml|
          scan_raw_style_references(xml, found)
        end
        found.each_value(&:uniq!)
        found
      end
    end

    def each_raw_xml_part
      root = workbook.root
      return unless root && root.respond_to?(:rels_hash)

      visited = Set.new
      walk = lambda do |object|
        return if object.nil? || visited.include?(object.object_id)
        visited << object.object_id

        if object.is_a?(RubyXL::GenericStorageObject) && object.data.is_a?(String)
          yield(object.data)
        end

        if object.respond_to?(:generic_storage)
          Array(object.generic_storage).each { |child| walk.call(child) }
        end
        if object.respond_to?(:related_objects)
          Array(object.related_objects).each { |child| walk.call(child) }
        end
      end

      walk.call(root)
    end

    def scan_raw_style_references(xml, found)
      document = Nokogiri::XML(xml, &:strict)
    rescue Nokogiri::XML::SyntaxError
      return
    else
      document.traverse do |node|
        next unless node.element?
        collect_raw_attribute(node, "s", found[:style_index])
        collect_raw_attribute(node, "dxfId", found[:dxf_id])
        collect_raw_attribute(node, "fontId", found[:font_id])
        collect_raw_attribute(node, "fillId", found[:fill_id])
        collect_raw_attribute(node, "borderId", found[:border_id])
      end
    end

    def collect_raw_attribute(node, name, target)
      value = node.attribute(name)
      return if value.nil?
      integer = begin
                  Integer(value.value)
                rescue ArgumentError, TypeError
                  nil
                end
      target << integer unless integer.nil?
    end

    def snapshot_counts(stylesheet)
      {
        :num_fmts       => (stylesheet.number_formats || []).size,
        :fonts          => (stylesheet.fonts || []).size,
        :fills          => (stylesheet.fills || []).size,
        :borders        => (stylesheet.borders || []).size,
        :cell_style_xfs => (stylesheet.cell_style_xfs || []).size,
        :cell_xfs       => (stylesheet.cell_xfs || []).size,
        :dxfs           => (stylesheet.dxfs || []).size
      }
    end

    def build_stats(before, after)
      counts = before.each_with_object({}) do |(key, old_count), result|
        new_count = after[key]
        result[key] = { :before => old_count, :after => new_count, :removed => old_count - new_count }
      end
      counts[:total] = {
        :before  => before.values.sum,
        :after   => after.values.sum,
        :removed => before.values.sum - after.values.sum
      }
      counts
    end
    # Instance carrier for the (module-organized) compression logic.
    class Compressor
      include StyleCompressor
    end
  end
end
