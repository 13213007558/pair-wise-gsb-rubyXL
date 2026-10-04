require 'rubyXL/objects/ooxml_object'

module RubyXL
  # Raw OOXML fragments are kept verbatim in extension-preservation mode.
  #
  # mc:Ignorable is used when unknown markup is harmless and can be retained while an older consumer
  # ignores the listed namespace prefixes. mc:AlternateContent is used only when a complete alternate
  # branch exists for consumers that do not understand +Requires+. Because the block is opaque,
  # RubyXL serializes one original block rather than synthesizing both +Choice+ and +Fallback+ content;
  # this prevents two branches from disagreeing after an edit.
  # http://www.datypic.com/sc/ooxml/e-ssml_ext-1.html
  class RawOOXML < OOXMLObject
    attr_accessor :raw_xml

    def self.parse(node, ignore)
      obj = new
      obj.raw_xml = node.canonicalize
      obj
    end

    def write_xml(xml, node_name_override = nil)
      self.raw_xml
    end

    def extension_relationship_ids
      RawOOXML.relationship_ids(raw_xml)
    end

    def remove_extension_relationship_ids!(ids)
      return if ids.empty?
      fragment = Nokogiri::XML::DocumentFragment.parse(raw_xml)
      removed = false

      if is_a?(AlternateContent) && fragment.xpath('.//@*[local-name()="id"]').any? {
           |attribute| attribute.namespace&.href == RELATIONSHIPS_NS && ids.include?(attribute.value)
         } then
        self.raw_xml = ''
        return true
      end

      fragment.xpath('.//@*[local-name()="id"]').each { |attribute|
        next unless attribute.namespace&.href == RELATIONSHIPS_NS && ids.include?(attribute.value)
        attribute.parent&.remove
        removed = true
      }

      self.raw_xml = fragment.canonicalize if removed
      removed
    end

    def self.relationship_ids(raw_xml)
      fragment = Nokogiri::XML::DocumentFragment.parse(raw_xml.to_s)
      fragment.xpath('.//@*[local-name()="id"]').find_all { |attribute|
        attribute.namespace&.href == RELATIONSHIPS_NS
      }.map(&:value).uniq
    end
  end

  # http://www.datypic.com/sc/ooxml/e-ssml_ext-1.html
  class Extension < RawOOXML
    define_attribute(:uri, :string)
    define_element_name 'ext'
  end

  # http://www.datypic.com/sc/ooxml/e-ssml_extLst-1.html
  class ExtensionStorageArea < OOXMLObject
    define_child_node(RubyXL::Extension, :collection => true)
    define_element_name 'extLst'

    def before_write_xml
      !(ext.nil? || ext.empty?)
    end
  end

  class AlternateContent < RawOOXML
    define_element_name 'mc:AlternateContent'
  end

  # Raised when preserved extension XML refers to a relationship that no longer has a target part.
  class ExtensionDependencyError < StandardError
    attr_reader :dependencies

    def initialize(dependencies)
      @dependencies = dependencies
      super(dependencies.map { |dependency|
              "#{dependency[:part]} requires missing relationship #{dependency[:id]} " \
              "(#{dependency[:target]}) for extension #{dependency[:extension]}"
            }.join("; "))
    end
  end

  class OOXMLIgnored < OOXMLObject
    def self.parse(node, ignore)
      nil
    end

    def write_xml(xml, node_name_override = nil)
      ''
    end
  end

  # https://msdn.microsoft.com/en-us/library/mt793297(v=office.12).aspx
  # "A CT_RevisionPtr element that specifies metadata supporting runtime scenarios for Microsoft Excel.
  # It SHOULD be ignored and SHOULD NOT be saved by all others."
  class RevisionPointer < OOXMLIgnored
    define_element_name 'xr:revisionPtr'
  end
end
