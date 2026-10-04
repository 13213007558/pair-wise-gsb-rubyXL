require 'nokogiri'
require 'pathname'
require 'rubyXL/objects/reference'

module RubyXL
  module OOXMLObjectClassMethods
    # Get the value of a [sub]class variable if it exists, or create the respective variable
    # with the passed-in +default+ (or +{}+, if not specified)
    #
    # Throughout this class, we are setting class variables through explicit method calls
    # rather than by directly addressing the name of the variable because of context issues:
    # addressing variable by name creates it in the context of defining class, while calling
    # the setter/getter method addresses it in the context of descendant class,
    # which is what we need.
    def obtain_class_variable(var_name, default = nil)
      if self.class_variable_defined? var_name
        self.class_variable_get(var_name)
      else
        self.class_variable_set(var_name, default || {})
      end
    end

    # Defines an attribute of OOXML object.
    # === Parameters
    # * +attribute_name+ - Name of the element attribute as seen in the source XML. Can be either <tt>"String"</tt> or <tt>:Symbol</tt>
    #   * Special attribute name <tt>'_'</tt> (underscore) denotes the value of the element rather than attribute.
    # * +attribute_type+ - Specifies the conversion type for the attribute when parsing. Available options are:
    #   * +:int+ - <tt>Integer</tt>
    #   * +:uint+ - Unsigned <tt>Integer</tt>
    #   * +:double+ - <tt>Float</tt></u>
    #   * +:string+ - <tt>String</tt> (no conversion)
    #   * +:sqref+ - RubyXL::Sqref
    #   * +:ref+ - RubyXL::Reference
    #   * +:bool+ - <tt>Boolean</tt> ("1" and "true" convert to +true+, others to +false+)
    #   * one of +simple_types+ - <tt>String</tt>, plus the list of acceptable values is saved for future validation (not used yet).
    # * +extra_parameters+ - Hash of optional parameters as follows:
    #   * +:accessor+ - Name of the accessor for this attribute to be defined on the object. If not provided, defaults to classidied +attribute_name+.
    #   * +:default+ - Value this attribute defaults to if not explicitly provided.
    #   * +:required+ - Whether this attribute is required when writing XML. If the value of the attrinute is not explicitly provided, +:default+ is written instead.
    #   * +:computed+ - Do not store this attribute on +parse+, but do call the object-provided read accessor on +write_xml+.
    # ==== Examples
    #   define_attribute(:outline, :bool, :default => true)
    # A <tt>Boolean</tt> attribute 'outline' with default value +true+ will be accessible by calling +obj.outline+
    #   define_attribute(:uniqueCount,  :int)
    # An <tt>Integer</tt> attribute 'uniqueCount' accessible as +obj.unique_count+
    #   define_attribute(:_,  :string, :accessor => :expression)
    # The value of the element will be accessible as a <tt>String</tt> by calling +obj.expression+
    #   define_attribute(:errorStyle, %w{ stop warning information }, :default => 'stop',)
    # A <tt>String</tt> attribute named 'errorStyle' will be accessible as +obj.error_style+, valid values are <tt>"stop"</tt>, <tt>"warning"</tt>, <tt>"information"</tt>
    def define_attribute(attr_name, attr_type, extra_params = nil)
      attrs = obtain_class_variable(:@@ooxml_attributes)
      attr_hash = { :attr_type => attr_type }
      attr_hash.merge!(extra_params) if extra_params
      attr_hash[:accessor] ||= accessorize(attr_name)
      attrs[attr_name.to_s] = attr_hash
      self.send(:attr_accessor, attr_hash[:accessor]) unless attr_hash[:computed]
    end

    # Defines a `r:id` attribute
    def define_relationship(extra_params = {})
      define_attribute(:'r:id', :string, extra_params)
    end

    # Defines a child node of OOXML object.
    # === Parameters
    # * +klass+ - Class (descendant of RubyXL::OOXMLObject) of the child nodes. Child node objects will be produced by calling +parse+ method of that class.
    # * +extra_parameters+ - Hash of optional parameters as follows:
    #   * +:accessor+ - Name of the accessor for this attribute to be defined on the object. If not provided, defaults to classidied +attribute_name+.
    #   * +:node_name+ - Node name for the child node, in case it does not match the one defined by the +klass+.
    #   * +:collection+ - Whether the child node should be treated as a single node or a collection of nodes:
    #     * +false+ (default) - child node is directly accessible through the respective accessor;
    #     * +true+ - a collection of child nodes is accessed as +Array+ through the respective accessor;
    #     * +:with_count+ - same as +true+, but in addition, the attribute +count+ is defined on the current object, that will be automatically set to the number of elements in the collection at the start of +write_xml+ call.
    # ==== Examples
    #   define_child_node(RubyXL::Alignment)
    # Define a singular child node parsed by the RubyXL::BorderEdge.parse() and accessed by the default <tt>obj.alignment</tt> accessor
    #   define_child_node(RubyXL::Hyperlink, :collection => true, :accessor => :hyperlinks)
    # Define an array of nodes accessed by <tt>obj.hyperlinks</tt> accessor, each of which will be parsed by the RubyXL::Hyperlink.parse()
    #   define_child_node(RubyXL::BorderEdge, :node_name => :left)
    #   define_child_node(RubyXL::BorderEdge, :node_name => :right)
    # Use class RubyXL::BorderEdge when parsing both the elements <tt><left ...></tt> and <tt><right ...></tt> elements.
    #   define_child_node(RubyXL::Font, :collection => :with_count, :accessor => :fonts)
    # Upon writing of the object this was defined on, its <tt>count</tt> attribute will be set to the count of nodes in <tt>fonts</tt> array
    def define_child_node(klass, extra_params = {})
      child_nodes = obtain_class_variable(:@@ooxml_child_nodes)
      child_node_name = (extra_params[:node_name] || klass.class_variable_get(:@@ooxml_tag_name)).to_s
      accessor = (extra_params[:accessor] || accessorize(child_node_name)).to_sym

      child_nodes[child_node_name] = {
        :class    => klass,
        :is_array => extra_params[:collection],
        :accessor => accessor
      }

      define_count_attribute if extra_params[:collection] == :with_count

      self.send(:attr_accessor, accessor)
    end

    def define_count_attribute
      define_attribute(:count, :uint, :required => true)
    end
    private :define_count_attribute

    # Defines the name of the element that represents the current OOXML object. Should only be used once per object.
    # In case of different objects represented by the same class in different parts of OOXML tree, +:node_name+
    # extra parameter can be used to override the default element name.
    # === Parameters
    # * +element_name+
    # ==== Examples
    #   define_element_name 'externalReference'
    def define_element_name(element_name)
      self.class_variable_set(:@@ooxml_tag_name, element_name)
    end

    def parse(node, known_namespaces = nil)
      case node
      when String, IO, Zip::InputStream then node = Nokogiri::XML.parse(node)
      end

      if node.is_a?(Nokogiri::XML::Document) then
        node = node.root
