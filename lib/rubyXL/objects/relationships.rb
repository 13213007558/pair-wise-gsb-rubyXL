require 'pathname'
require 'rubyXL/objects/ooxml_object'

module RubyXL
  class RID < OOXMLObject
    define_relationship(:required => true)
  end

  class Relationship < OOXMLObject
    define_attribute(:Id,         :string)
    define_attribute(:Type,       :string)
    define_attribute(:Target,     :string)
    define_attribute(:TargetMode, :string)
    define_element_name 'Relationship'
  end

  class OOXMLRelationshipsFile < OOXMLTopLevelObject
    CONTENT_TYPE = 'application/vnd.openxmlformats-package.relationships+xml'.freeze
    SAVE_ORDER = 100

    define_child_node(RubyXL::Relationship, :collection => true, :accessor => :relationships)
    define_element_name 'Relationships'
    set_namespaces('http://schemas.openxmlformats.org/package/2006/relationships' => nil)

    attr_accessor :related_files, :owner

    @@debug_indent = ($DEBUG ? 0 : nil)

    def new_relationship(target, type)
      RubyXL::Relationship.new(:id     => next_relationship_id,
                               :type   => type,
                               :target => target)
    end
    protected :new_relationship

    def add_relationship(obj)
      return if obj.nil? || !defined?(obj.class::REL_TYPE) || (obj.respond_to?(:empty?) && obj.empty?)

      relationships << RubyXL::Relationship.new(:id     => next_relationship_id,
                                                :type   => obj.class::REL_TYPE,
                                                :target => obj.xlsx_path.relative_path_from(owner.xlsx_path.dirname))
    end
    protected :add_relationship

    def next_relationship_id
      max_id = relationships.map { |relationship| relationship.id.to_s[/\d+\z/].to_i }.max || 0
      "rId#{max_id + 1}"
    end
    private :next_relationship_id

    def find_by_rid(r_id)
      relationships.find { |r| r.id == r_id }
    end

    def find_by_target(target)
      relationships.find { |r|
        (r.target.to_s == target.to_s) ||
          (r.target.to_s == target.relative_path_from(owner.xlsx_path.dirname).to_s)
      }
    end

    def self.get_class_by_rel_type(rel_type)
      unless defined?(@@rel_hash)
        @@rel_hash = {}
        RubyXL.constants.each { |c|
          klass = RubyXL.const_get(c)

          if klass.is_a?(Class) && klass.const_defined?(:REL_TYPE) then
            @@rel_hash[klass::REL_TYPE] = klass
          end
        }
      end

      @@rel_hash[rel_type]
    end

    def load_related_files(zipdir_path, base_file_name)
      self.related_files = {}
      preserving = owner&.preserve_extensions || preserve_extensions?

      @@debug_indent += 2 if @@debug_indent

      self.relationships.each { |rel|
        next if rel.target_mode == 'External'

        file_path = ::Pathname.new(rel.target)
        file_path = (base_file_name.dirname + file_path).cleanpath if file_path.relative?

        klass = RubyXL::OOXMLRelationshipsFile.get_class_by_rel_type(rel.type)

        if klass.nil? then
          if !RubyXL.class_variable_get(:@@suppress_warnings) then
            puts "*** WARNING: storage class not found for #{rel.target} (#{rel.type})"
          end

          klass = GenericStorageObject
        end

        puts "--> DEBUG:#{'  ' * @@debug_indent}Loading #{klass} (#{rel.id}): #{file_path}" if @@debug_indent

        obj = klass.parse_file(zipdir_path, file_path)
        obj.preserve_extensions = preserving if obj.respond_to?(:preserve_extensions=)
        obj.load_relationships(zipdir_path, file_path) if obj.respond_to?(:load_relationships)
        self.related_files[rel.id] = obj
      }

      @@debug_indent -= 2 if @@debug_indent

      related_files
    end

    def self.load_relationship_file(zipdir_path, base_file_path)
      rel_file_path = rel_file_path(base_file_path)

      puts "--> DEBUG:  #{'  ' * @@debug_indent}Loading .rel file: #{rel_file_path}" if @@debug_indent

      relationship_file = parse_file(zipdir_path, rel_file_path)
      relationship_file.preserve_extensions = preserve_extensions? if relationship_file
      relationship_file
    end

    def xlsx_path
      self.class.rel_file_path(owner.xlsx_path)
    end

    def preserve_extensions?
      !!RubyXL.preserve_extensions
    end

    def before_write_xml
      if owner&.preserve_extensions then
        related_objects = owner.respond_to?(:related_objects) ? owner.related_objects : []
        related_objects += owner.generic_storage if owner.generic_storage
        existing_targets = relationships.map { |relationship| resolved_relationship_target(relationship).to_s }
        related_objects.compact.each { |object|
          next unless object.respond_to?(:xlsx_path)
          target = resolved_relationship_target_for_object(object).to_s
          unless existing_targets.include?(target)
            add_relationship(object)
            existing_targets << target
          end
        }
      elsif owner.is_a?(RubyXL::WorkbookRoot) || owner.is_a?(RubyXL::Workbook)
        # Fully implemented objects with no generic (unhandled) relationships -
        #   (re)generating relationships from scratch.
        related_objects = owner.related_objects
        related_objects += owner.generic_storage if owner.generic_storage

        self.relationships = []
        related_objects.compact.each { |f| add_relationship(f) }
      end
      reconcile_preserved_relationships!
      missing_dependencies = extension_dependencies
      raise RubyXL::ExtensionDependencyError.new(missing_dependencies) unless missing_dependencies.empty?
      super
    end

    def reconcile_preserved_relationships!
      return unless owner&.preserve_extensions

      available_targets = available_relationship_targets
      self.relationships ||= []
      relationships.select! { |relationship|
        relationship.target_mode == 'External' || available_targets.include?(resolved_relationship_target(relationship))
      }
    end

    def extension_dependencies
      return [] unless owner

      valid_ids = relationships.select { |relationship|
        relationship.target_mode == 'External' || available_relationship_targets.include?(resolved_relationship_target(relationship))
      }.map(&:id)

      referenced_ids = owner.extension_relationship_ids
      referenced_ids.reject { |id| valid_ids.include?(id) }.map { |id|
        relationship = relationships.find { |rel| rel.id == id }
        {
          :part       => part_label,
          :id         => id,
          :target     => relationship&.target || '<relationship removed>',
          :extension  => 'preserved extension XML'
        }
      }
    end

    def drop_missing_extensions!
      reconcile_preserved_relationships!
      missing = extension_dependencies.map { |dependency| dependency[:id] }
      owner.remove_extension_relationship_ids!(missing) unless missing.empty?
      reconcile_preserved_relationships!
      missing
    end

    def available_relationship_targets
      objects = root_related_objects
      objects.select { |object|
        object.respond_to?(:xlsx_path) && !object.is_a?(RubyXL::OOXMLRelationshipsFile)
      }.map { |object| RubyXL.from_root(object.xlsx_path) }
    end

    def root_related_objects
      root_object = owner.respond_to?(:root) ? owner.root : owner
      root_object ? root_object.collect_related_objects : []
    end

    def resolved_relationship_target(relationship)
      target = ::Pathname.new(relationship.target.to_s)
      base_path = owner.is_a?(RubyXL::OOXMLRelationshipsFile) ? owner.xlsx_path.dirname.parent : owner.xlsx_path.dirname
      target = base_path + target if target.relative?
      RubyXL.from_root(target.cleanpath)
    end

    def resolved_relationship_target_for_object(object)
      RubyXL.from_root(object.xlsx_path)
    end

    def part_label
      owner.respond_to?(:xlsx_path) ? RubyXL.from_root(owner.xlsx_path).to_s : owner.class.name
    end

    def self.rel_file_path(base_file_path)
      basename = base_file_path.root? ? '' : base_file_path.basename
      base_file_path.dirname.join('_rels', "#{basename}.rels").cleanpath
    end
  end

  # +RelationshipSupport+ module enables automatic loading and saving of _rels for the respective file
  module RelationshipSupport
    module ClassMehods
      def define_relationship(klass, accessor = nil)
        class_variable_get(:@@ooxml_relationships)[klass] = accessor
        attr_accessor(accessor) if accessor
      end
    end

    def self.included(klass)
      klass.class_variable_set(:@@ooxml_relationships, {})
      klass.extend RubyXL::RelationshipSupport::ClassMehods
    end

    attr_accessor :generic_storage, :relationship_container, :preserve_extensions

    def related_objects # Override this method
      []
    end

    def preserve_extensions?
      !!RubyXL.preserve_extensions
    end

    def collect_related_objects
      res = related_objects.compact # Avoid tainting +related_objects+ array
      res.concat(generic_storage) if generic_storage

      if relationship_container then
        relationship_container.owner = self
        res << relationship_container
      end

      related = []

      res.each { |obj|
        next if obj.respond_to?(:empty?) && obj.empty?
        related << obj
        related.concat(obj.collect_related_objects) if obj.respond_to?(:collect_related_objects)
      }

      related
    end

    def load_relationships(dir_path, base_file_name)
      self.preserve_extensions = preserve_extensions? if respond_to?(:preserve_extensions=) && preserve_extensions.nil?
      self.relationship_container = RubyXL::OOXMLRelationshipsFile.load_relationship_file(dir_path, base_file_name)
      return if relationship_container.nil?
      relationship_container.owner = self
      relationship_container.preserve_extensions = preserve_extensions if relationship_container.respond_to?(:preserve_extensions=)

      relationship_container.load_related_files(dir_path, base_file_name).each_pair { |rid, related_file|
        attach_relationship(rid, related_file) if related_file
      }
    end

    def attach_relationship(rid, rf)
      relationships = self.class.class_variable_get(:@@ooxml_relationships)
      klass = rf.class
      if relationships.has_key?(klass) then
        accessor = relationships[klass]
        case accessor
        when NilClass then
          # Relationship is known, but we don't have a special accessor for it, store as generic
          store_relationship(rf)
        when false then
          # Do nothing, the code will perform attaching on its own
        else
          container = self.send(accessor)
          if container.is_a?(Array) then container << rf
          else self.send("#{accessor}=", rf)
          end
        end
      else store_relationship(rf, :unknown)
      end
    end

    def store_relationship(related_file, unknown = false)
      self.generic_storage ||= []
      if unknown && !RubyXL.class_variable_get(:@@suppress_warnings) then
        puts "WARNING: #{self.class} is not aware how to process #{related_file.class}"
      end
      self.generic_storage << related_file
    end

    def extension_relationship_ids
      ids = []
      collect_extension_relationship_ids(self, ids)
      ids.uniq
    end

    def remove_extension_relationship_ids!(ids)
      remove_extension_relationship_ids_from_object(self, ids)
    end

    private

    def collect_extension_relationship_ids(object, ids)
      case object
      when RubyXL::RawOOXML then ids.concat(object.extension_relationship_ids)
      when RubyXL::OOXMLObject, RubyXL::OOXMLContainerObject
        object.preserved_attributes.each_value { |attribute|
          if attribute[:namespace] == RubyXL::RELATIONSHIPS_NS && attribute[:name] == 'id' then
            ids << attribute[:value]
          end
        }
        object.preserved_child_order.each { |kind, name, raw_or_index|
          ids.concat(RubyXL::RawOOXML.relationship_ids(raw_or_index)) if kind == 'raw'
        }
        object.class.obtain_class_variable(:@@ooxml_child_nodes).each_value { |params|
          child = object.send(params[:accessor]) rescue nil
          if object.is_a?(RubyXL::OOXMLContainerObject) && params[:is_array] then
            object.each { |item| collect_extension_relationship_ids(item, ids) }
          else
            Array(child).compact.each { |item| collect_extension_relationship_ids(item, ids) }
          end
        }
      end
    end

    def remove_extension_relationship_ids_from_object(object, ids)
      return unless object.is_a?(RubyXL::OOXMLObject) || object.is_a?(RubyXL::OOXMLContainerObject)

      object.preserved_attributes.delete_if { |_name, attribute|
        attribute[:namespace] == RubyXL::RELATIONSHIPS_NS && attribute[:name] == 'id' && ids.include?(attribute[:value])
      }

      object.preserved_child_order.reject! { |slot|
        slot[0] == 'raw' && !(RubyXL::RawOOXML.relationship_ids(slot[2]) & ids).empty?
      }

      object.class.obtain_class_variable(:@@ooxml_child_nodes).each_value { |params|
        child = object.send(params[:accessor]) rescue nil
        next if child.nil?

        if child.is_a?(RubyXL::RawOOXML)
          child.remove_extension_relationship_ids!(ids)
          object.send("#{params[:accessor]}=", nil) if child.raw_xml.to_s.empty?
        elsif child.is_a?(Array)
          if object.is_a?(RubyXL::OOXMLContainerObject) && params[:is_array] then
            object.each { |item| remove_raw_item_if_needed(item, ids) }
            object.reject! { |item| item.is_a?(RubyXL::RawOOXML) && item.raw_xml.to_s.empty? }
          else
            child.each { |item| remove_raw_item_if_needed(item, ids) }
          end
          child.reject! { |item| item.is_a?(RubyXL::RawOOXML) && item.raw_xml.to_s.empty? }
          object.send("#{params[:accessor]}=", nil) if child.empty?
        elsif child.is_a?(RubyXL::OOXMLObject) || child.is_a?(RubyXL::OOXMLContainerObject)
          remove_extension_relationship_ids_from_object(child, ids)
          object.send("#{params[:accessor]}=", nil) if child_raw_extension_empty?(child, params)
          if !params[:is_array] && child.respond_to?(:extensions) && child.extensions&.empty? then
            object.send("#{params[:accessor]}=", nil)
          end
        end
      }
    end

    def child_raw_extension_empty?(child, params)
      child.respond_to?(:empty?) && child.empty?
    end

    def remove_raw_item_if_needed(item, ids)
      case item
      when RubyXL::RawOOXML then item.remove_extension_relationship_ids!(ids)
      when RubyXL::OOXMLObject, RubyXL::OOXMLContainerObject then remove_extension_relationship_ids_from_object(item, ids)
      end
    end
  end
end
