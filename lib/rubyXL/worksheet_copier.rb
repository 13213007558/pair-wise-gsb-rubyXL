require 'pathname'
require 'rubyXL/objects/ooxml_object'

module RubyXL
  # Raised when a cross-workbook worksheet copy is aborted because the worksheet
  # (transitively) depends on part types that the copier does not know how to migrate.
  # The full dependency closure is available via +plan+, so the caller can inspect
  # exactly which parts blocked the copy before deciding how to proceed.
  class UnsupportedPartsError < StandardError
    attr_reader :plan

    def initialize(plan)
      @plan = plan
      super("Cannot copy worksheet '#{plan.source_sheet_name}': " +
            "the dependency closure contains unsupported parts.\n#{plan}")
    end
  end

  # Raised when a cross-workbook worksheet copy is aborted because the worksheet
  # references other sheets of the source workbook and the caller did not allow
  # rewriting such references as external links.
  class ExternalReferenceError < StandardError
    attr_reader :sheet_names

    def initialize(sheet_names, source_label)
      @sheet_names = sheet_names
      super("Worksheet references other sheets of the source workbook: #{sheet_names.join(', ')}. " +
            "Pass :external_references => :keep to rewrite such references as external links to '#{source_label}'.")
    end
  end

  # Describes every part a worksheet (transitively) depends on, so the caller can
  # review the dependency closure before deciding whether a copy should execute.
  class WorksheetCopyPlan
    Part = Struct.new(:owner_path, :rel_id, :rel_type, :target, :kind, :supported, :note) do
      def supported?
        supported
      end

      def to_s
        line = "  [#{supported ? 'supported' : 'UNSUPPORTED'}] #{kind}: #{target}"
        line << " (referenced by #{owner_path}##{rel_id})" if owner_path
        line << " -- #{note}" if note
        line
      end
    end

    attr_reader :source_sheet_name, :parts

    def initialize(source_sheet_name, parts)
      @source_sheet_name = source_sheet_name
      @parts = parts
    end

    def unsupported_parts
      parts.reject(&:supported?)
    end

    def supported?
      unsupported_parts.empty?
    end

    def to_s
      "Dependency closure for worksheet '#{source_sheet_name}':\n#{parts.map(&:to_s).join("\n")}"
    end
  end

  # Copies a worksheet (with everything it depends on: cell data, styles, shared strings,
  # comments, images, hyperlinks, printer settings) from one workbook into another.
  #
  # Relationship IDs and part URIs are re-assigned inside the target package; shared
  # resources (styles, shared strings, images) are reused by actual content, not by name.
  # References that point at the copied sheet itself are remapped to the new sheet;
  # references to other sheets of the source workbook are either rewritten as external
  # links or rejected, at the caller's discretion.
  class WorksheetCopier
    EXTERNAL_REFERENCE_BEHAVIORS = [ :reject, :keep ].freeze
    UNSUPPORTED_PART_BEHAVIORS   = [ :reject, :skip ].freeze

    RELATIONSHIPS_NAMESPACE = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'.freeze
    SHEET_PARTS_DIR = Pathname('/xl/worksheets')

    IMAGE_CONTENT_TYPES = {
      'png'  => 'image/png',
      'jpg'  => 'image/jpeg',
      'jpeg' => 'image/jpeg',
      'gif'  => 'image/gif',
      'bmp'  => 'image/bmp',
      'tif'  => 'image/tiff',
      'tiff' => 'image/tiff',
      'emf'  => 'image/x-emf',
      'wmf'  => 'image/x-wmf',
      'svg'  => 'image/svg+xml'
    }.freeze

    # Matches either a double-quoted string literal (captured, left untouched), or
    # a sheet reference token (quoted 'Sheet Name'! or bare Sheet1!) followed by '!'.
    SHEET_REFERENCE = /("(?:[^"]|"")*")|(?<![\]\w.!])(?:'((?:[^']|'')*)'|([\w.]+))!/

    attr_reader :target_workbook, :source_worksheet

    def self.resolve_source(source, sheet)
      case source
      when RubyXL::Worksheet then source
      when RubyXL::Workbook
        raise ArgumentError, 'worksheet name or index is required when the source is a workbook' if sheet.nil?
        worksheet = source[sheet]
        raise ArgumentError, "worksheet #{sheet.inspect} not found in the source workbook" if worksheet.nil?
        worksheet
      else
        raise ArgumentError, "cannot copy a worksheet from #{source.inspect}"
      end
    end

    def initialize(target_workbook, source_worksheet, options = {})
      @target_workbook  = target_workbook
      @source_worksheet = source_worksheet
      @requested_name   = options[:as]
      @external_references_behavior = options.fetch(:external_references, :reject)
      @unsupported_parts_behavior   = options.fetch(:unsupported_parts, :reject)
    end

    # The dependency closure of the source worksheet: every part that would need to be
    # migrated, marked as supported or unsupported. Computed without changing anything.
    def plan
      @plan ||= build_plan
    end

    # Perform the copy and return the newly created worksheet.
    def execute
      validate!

      if unsupported_parts_behavior == :reject && !plan.supported?
        raise RubyXL::UnsupportedPartsError, plan
      end

      if external_references_behavior == :reject
        offenders = external_sheet_references
        raise RubyXL::ExternalReferenceError.new(offenders, source_file_label) unless offenders.empty?
      end

      # Deep-copy the worksheet without touching the source workbook: Marshal duplicates
      # the entire object graph (sheet data, comments, drawings, relationships), so the
      # source workbook is left byte-for-byte identical.
      new_worksheet = Marshal.load(Marshal.dump(source_worksheet))
      new_worksheet.workbook = target_workbook
      new_worksheet.sheet_id = nil # A fresh sheet id is assigned when the workbook is saved.
      new_worksheet.sheet_name = unique_sheet_name(requested_name || source_worksheet.sheet_name)
      @new_sheet_name = new_worksheet.sheet_name

      remap_styles(new_worksheet)
      remap_shared_strings(new_worksheet)
      rewrite_references(new_worksheet)
      rehome_related_parts(new_worksheet)

      target_workbook.worksheets << new_worksheet
      new_worksheet
    end

    private

    attr_reader :requested_name, :external_references_behavior, :unsupported_parts_behavior

    def validate!
      raise ArgumentError, 'source worksheet is not attached to a workbook' if source_workbook.nil?

      unless EXTERNAL_REFERENCE_BEHAVIORS.include?(external_references_behavior)
        raise ArgumentError, "invalid :external_references behavior #{external_references_behavior.inspect} " \
                             "(expected one of #{EXTERNAL_REFERENCE_BEHAVIORS.inspect})"
      end

      unless UNSUPPORTED_PART_BEHAVIORS.include?(unsupported_parts_behavior)
        raise ArgumentError, "invalid :unsupported_parts behavior #{unsupported_parts_behavior.inspect} " \
                             "(expected one of #{UNSUPPORTED_PART_BEHAVIORS.inspect})"
      end
    end

    def source_workbook
      source_worksheet.workbook
    end

    def source_sheet_names
      source_workbook.worksheets.map(&:sheet_name)
    end

    def source_file_label
      root = source_workbook.root
      path = root && root.source_file_path
      path.nil? || path.to_s.empty? ? 'source.xlsx' : File.basename(path.to_s)
    end

    ### Dependency closure (plan) ###

    def build_plan
      parts = []
      sheet_path = source_sheet_path
      parts << WorksheetCopyPlan::Part.new(nil, nil, nil, sheet_path.to_s, 'worksheet', true,
                                           'copied to a new sheet part in the target package')

      if source_workbook.stylesheet
        parts << WorksheetCopyPlan::Part.new(nil, nil, nil, 'xl/styles.xml', 'styles', true,
                                             'style records merged into the target stylesheet by content')
      end

      sst = source_workbook.shared_strings_container
      if sst && !sst.empty?
        parts << WorksheetCopyPlan::Part.new(nil, nil, nil, 'xl/sharedStrings.xml', 'shared strings', true,
                                             'strings merged into the target shared string table by content')
      end

      walk_relationships(source_worksheet, sheet_path, parts)

      WorksheetCopyPlan.new(source_worksheet.sheet_name, parts)
    end

    def walk_relationships(owner, owner_path, parts, seen = {})
      return if seen[owner.object_id]
      seen[owner.object_id] = true

      container = owner.respond_to?(:relationship_container) ? owner.relationship_container : nil
      return if container.nil?
      related_files = container.related_files || {}

      container.relationships.each { |rel|
        if rel.target_mode == 'External'
          parts << WorksheetCopyPlan::Part.new(owner_path.to_s, rel.id, rel.type, rel.target,
                                               'external link', true, 'external reference copied as-is')
          next
        end

        related = related_files[rel.id]
        target_path = resolve_target(owner_path, rel.target)
        kind, supported, note = classify_part(related, rel)
        parts << WorksheetCopyPlan::Part.new(owner_path.to_s, rel.id, rel.type, target_path.to_s,
                                             kind, supported, note)

        walk_relationships(related, target_path, parts, seen) if related
      }
    end

    def classify_part(related, rel)
      case related
      when nil then [ 'unresolved reference', false, 'relationship target could not be loaded' ]
      when RubyXL::CommentsFile then [ 'comments', true, 'copied to a new comments part' ]
      when RubyXL::DrawingFile then [ 'drawing', true, 'copied; embedded images reused by content' ]
      when RubyXL::VMLDrawingFile then [ 'VML drawing', true, 'copied; embedded images reused by content' ]
      when RubyXL::PrinterSettingsFile then [ 'printer settings', true, 'copied to a new part' ]
      when RubyXL::BinaryImageFile then [ 'image', true, 'reused by content or copied to a new part' ]
      else
        type_name = rel.type ? rel.type.split('/').last : related.class.name
        [ type_name, false, 'this part type is not supported by cross-workbook copy' ]
      end
    end

    def source_sheet_path
      container = source_workbook.relationship_container

      if container && container.related_files
        container.relationships.each { |rel|
          next if rel.target_mode == 'External'
          if container.related_files[rel.id].equal?(source_worksheet)
            return resolve_target(Pathname('/xl/workbook.xml'), rel.target)
          end
        }
      end

      index = source_workbook.worksheets.index { |ws| ws.equal?(source_worksheet) } || 0
      Pathname("/xl/worksheets/sheet#{index + 1}.xml")
    end

    def resolve_target(owner_path, target)
      path = Pathname(target.to_s)
      path.relative? ? (owner_path.dirname + path).cleanpath : path
    end

    ### Stylesheet merging (records are reused by content, never by name or index) ###

    def source_stylesheet
      source_workbook.stylesheet
    end

    def target_stylesheet
      ss = target_workbook.stylesheet ||= RubyXL::Stylesheet.default
      ss.fonts          ||= RubyXL::Fonts.default
      ss.fills          ||= RubyXL::Fills.default
      ss.borders        ||= RubyXL::Borders.default
      ss.cell_xfs       ||= RubyXL::CellXFs.default
      ss.cell_style_xfs ||= RubyXL::CellStyleXFs.default
      ss.cell_styles    ||= RubyXL::CellStyles.default
      ss
    end

    def remap_styles(new_worksheet)
      return if source_stylesheet.nil?

      @xf_map = {}
      @style_xf_map = {}
      @num_fmt_map = {}
      @font_map = {}
      @fill_map = {}
      @border_map = {}
      @dxf_map = {}

      if new_worksheet.cols
        new_worksheet.cols.each { |col|
          col.style_index = remap_cell_xf(col.style_index) unless col.style_index.nil?
        }
      end

      if new_worksheet.sheet_data
        new_worksheet.sheet_data.rows.each { |row|
          next if row.nil?
          row.style_index = remap_cell_xf(row.style_index) unless row.style_index.nil?
          row.cells.each { |cell|
            next if cell.nil? || cell.style_index.nil?
            cell.style_index = remap_cell_xf(cell.style_index)
          }
        }
      end

      Array(new_worksheet.conditional_formatting).each { |cf|
        cf.conditional_formatting_rules.each { |rule|
          rule.dxf_id = remap_dxf(rule.dxf_id) unless rule.dxf_id.nil?
        }
      }
    end

    def remap_cell_xf(src_index)
      return @xf_map[src_index] if @xf_map.key?(src_index)
      src_xf = source_stylesheet.cell_xfs && source_stylesheet.cell_xfs[src_index]
      return @xf_map[src_index] = src_index if src_xf.nil?

      new_xf = remap_xf_object(src_xf)
      new_xf.xf_id = remap_style_xf(src_xf.xf_id) unless src_xf.xf_id.nil?
      @xf_map[src_index] = find_or_add(target_stylesheet.cell_xfs, new_xf)
    end

    def remap_style_xf(src_index)
      return @style_xf_map[src_index] if @style_xf_map.key?(src_index)
      src_style_xfs = source_stylesheet.cell_style_xfs
      src_xf = src_style_xfs && src_style_xfs[src_index]
      return @style_xf_map[src_index] = src_index if src_xf.nil?

      new_xf = remap_xf_object(src_xf)
      new_xf.xf_id = nil
      new_index = find_or_add(target_stylesheet.cell_style_xfs, new_xf)
      @style_xf_map[src_index] = new_index

      # Named cell styles pointing at this style record are copied as well. They are
      # matched by full content: an identical name does not imply identical content.
      if source_stylesheet.cell_styles
        source_stylesheet.cell_styles.each { |cell_style|
          next unless cell_style.xf_id == src_index
          new_style = cell_style.dup
          new_style.xf_id = new_index
          find_or_add(target_stylesheet.cell_styles, new_style)
        }
      end

      new_index
    end

    def remap_xf_object(src_xf)
      new_xf = deep_copy_ooxml(src_xf)
      new_xf.num_fmt_id = remap_num_fmt(src_xf.num_fmt_id)
      new_xf.font_id    = remap_component(@font_map,   source_stylesheet.fonts,   target_stylesheet.fonts,   src_xf.font_id)
      new_xf.fill_id    = remap_component(@fill_map,   source_stylesheet.fills,   target_stylesheet.fills,   src_xf.fill_id)
      new_xf.border_id  = remap_component(@border_map, source_stylesheet.borders, target_stylesheet.borders, src_xf.border_id)
      new_xf
    end

    def remap_num_fmt(src_id)
      return nil if src_id.nil?
      return @num_fmt_map[src_id] if @num_fmt_map.key?(src_id)

      src_formats = source_stylesheet.number_formats
      fmt = src_formats && src_formats.find_by_format_id(src_id)
      # Custom formats are (re)registered by format code, so a same-id format in the
      # target workbook with different content never gets reused by mistake.
      @num_fmt_map[src_id] = fmt ? target_stylesheet.register_number_format(fmt.format_code) : src_id
    end

    def remap_component(map, src_collection, dst_collection, src_id)
      return nil if src_id.nil?
      return map[src_id] if map.key?(src_id)
      obj = src_collection && src_collection[src_id]
      map[src_id] = obj.nil? ? src_id : find_or_add(dst_collection, deep_copy_ooxml(obj))
    end

    def remap_dxf(src_index)
      return @dxf_map[src_index] if @dxf_map.key?(src_index)
      src_dxfs = source_stylesheet.dxfs
      src_dxf = src_dxfs && src_dxfs[src_index]
      return @dxf_map[src_index] = src_index if src_dxf.nil?

      new_dxf = deep_copy_ooxml(src_dxf)
      new_dxf.num_fmt.num_fmt_id = remap_num_fmt(new_dxf.num_fmt.num_fmt_id) if new_dxf.num_fmt

      dst_dxfs = (target_stylesheet.dxfs ||= RubyXL::DXFs.new)
      @dxf_map[src_index] = find_or_add(dst_dxfs, new_dxf)
    end

    def find_or_add(collection, obj)
      index = collection.find_index { |existing| existing == obj }
      return index if index
      collection << obj
      collection.size - 1
    end

    def deep_copy_ooxml(obj)
      obj.class.parse(obj.write_xml)
    end

    ### Shared strings (merged by content) ###

    def remap_shared_strings(new_worksheet)
      src_sst = source_workbook.shared_strings_container
      return if src_sst.nil? || new_worksheet.sheet_data.nil?

      @sst_map = {}

      new_worksheet.sheet_data.rows.each { |row|
        next if row.nil?
        row.cells.each { |cell|
          next if cell.nil? || cell.datatype != RubyXL::DataType::SHARED_STRING || cell.raw_value.nil?
          cell.raw_value = remap_shared_string(src_sst, cell.raw_value.to_i).to_s
        }
      }
    end

    def remap_shared_string(src_sst, src_index)
      return @sst_map[src_index] if @sst_map.key?(src_index)
      rich_text = src_sst[src_index]
      return @sst_map[src_index] = src_index if rich_text.nil?

      copy = deep_copy_ooxml(rich_text)
      dst_sst = target_workbook.shared_strings_container ||= RubyXL::SharedStringsTable.new
      index = dst_sst.strings.find_index { |existing| existing == copy }
      @sst_map[src_index] = index || dst_sst.add(copy)
    end

    ### Reference rewriting ###

    # Sheet references pointing at the copied sheet itself are remapped to the new sheet;
    # references to other sheets of the source workbook are rewritten as external links
    # (when :external_references => :keep) or reported to the caller (default).
    def rewrite_references(new_worksheet)
      each_formula(new_worksheet) { |formula|
        formula.expression = rewrite_expression(formula.expression)
      }

      if new_worksheet.hyperlinks
        new_worksheet.hyperlinks.each { |link|
          link.location = rewrite_expression(link.location) if link.location
        }
      end
    end

    def each_formula(worksheet)
      if worksheet.sheet_data
        worksheet.sheet_data.rows.each { |row|
          next if row.nil?
          row.cells.each { |cell|
            next if cell.nil? || cell.formula.nil?
            yield cell.formula
          }
        }
      end

      Array(worksheet.conditional_formatting).each { |cf|
        cf.conditional_formatting_rules.each { |rule|
          rule.formulas.each { |formula| yield formula }
        }
      }

      if worksheet.data_validations
        worksheet.data_validations.each { |dv|
          yield dv.formula1 if dv.formula1
          yield dv.formula2 if dv.formula2
        }
      end
    end

    # Names of other sheets of the source workbook referenced by the source worksheet.
    def external_sheet_references
      offenders = []

      each_formula(source_worksheet) { |formula|
        each_sheet_token(formula.expression) { |token|
          offenders << token if cross_sheet_token?(token)
        }
      }

      if source_worksheet.hyperlinks
        source_worksheet.hyperlinks.each { |link|
          each_sheet_token(link.location) { |token|
            offenders << token if cross_sheet_token?(token)
          }
        }
      end

      offenders.uniq
    end

    def cross_sheet_token?(token)
      token != source_worksheet.sheet_name && source_sheet_names.include?(token)
    end

    def each_sheet_token(expression)
      return if expression.nil?
      expression.scan(SHEET_REFERENCE) { |literal, quoted, bare|
        next unless literal.nil?
        token = quoted ? quoted.gsub("''", "'") : bare
        yield token unless token.nil? || token.include?('[') || token.include?(']')
      }
    end

    def rewrite_expression(expression)
      return expression if expression.nil?
      expression.gsub(SHEET_REFERENCE) { |match|
        if Regexp.last_match(1) then
          match # String literal: leave untouched.
        else
          token = Regexp.last_match(2) ? Regexp.last_match(2).gsub("''", "'") : Regexp.last_match(3)
          replacement = map_sheet_token(token)
          replacement.nil? ? match : "#{replacement}!"
        end
      }
    end

    def map_sheet_token(token)
      return nil if token.nil? || token.include?('[') || token.include?(']') # Already external.

      if token == source_worksheet.sheet_name
        quote_sheet_name(@new_sheet_name)
      elsif source_sheet_names.include?(token)
        "'[#{source_file_label}]#{token.gsub("'", "''")}'" if external_references_behavior == :keep
      end
    end

    def quote_sheet_name(name)
      if name =~ /\A[A-Za-z_][A-Za-z0-9_.]*\z/ && name !~ /\A[A-Za-z]{1,3}[0-9]+\z/i
        name
      else
        "'#{name.gsub("'", "''")}'"
      end
    end

    def unique_sheet_name(base)
      base = base.to_s[0..30]
      base = 'Sheet' if base.empty?
      candidate = base
      n = 1
      until target_workbook[candidate].nil?
        n += 1
        suffix = " (#{n})"
        candidate = "#{base[0..(30 - suffix.length)]}#{suffix}"
      end
      candidate
    end

    ### Related parts (comments, drawings, images, printer settings, hyperlinks) ###

    def rehome_related_parts(new_worksheet)
      @rid_map = {}
      @assigned_rids = {}
      @handled_parts = {}
      @new_relationships = RubyXL::OOXMLRelationshipsFile.new
      kept_generic_storage = []

      old_container = new_worksheet.relationship_container

      if old_container
        old_related = old_container.related_files || {}

        old_container.relationships.each { |rel|
          if rel.target_mode == 'External'
            @rid_map[rel.id] = add_sheet_relationship(rel.target, rel.type, 'External')
            next
          end

          new_target = rehome_part(old_related[rel.id], kept_generic_storage)
          @rid_map[rel.id] = add_sheet_relationship(new_target, rel.type) if new_target
        }
      end

      sweep_unrelated_parts(new_worksheet, kept_generic_storage)

      new_worksheet.generic_storage = kept_generic_storage
      new_worksheet.relationship_container = @new_relationships

      fixup_rid_references(new_worksheet)
    end

    # Migrate a single related part into the target package. Returns the relative
    # target path for the new relationship, or +nil+ if the part is dropped.
    def rehome_part(related, kept_generic_storage)
      case related
      when nil then nil
      when RubyXL::CommentsFile
        @handled_parts[related.object_id] = true
        related.workbook = target_workbook
        relative_target(SHEET_PARTS_DIR, allocate_comments_path)
      when RubyXL::DrawingFile, RubyXL::VMLDrawingFile
        @handled_parts[related.object_id] = true
        rehome_drawing(related)
        kept_generic_storage << related
        relative_target(SHEET_PARTS_DIR, related.xlsx_path)
      when RubyXL::PrinterSettingsFile
        @handled_parts[related.object_id] = true
        rehome_generic_part(related)
        relative_target(SHEET_PARTS_DIR, related.xlsx_path)
      when RubyXL::BinaryImageFile
        @handled_parts[related.object_id] = true
        image, is_new = find_or_add_image(related)
        kept_generic_storage << image if is_new
        relative_target(SHEET_PARTS_DIR, image.xlsx_path)
      end
      # Any other part type is unsupported: it is dropped here (the dependency
      # closure has already been reported to the caller via the plan).
    end

    # Parts of programmatically built source workbooks may be attached through
    # accessors only, without a .rels file. Pick those up as well.
    def sweep_unrelated_parts(new_worksheet, kept_generic_storage)
      new_worksheet.comments.each { |comments|
        next if @handled_parts[comments.object_id]
        @handled_parts[comments.object_id] = true
        comments.workbook = target_workbook
        add_sheet_relationship(relative_target(SHEET_PARTS_DIR, allocate_comments_path),
                               RubyXL::CommentsFile::REL_TYPE)
      }

      new_worksheet.printer_settings.each { |settings|
        next if @handled_parts[settings.object_id]
        @handled_parts[settings.object_id] = true
        rehome_generic_part(settings)
        rid = add_sheet_relationship(relative_target(SHEET_PARTS_DIR, settings.xlsx_path),
                                     RubyXL::PrinterSettingsFile::REL_TYPE)
        new_worksheet.page_setup.r_id = rid if new_worksheet.page_setup
      }

      new_worksheet.generic_storage.each { |part|
        next if @handled_parts[part.object_id]
        @handled_parts[part.object_id] = true

        case part
        when RubyXL::DrawingFile
          rehome_drawing(part)
          kept_generic_storage << part
          rid = add_sheet_relationship(relative_target(SHEET_PARTS_DIR, part.xlsx_path), RubyXL::DrawingFile::REL_TYPE)
          new_worksheet.drawing = RubyXL::RID.new(:r_id => rid)
        when RubyXL::VMLDrawingFile
          rehome_drawing(part)
          kept_generic_storage << part
          rid = add_sheet_relationship(relative_target(SHEET_PARTS_DIR, part.xlsx_path), RubyXL::VMLDrawingFile::REL_TYPE)
          new_worksheet.legacy_drawing = RubyXL::RID.new(:r_id => rid)
        when RubyXL::BinaryImageFile
          image, is_new = find_or_add_image(part)
          kept_generic_storage << image if is_new
          rid = add_sheet_relationship(relative_target(SHEET_PARTS_DIR, image.xlsx_path), RubyXL::BinaryImageFile::REL_TYPE)
          new_worksheet.picture = RubyXL::RID.new(:r_id => rid)
        end
      }
    end

    # Re-home a drawing (or VML drawing) part: assign a fresh part URI, migrate its
    # image relationships (reusing images by content), copy external relationships,
    # and rewrite relationship IDs inside the drawing XML.
    def rehome_drawing(drawing)
      old_container = drawing.relationship_container
      old_related = old_container ? (old_container.related_files || {}) : {}

      rehome_generic_part(drawing)

      new_container = RubyXL::OOXMLRelationshipsFile.new
      new_generic_storage = []
      rid_map = {}
      dropped_rids = []

      old_container && old_container.relationships.each { |rel|
        if rel.target_mode == 'External'
          rid_map[rel.id] = add_relationship(new_container, rel.target, rel.type, 'External')
          next
        end

        related = old_related[rel.id]

        case related
        when RubyXL::BinaryImageFile
          image, is_new = find_or_add_image(related)
          new_generic_storage << image if is_new
          rid_map[rel.id] = add_relationship(new_container,
                                             relative_target(drawing.xlsx_path.dirname, image.xlsx_path),
                                             RubyXL::BinaryImageFile::REL_TYPE)
        else
          # Unsupported (charts, etc.) or unresolved: drop the relationship and the
          # shape that references it.
          dropped_rids << rel.id
        end
      }

      drawing.generic_storage = new_generic_storage
      drawing.relationship_container = new_container
      drawing.data = remap_part_relationship_ids(drawing.data, rid_map, dropped_rids)
    end

    # Rewrite every relationship-ID attribute inside an XML part. IDs in +rid_map+
    # are renumbered; IDs in +dropped_rids+ have their top-level anchor removed.
    def remap_part_relationship_ids(data, rid_map, dropped_rids)
      return data if data.nil? || (rid_map.empty? && dropped_rids.empty?)

      doc = Nokogiri::XML(data)
      anchors = []

      doc.traverse { |node|
        next unless node.element?
        node.attribute_nodes.each { |attr|
          ns = attr.namespace
          next if ns.nil? || ns.href != RELATIONSHIPS_NAMESPACE
          if rid_map.key?(attr.value) then
            attr.value = rid_map[attr.value]
          elsif dropped_rids.include?(attr.value) then
            anchors << top_level_anchor(node)
          end
        }
      }

      anchors.each(&:remove)
      doc.to_xml(:indent => 0, :save_with => Nokogiri::XML::Node::SaveOptions::AS_XML)
    end

    def top_level_anchor(node)
      node = node.parent while node.parent && node.parent.element? && node.parent != node.document.root
      node
    end

    # Reuse an existing image of the target workbook when its bytes are identical
    # (same file name does NOT imply same content); otherwise allocate a fresh part.
    def find_or_add_image(source_image)
      existing = target_images.find { |img| img.data == source_image.data }
      return [ existing, false ] if existing

      source_path = source_image.xlsx_path
      source_image.content_type ||= source_content_type_for(source_path) || image_content_type_for(source_path)
      rehome_generic_part(source_image)
      target_images << source_image
      [ source_image, true ]
    end

    def target_images
      @target_images ||= target_workbook.root.collect_related_objects.select { |obj|
        obj.is_a?(RubyXL::BinaryImageFile)
      }
    end

    def source_content_type_for(part_path)
      root = source_workbook.root
      content_types = root && root.content_types
      content_types && content_types.content_type_for(part_path)
    end

    def image_content_type_for(part_path)
      IMAGE_CONTENT_TYPES[File.extname(part_path.to_s)[1..-1].to_s.downcase]
    end

    # Assign the part a URI that is free inside the target package, keeping its
    # current one if it does not collide with an existing part.
    def rehome_generic_part(part)
      path = part.xlsx_path.to_s
      path = allocate_similar_path(path) if used_paths.key?(path)
      used_paths[path] = true
      part.xlsx_path = Pathname(path)
    end

    def allocate_similar_path(path)
      dir = File.dirname(path)
      ext = File.extname(path)
      stem = File.basename(path, ext).sub(/\d+\z/, '')
      n = 1
      n += 1 while used_paths.key?(candidate = "#{dir}/#{stem}#{n}#{ext}")
      candidate
    end

    def used_paths
      @used_paths ||= begin
        paths = {}
        target_workbook.root.collect_related_objects.each { |obj|
          paths[obj.xlsx_path.to_s] = true if obj.is_a?(RubyXL::GenericStorageObject)
        }
        paths
      end
    end

    # Comments parts are named by save-time index (xl/comments<N>.xml), so predict
    # the index the copied part will get: existing comments come first in save order.
    def allocate_comments_path
      @comments_part_index ||= target_workbook.root.collect_related_objects.count { |obj|
        obj.is_a?(RubyXL::CommentsFile)
      }
      @comments_part_index += 1
      Pathname("/xl/comments#{@comments_part_index}.xml")
    end

    def relative_target(owner_dir, target_path)
      Pathname(target_path).relative_path_from(owner_dir).to_s
    end

    def add_sheet_relationship(target, type, mode = nil)
      add_relationship(@new_relationships, target, type, mode)
    end

    def add_relationship(container, target, type, mode = nil)
      id = "rId#{container.relationships.size + 1}"
      container.relationships << RubyXL::Relationship.new(:id => id, :type => type,
                                                          :target => target, :target_mode => mode)
      @assigned_rids[id] = true if container.equal?(@new_relationships)
      id
    end

    ### Fix up r:id references inside the copied sheet ###

    def fixup_rid_references(new_worksheet)
      remap_rid_node(new_worksheet, :drawing)
      remap_rid_node(new_worksheet, :legacy_drawing)
      remap_rid_node(new_worksheet, :legacy_drawing_hf)
      remap_rid_node(new_worksheet, :picture)

      if new_worksheet.page_setup && new_worksheet.page_setup.r_id
        new_worksheet.page_setup.r_id = remap_rid(new_worksheet.page_setup.r_id)
      end

      if new_worksheet.hyperlinks
        new_worksheet.hyperlinks.each { |link|
          link.r_id = remap_rid(link.r_id) if link.r_id
        }
      end

      prune_rid_collection(new_worksheet, :table_parts)
      prune_rid_collection(new_worksheet, :ole_objects)
      prune_rid_collection(new_worksheet, :controls)
      prune_rid_collection(new_worksheet, :custom_properties)
      fix_data_consolidate(new_worksheet)
    end

    def remap_rid(old_rid)
      @rid_map[old_rid] || (@assigned_rids[old_rid] ? old_rid : nil)
    end

    def remap_rid_node(obj, accessor)
      node = obj.send(accessor) or return
      new_rid = remap_rid(node.r_id)
      if new_rid then
        node.r_id = new_rid
      else
        obj.send("#{accessor}=", nil)
      end
    end

    # Remap r:id's of collection members; drop members whose relationships were
    # not migrated (unsupported parts skipped with :unsupported_parts => :skip).
    def prune_rid_collection(new_worksheet, accessor)
      collection = new_worksheet.send(accessor) or return

      collection.reject! { |node|
        next false unless node.respond_to?(:r_id) && node.r_id
        new_rid = remap_rid(node.r_id)
        if new_rid then
          node.r_id = new_rid
          false
        else
          true
        end
      }

      new_worksheet.send("#{accessor}=", nil) if collection.empty?
    end

    def fix_data_consolidate(new_worksheet)
      consolidate = new_worksheet.data_consolidate or return
      refs = consolidate.data_refs or return
      orphaned = false

      refs.each { |ref|
        next if ref.r_id.nil?
        new_rid = remap_rid(ref.r_id)
        if new_rid then
          ref.r_id = new_rid
        else
          orphaned = true
        end
      }

      new_worksheet.data_consolidate = nil if orphaned
    end
  end

  class Workbook
    # Compute the dependency closure for copying a worksheet from another workbook
    # into this one, without changing anything. Inspect the returned
    # RubyXL::WorksheetCopyPlan to decide whether the copy should execute.
    #
    # +source+ may be a RubyXL::Worksheet, or a RubyXL::Workbook together with
    # +sheet+ (worksheet name or index).
    def plan_worksheet_copy(source, sheet = nil)
      worksheet = RubyXL::WorksheetCopier.resolve_source(source, sheet)
      RubyXL::WorksheetCopier.new(self, worksheet).plan
    end

    # Copy a worksheet from another workbook into this one, migrating everything the
    # sheet depends on: cell data, styles, shared strings, comments, images, hyperlinks
    # and printer settings. Relationship IDs and part URIs are re-assigned inside this
    # workbook's package; shared resources are reused by actual content, not by name.
    #
    # +source+ may be a RubyXL::Worksheet, or a RubyXL::Workbook together with
    # +sheet+ (worksheet name or index).
    #
    # Options:
    # * +:as+ - name for the new sheet (defaults to the source sheet name,
    #   de-duplicated if already taken);
    # * +:external_references+ - how to handle references to other sheets of the
    #   source workbook: +:reject+ (default, raise RubyXL::ExternalReferenceError)
    #   or +:keep+ (rewrite them as external links to the source file);
    # * +:unsupported_parts+ - how to handle unsupported part types found in the
    #   dependency closure: +:reject+ (default, raise RubyXL::UnsupportedPartsError
    #   carrying the full closure) or +:skip+ (copy without those parts).
    #
    # Returns the newly created RubyXL::Worksheet.
    def copy_worksheet_from(source, sheet = nil, as: nil, external_references: :reject, unsupported_parts: :reject)
      worksheet = RubyXL::WorksheetCopier.resolve_source(source, sheet)
      RubyXL::WorksheetCopier.new(self, worksheet,
                                  :as => as,
                                  :external_references => external_references,
                                  :unsupported_parts => unsupported_parts).execute
    end
  end

  class Worksheet
    # Copy this worksheet into +target_workbook+. See RubyXL::Workbook#copy_worksheet_from.
    def copy_to(target_workbook, **options)
      RubyXL::WorksheetCopier.new(target_workbook, self, options).execute
    end
  end
end
