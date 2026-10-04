require 'rubyXL/objects/ooxml_object'

module RubyXL
  class ContentTypeDefault < OOXMLObject
    define_attribute(:Extension,   :string)
    define_attribute(:ContentType, :string)
    define_element_name 'Default'
  end

  class ContentTypeOverride < OOXMLObject
    define_attribute(:PartName, :string)
    define_attribute(:ContentType, :string)
    define_element_name 'Override'
  end

  class ContentTypes < OOXMLTopLevelObject
    SAVE_ORDER = 999  # Must be saved last, so it has time to accumulate overrides from all others.
    XLSX_PATH = ROOT.join('[Content_Types].xml')

    define_child_node(RubyXL::ContentTypeDefault,  :collection => true, :accessor => :defaults)
    define_child_node(RubyXL::ContentTypeOverride, :collection => true, :accessor => :overrides)

    set_namespaces('http://schemas.openxmlformats.org/package/2006/content-types' => nil)
    define_element_name 'Types'

    def xlsx_path
      XLSX_PATH
    end

    # Look up the content type registered for the given part name (e.g. '/xl/media/image1.png'),
    # checking explicit overrides first, then extension defaults. Returns +nil+ if not found.
    def content_type_for(part_name)
      name = part_name.to_s

      override = (overrides || []).find { |o| o.part_name == name }
      return override.content_type if override

      ext = File.extname(name)
      ext = ext[1..-1] unless ext.empty?
      default = (defaults || []).find { |d| d.extension == ext }
      default && default.content_type
    end

    def before_write_xml
      content_types_by_ext = {}

      # Collect all extensions and corresponding content types
      root.rels_hash.each_pair { |klass, objects|
        objects.each { |obj|
          obj_content_type = (obj.content_type if obj.respond_to?(:content_type))
          obj_content_type ||= klass::CONTENT_TYPE if klass.const_defined?(:CONTENT_TYPE)
          next if obj_content_type.nil?
          ext = obj.xlsx_path.extname[1..-1]
          next if ext.nil?
          content_types_by_ext[ext] ||= []
          content_types_by_ext[ext] << obj_content_type
        }
      }

      self.defaults = [ RubyXL::ContentTypeDefault.new(:extension => 'xml', :content_type => 'application/xml') ]

      # Determine which content types are used most often, and add them to the list of defaults
      content_types_by_ext.each_pair { |ext, content_types_arr|
        next if ext.nil? || defaults.any? { |d| d.extension == ext }
        most_frequent_ct = content_types_arr.group_by { |ct| ct }.values.max_by(&:size).first
        defaults << RubyXL::ContentTypeDefault.new(:extension => ext, :content_type => most_frequent_ct)
      }

      self.overrides = []

      # Add overrides for the files with known extensions but different content types.
      root.rels_hash.each_pair { |klass, objects|
        objects.each { |obj|
          obj_content_type = (obj.content_type if obj.respond_to?(:content_type))
          obj_content_type ||= klass::CONTENT_TYPE if defined?(klass::CONTENT_TYPE)
          next if obj_content_type.nil?

          ext = obj.xlsx_path.extname[1..-1]
          next if defaults.any? { |d| (d.extension == ext) && (d.content_type == obj_content_type) }
          overrides << RubyXL::ContentTypeOverride.new(:part_name    => obj.xlsx_path,
                                                       :content_type => obj_content_type)
        }
      }

      true
    end
  end
end
