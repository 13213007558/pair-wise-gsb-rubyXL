require 'rubyXL/objects/ooxml_object'

module RubyXL
  # Namespace URI of OOXML relationship references (r:id / r:embed / r:link).
  RELATIONSHIPS_NAMESPACE = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'.freeze

  # Functionality shared by all preserved extension payloads: scanning the raw
  # XML for relationship references, and detaching the payload from its parent
  # object (used when a dangling dependency is found and the caller opted for
  # RubyXL.extension_dependency_policy = :drop).
  module ExtensionPreservation
    # Attribute local names that, in the relationships namespace, carry an rId.
    RELATIONSHIP_ATTRIBUTES = %w{id embed link}.freeze

    attr_accessor :parent_object

    # rIds of relationships this payload depends on. An attribute is treated as
    # a relationship reference when it lives in the relationships namespace, or
    # when its namespace could not be resolved from the raw fragment but it
    # looks like a relationship attribute (id/embed/link) with an rId value.
    def referenced_rids
      rids = []
      Nokogiri::XML::DocumentFragment.parse(raw_xml).traverse { |node|
        node.attribute_nodes.each { |attr|
          next unless attr.value =~ /\ArId\d+\z/
          ns = attr.namespace
          # When the prefix is not bound inside the fragment, Nokogiri keeps it
          # as part of the attribute name; fall back to matching the local name.
          local_name = attr.name.split(':', 2).last
          next unless (ns && ns.href == RELATIONSHIPS_NAMESPACE) ||
                      (ns.nil? && RELATIONSHIP_ATTRIBUTES.include?(local_name))
          rids << attr.value
        }
      }
      rids.uniq
    end

    # Removes this payload from the object that owns it.
    def detach!
      parent_object && parent_object.send(:remove_preserved_child, self)
    end

    # Short human-readable description used in dependency error reports.
    def extension_description
      root = Nokogiri::XML::DocumentFragment.parse(raw_xml).element_children.first
      return self.class.name if root.nil?
      uri = root['uri']
      uri ? "#{root.name} (uri=#{uri})" : root.name
    end
  end

  # Raised when a preserved extension references a relationship (rId) that no
  # longer exists in the owning part, and RubyXL.extension_dependency_policy is
  # +:raise+. Carries the offending part and the list of
  # [extension, missing_rids] pairs in #missing_dependencies.
  class ExtensionDependencyError < StandardError
    attr_reader :part, :missing_dependencies

    def initialize(part, offenders)
      @part = part
      @missing_dependencies = offenders
      details = offenders.map { |ext, rids|
        "#{ext.extension_description} -> #{rids.join(', ')}"
      }.join('; ')
      super("Preserved extension(s) in #{self.class.describe_part(part)} reference missing relationship(s): #{details}. " \
            'Restore the relationship target(s), or set RubyXL.extension_dependency_policy = :drop ' \
            'to remove the offending extension(s) instead.')
    end

    # Best-effort human-readable identification of the offending part.
    # +xlsx_path+ may be unavailable outside of a write (it depends on the
    # relationship index), so fall back to the class and sheet name.
    def self.describe_part(part)
      path = begin
        part.xlsx_path.to_s
      rescue StandardError
        nil
      end
      path ||= part.class.name
      part.respond_to?(:sheet_name) && part.sheet_name ? "#{path} (#{part.sheet_name})" : path
    end
  end

  # A child element RubyXL does not understand, captured verbatim (together
  # with its position relative to other unknown siblings) so it can be written
  # back with the part it was found on.
  class PreservedNode
    include ExtensionPreservation

    attr_accessor :raw_xml

    def initialize(node, parent)
      self.raw_xml = node.to_xml
      self.parent_object = parent
    end
  end

  # http://www.datypic.com/sc/ooxml/e-ssml_ext-1.html
  class RawOOXML < OOXMLObject
    include ExtensionPreservation

    attr_accessor :raw_xml

    def self.parse(node, ignore)
      obj = new
      obj.raw_xml = node.to_xml
      obj
    end

    def write_xml(xml, node_name_override = nil)
      self.raw_xml
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
      # Do not emit an empty <extLst/> (for example, after all extensions were
      # dropped by the dependency policy).
      !ext.empty? || !unknown_children.empty?
    end
  end

  class AlternateContent < RawOOXML
    define_element_name 'mc:AlternateContent'
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