#        ignorable_attr = node.attributes['Ignorable']
#        @ignorables << ignorable_attr.value if ignorable_attr
      end

      obj = self.new
      hsh = {}
      node.namespace_definitions.each { |ns| hsh[ns.href] = ns.prefix }
      obj.local_namespaces = hsh
      obj.preserve_extensions = preserve_extensions?

      known_attributes = obtain_class_variable(:@@ooxml_attributes)

      content_params = known_attributes['_']
      process_attribute(obj, node.text, content_params) if content_params

      node.attributes.each_pair { |attr_name, attr|
        attr_name = ooxml_attribute_name(attr)

        attr_params = known_attributes[attr_name]

        if attr_params.nil? then
          if obj.preserve_extensions then
            namespace = attr.namespace
            obj.preserved_attributes[attr_name] = {
              :name      => attr.name,
              :namespace => namespace && namespace.href,
              :prefix    => namespace && namespace.prefix,
              :value     => attr.value
            }
          end
          next
        end
        # raise "Unknown attribute [#{attr_name}] for element [#{node.name}]" if attr_params.nil?
        process_attribute(obj, attr.value, attr_params) unless attr_params[:computed]
      }

      known_child_nodes = obtain_class_variable(:@@ooxml_child_nodes)
      known_namespaces ||= obtain_class_variable(:@@ooxml_namespaces)

      node.element_children.each { |child_node|
        child_node_name = ooxml_child_node_name(child_node, known_namespaces)
        child_node_params = known_child_nodes[child_node_name]

        if child_node_params.nil? then
          raise "Unknown child node [#{child_node_name}] for element [#{node.name}]" unless obj.preserve_extensions
          obj.preserved_child_order << ['raw', child_node_name, child_node.canonicalize]
          next
        end

        parsed_object = child_node_params[:class].parse(child_node, known_namespaces)
        if child_node_params[:is_array] then
          index = parsed_object.index_in_collection

          collection = if (self < RubyXL::OOXMLContainerObject) then obj
                       else obj.send(child_node_params[:accessor])
                       end

          if index.nil? then
            collection << parsed_object
            stored_index = collection.size - 1
          else
            collection[index] = parsed_object
            stored_index = index
          end
          obj.preserved_child_order << ['node', child_node_params[:accessor], stored_index] if obj.preserve_extensions
        else
          obj.send("#{child_node_params[:accessor]}=", parsed_object)
          obj.preserved_child_order << ['node', child_node_params[:accessor], nil] if obj.preserve_extensions
        end
      }

      obj
    end

    def preserve_extensions?
      !!(defined?(RubyXL) && RubyXL.respond_to?(:preserve_extensions) && RubyXL.preserve_extensions)
    end

    def ooxml_attribute_name(attr)
      return attr.name if attr.namespace.nil?
      namespaces = obtain_class_variable(:@@ooxml_namespaces, nil) || {}
      prefix = namespaces[attr.namespace.href] || attr.namespace.prefix
      prefix && !prefix.empty? ? "#{prefix}:#{attr.name}" : attr.name
    end

    def ooxml_child_node_name(node, known_namespaces)
      ns = node.namespace
      prefix = if known_namespaces.has_key?(ns&.href) then known_namespaces[ns&.href]
               else ns&.prefix
               end

      case prefix
      when '', nil then node.name
      else "#{prefix}:#{node.name}"
      end
    end

    private
    def accessorize(str)
      acc = str.to_s.dup
      acc.gsub!(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2')
      acc.gsub!(/([a-z\d])([A-Z])/, '\1_\2')
      acc.gsub!(':', '_')
      acc.downcase.to_sym
    end

    def process_attribute(obj, raw_value, params)
      val = raw_value &&
              case params[:attr_type]
              when :double then Float(raw_value) # http://www.datypic.com/sc/xsd/t-xsd_double.html
              when :string then raw_value
              when Array   then raw_value # Case of Simple Types
              when :sqref  then RubyXL::Sqref.new(raw_value)
              when :ref    then RubyXL::Reference.new(raw_value)
              when :bool   then ['1', 'true'].include?(raw_value) # http://www.datypic.com/sc/xsd/t-xsd_boolean.html
              when :int    then Integer(raw_value)
              when :uint   then
                v = Integer(raw_value)
                raise ArgumentError.new("invalid value for unsigned Integer(): \"#{raw_value}\"") if v < 0
                v
              end
      obj.send("#{params[:accessor]}=", val)
    end
  end


  module OOXMLObjectInstanceMethods
    attr_accessor :local_namespaces
    attr_accessor :preserve_extensions

    def self.included(klass)
      klass.extend RubyXL::OOXMLObjectClassMethods
    end

    def obtain_class_variable(var_name, default = {})
      self.class.obtain_class_variable(var_name, default)
    end
    private :obtain_class_variable

    def initialize(params = nil)
      @local_namespaces = nil
      @preserve_extensions = self.class.send(:preserve_extensions?)
      @preserved_attributes = {}
      @preserved_child_order = []
      params ||= {}

      obtain_class_variable(:@@ooxml_attributes).each_value { |v|
        instance_variable_set("@#{v[:accessor]}", params[v[:accessor]]) unless v[:computed]
      }

      init_child_nodes(params)
    end

    def init_child_nodes(params)
      obtain_class_variable(:@@ooxml_child_nodes).each_value { |v|
        initial_value =
          if params.has_key?(v[:accessor]) then params[v[:accessor]]
          elsif v[:is_array] then []
          else nil
          end

        instance_variable_set("@#{v[:accessor]}", initial_value)
      }
    end
    private :init_child_nodes

    def preserved_attributes
      @preserved_attributes ||= {}
    end

    def preserved_child_order
      @preserved_child_order ||= []
    end

    def preserve_whitespace
      self.xml_space = (value.is_a?(String) && ((value =~ /\A\s/) || (value =~ /\s\Z/) || value.include?("\n"))) ? 'preserve' : nil
    end
    private :preserve_whitespace

    def ==(other)
      other.is_a?(self.class) &&
        obtain_class_variable(:@@ooxml_attributes).all? { |_k, v| self.send(v[:accessor]) == other.send(v[:accessor]) } &&
        obtain_class_variable(:@@ooxml_child_nodes).all? { |_k, v| self.send(v[:accessor]) == other.send(v[:accessor]) }
    end

    # Recursively write the OOXML object and all its children out as Nokogiri::XML. Immediately before the actual
    # generation, +before_write_xml()+ is called to perform last-minute cleanup and validation operations; if it
    # returns +false+, an empty string is returned (rather than +nil+, so Nokogiri::XML's <tt>&lt;&lt;</tt> operator
    # can be used without additional +nil+ checking)
    # === Parameters
    # * +xml+ - Base Nokogiri::XML object used for building. If omitted, a blank document will be generated.
    # * +node_name_override+ - if present, is used instead of the default element name for this object provided by +define_element_name+
    # ==== Examples
    #   obj.write_xml()
    # Creates a new empty +Nokogiri::XML+, populates it with the OOXML structure as described in the respective definition, and returns the resulting +Nokogiri::XML+ object.
    #   obj.write_xml(seed_xml)
    # Using the passed-in +Nokogiri+ +xml+ object, creates a new element corresponding to +obj+ according to its definition, along with all its properties and children, and returns the newly created element.
    #   obj.write_xml(seed_xml, 'overriden_element_name')
    # Same as above, but uses the passed-in +node_name_override+ as the new element name, instead of its default name set by +define_element_name+.
    def write_xml(xml = nil, node_name_override = nil)
      if xml.nil? then
        seed_xml = Nokogiri::XML('<?xml version = "1.0" standalone ="yes"?>')
        seed_xml.encoding = 'UTF-8'

        if Nokogiri.jruby? then # Issue 188 workaround for JRuby
          seed_xml.to_java.strict_error_checking = false
        end

        result = self.write_xml(seed_xml)
        return result if result == ''
        seed_xml << result
        return seed_xml.to_xml({ :indent => 0, :save_with => Nokogiri::XML::Node::SaveOptions::AS_XML })
      end

      return '' unless before_write_xml

      attrs = {}

      obtain_class_variable(:@@ooxml_attributes).each_pair { |k, v|
        val = self.send(v[:accessor])

        if val.nil? then
          next unless v[:required]
          val = v[:default]
        end

        val = val &&
                case v[:attr_type]
                when :bool   then val ? '1' : '0'
                when :double then val.to_s.gsub(/\.0*\Z/, '') # Trim trailing zeroes
                else val
                end

        attrs[k] = val
      }

      element_text = attrs.delete('_')
      elem = xml.create_element(node_name_override || obtain_class_variable(:@@ooxml_tag_name), attrs, element_text)

      # First, populate namespaces from the original document
      @local_namespaces&.each_pair { |href, prefix| elem.add_namespace_definition(prefix, href) }

      # Then, add defaults. Note that if some namespace prefix was already set, Nokogiri will NOT change that namespace.
      obtain_class_variable(:@@ooxml_namespaces).each_pair { |href, prefix| elem.add_namespace_definition(prefix, href) }

      preserved_attributes.each_value { |attribute_params|
        attribute_name = attribute_params[:name]
        namespace_href = attribute_params[:namespace]
        if namespace_href then
          prefix = namespace_prefix(elem, namespace_href) || attribute_params[:prefix]
          attribute_name = "#{prefix}:#{attribute_name}" if prefix && !prefix.empty?
        end
        elem[attribute_name] = attribute_params[:value]
      }

      child_nodes = obtain_class_variable(:@@ooxml_child_nodes)
      written_nodes = Hash.new { |hash, key| hash[key] = [] }
      write_unpreserved_children(xml, elem, child_nodes, written_nodes)
      elem
    end

    def write_unpreserved_children(xml, elem, child_nodes, written_nodes)
      slot_index = 0

      child_nodes.each_pair { |child_node_name, child_node_params|
        slot_index = write_children_until(xml, elem, child_node_params[:accessor], child_nodes, written_nodes, slot_index)
        write_unpreserved_child(xml, elem, child_node_name, child_node_params, written_nodes)
      }

      while slot_index < preserved_child_order.size
        _kind, _accessor, raw_xml = preserved_child_order[slot_index]
        elem << xml.fragment(raw_xml)
        slot_index += 1
      end
    end
    private :write_unpreserved_children

    def write_children_until(xml, elem, current_accessor, child_nodes, written_nodes, slot_index)
      while slot_index < preserved_child_order.size
        kind, accessor, index = preserved_child_order[slot_index]
        break unless kind == 'raw' || accessor == current_accessor

        if kind == 'raw' then
          elem << xml.fragment(index)
        else
          child_node_name, child_node_params = child_nodes.find { |_name, params| params[:accessor] == accessor }
          write_modeled_child(xml, elem, child_node_name, child_node_params, index, written_nodes)
        end
        slot_index += 1
      end
      slot_index
    end
    private :write_children_until

    def write_unpreserved_child(xml, elem, child_node_name, child_node_params, written_nodes)
      if child_node_params[:is_array] then
        collection = get_node_object(child_node_params)
        return unless collection
        collection.each_with_index { |item, index|
          next if written_nodes[child_node_params[:accessor]].include?(index)
          append_modeled_child(xml, elem, child_node_name, item)
        }
      else
        return if written_nodes[child_node_params[:accessor]].include?(0)
        append_modeled_child(xml, elem, child_node_name, get_node_object(child_node_params))
      end
    end
    private :write_unpreserved_child

    def write_modeled_child(xml, elem, child_node_name, child_node_params, index, written_nodes)
      if child_node_params[:is_array] then
        collection = get_node_object(child_node_params)
        item = collection&.at(index)
        written_nodes[child_node_params[:accessor]] << index
      else
        item = get_node_object(child_node_params)
        written_nodes[child_node_params[:accessor]] << 0
      end
      append_modeled_child(xml, elem, child_node_name, item)
    end
    private :write_modeled_child

    def append_modeled_child(xml, elem, child_node_name, item)
      return if item.nil?
      if item.respond_to?(:write_xml) && !item.equal?(self) then
        elem << item.write_xml(xml, child_node_name)
      else
        item.each { |child| elem << child.write_xml(xml, child_node_name) unless child.nil? }
      end
    end
    private :append_modeled_child

    def namespace_prefix(elem, href)
      namespace = elem.namespace_definitions.find { |definition| definition.href == href }
      return namespace.prefix if namespace
      nil
    end
    private :namespace_prefix

    # Prototype method. For sparse collections (+Rows+, +Cells+, etc.) must return index at which this object
    # is expected to reside in the collection. If +nil+ is returned, then object is simply added
    # to the end of the collection.
    def index_in_collection
      nil
    end

    def get_node_object(child_node_params)
      self.send(child_node_params[:accessor])
    end
    private :get_node_object

    # Subclass provided filter to perform last-minute operations (cleanup, count, etc.) immediately prior to write,
    # along with option to terminate the actual write if +false+ is returned (for example, to avoid writing
    # the collection's root node if the collection is empty).
    def before_write_xml
      #TODO# This will go away once containers are fully implemented.
      child_nodes = obtain_class_variable(:@@ooxml_child_nodes)
      child_nodes.each_pair { |_child_node_name, child_node_params|
        self.count = self.send(child_node_params[:accessor]).size if child_node_params[:is_array] == :with_count
      }
      true
    end
  end

  # Parent class for defining OOXML based objects (not unlike Rails' +ActiveRecord+!)
  # Most importantly, provides functionality of parsing such objects from XML,
  # and marshalling them to XML.
  class OOXMLObject
    include OOXMLObjectInstanceMethods
  end

  # Parent class for OOXML container objects (for example,
  # <tt>&lt;fonts&gt;&lt;font&gt;...&lt;/font&gt;&lt;font&gt;...&lt;/font&gt;&lt;/fonts&gt;</tt>
  # that obscures the top-level container, allowing direct access to the contents as +Array+.
  class OOXMLContainerObject < Array
    include OOXMLObjectInstanceMethods

    def initialize(params = {})
      array_content = params.delete(:_)
      super
      array_content.each_with_index { |v, i| self[i] = v } if array_content
    end

    def get_node_object(child_node_params)
      if child_node_params[:is_array] then self
      else super
      end
    end
    protected :get_node_object

    def init_child_nodes(params)
      obtain_class_variable(:@@ooxml_child_nodes).each_value { |v|
        next if v[:is_array] # Only one collection node allowed per OOXMLContainerObject, and it is contained in itself.
        instance_variable_set("@#{v[:accessor]}", params[v[:accessor]])
      }
    end
    protected :init_child_nodes

    def before_write_xml
      true
    end

    def inspect
      vars = [ super ]
      vars = self.instance_variables.each { |v| vars << "#{v}=#{instance_variable_get(v).inspect}" }
      "<#{self.class}: #{super} #{vars.join(", ")}>"
    end

    class << self
      def define_count_attribute
        # Count will be inherited from Array. so no need to define it explicitly.
        define_attribute(:count, :uint, :required => true, :computed => true)
      end
      protected :define_count_attribute
    end
  end

  # Extension class providing functionality for top-level OOXML objects that are represented by
  # their own <tt>.xml</tt> files in <tt>.xslx</tt> zip container.
  class OOXMLTopLevelObject < OOXMLObject
    SAVE_ORDER = 500
    ROOT = ::Pathname.new('/')

    attr_accessor :root

    # Prototype method. For top-level OOXML object, returns the path at which the current object's XML file
    # is located within the <tt>.xlsx</tt> zip container.
    def xlsx_path
      raise 'Subclass responsebility'
    end

    # Sets the list of namespaces on this object to be added when writing out XML. Valid only on top-level objects.
    # === Parameters
    # * +namespace_hash+ - Hash of namespaces in the form of <tt>"url" => "prefix"</tt>
    # ==== Examples
    #   set_namespaces('http://schemas.openxmlformats.org/spreadsheetml/2006/main' => nil,
    #                  'http://schemas.openxmlformats.org/officeDocument/2006/relationships' => 'r')
    def self.set_namespaces(namespace_hash)
      self.class_variable_set(:@@ooxml_namespaces, namespace_hash)
    end

    # Generates the top-level OOXML object by parsing its XML file from the contents of the <tt>.xslx</tt> container.
    # === Parameters
    # * +zip_file+ - <tt>.xslx</tt> file as <tt>Zip::File</tt> object
    # * +file_path+ - path to the subject file inside the <tt>.xslx</tt> zip archive
    def self.parse_file(zip_file, file_path)
      entry = zip_file.find_entry(RubyXL::from_root(file_path))
      # Accomodate for Nokogiri Java implementation which is incapable of reading from a stream
      entry && (entry.get_input_stream { |f| parse(defined?(JRUBY_VERSION) ? f.read : f) })
    end

    # Saves the contents of the object as XML to respective location in <tt>.xslx</tt> zip container.
    # === Parameters
    # * +zipfile+ - ::Zip::File to which the resulting XNMML should be added.
    def add_to_zip(zip_stream)
      xml_string = write_xml
      return false if xml_string.empty?
      zip_stream.put_next_entry(RubyXL::from_root(self.xlsx_path))
      zip_stream.write(xml_string)
      true
    end

    def file_index
      root.rels_hash[self.class].index{ |f| f.equal?(self) }.to_i + 1
    end
  end
end
