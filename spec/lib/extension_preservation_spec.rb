# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

describe 'Extension preservation' do
  let(:custom_ignorable_ns) { 'https://example.test/ignorable' }
  let(:custom_extension_ns) { 'https://example.test/picture' }
  let(:gif) { 'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'.unpack1('m') }

  def create_workbook(path)
    workbook = RubyXL::Workbook.new
    worksheet = workbook[0]
    worksheet.add_cell(0, 0, 'old value')
    worksheet.add_cell(0, 1, 'ordinary value')
    workbook.save(path)
  end

  def add_extension_fixture(path)
    Zip::File.open(path) do |zip|
      doc = Nokogiri::XML(zip.read('xl/worksheets/sheet1.xml'))
      root = doc.root
      root.add_namespace_definition('z9', custom_ignorable_ns)
      root.add_namespace_definition('p9', custom_extension_ns)
      root.add_namespace_definition('alt', 'http://schemas.openxmlformats.org/markup-compatibility/2006')
      root['mc:Ignorable'] = 'z9'
      root['z9:label'] = 'ignored-root-property'
      root['r:unknownId'] = 'rIdExt1'

      sheet_data = root.at_xpath('xmlns:sheetData', :xmlns => 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
      widget = Nokogiri::XML::Node.new('z9:widget', doc)
      widget['z9:name'] = 'widget-before-sheet-data'
      widget['r:id'] = 'rIdExt1'
      sheet_data.previous = widget

      extension = <<~XML
        <extLst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <ext uri="#{custom_extension_ns}"
               xmlns:p9="#{custom_extension_ns}"
               xmlns:z9="#{custom_ignorable_ns}"
               xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <p9:picture r:id="rIdExt1" z9:ignored="yes">
              <p9:name>Extension picture</p9:name>
            </p9:picture>
          </ext>
        </extLst>
      XML
      root << Nokogiri::XML::DocumentFragment.parse(extension)

      alternate = <<~XML
        <alt:AlternateContent
            xmlns:alt="http://schemas.openxmlformats.org/markup-compatibility/2006"
            xmlns:p9="#{custom_extension_ns}"
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <alt:Choice Requires="p9">
            <p9:fallback-picture r:id="rIdExt2" />
          </alt:Choice>
          <alt:Fallback>
            <picture legacyId="rIdExt2" />
          </alt:Fallback>
        </alt:AlternateContent>
      XML
      root << Nokogiri::XML::DocumentFragment.parse(alternate)

      zip.get_output_stream('xl/worksheets/sheet1.xml') { |file| file.write(doc.to_xml) }
      zip.get_output_stream('xl/media/ext1.gif') { |file| file.write(gif) }
      zip.get_output_stream('xl/media/ext2.gif') { |file| file.write(gif) }
      zip.get_output_stream('xl/worksheets/_rels/sheet1.xml.rels') { |file| file.write <<~XML }
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rIdExt1"
                        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
                        Target="../media/ext1.gif" />
          <Relationship Id="rIdExt2"
                        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
                        Target="../media/ext2.gif" />
        </Relationships>
      XML

      content_types = Nokogiri::XML(zip.read('[Content_Types].xml'))
      unless content_types.root.css('Default[Extension="gif"]').any?
        default = Nokogiri::XML::Node.new('Default', content_types)
        default['Extension'] = 'gif'
        default['ContentType'] = 'image/gif'
        content_types.root << default
        zip.get_output_stream('[Content_Types].xml') { |file| file.write(content_types.to_xml) }
      end
    end
  end

  def worksheet_xml(zip)
    Nokogiri::XML(zip.read('xl/worksheets/sheet1.xml')).root
  end

  def relationships_xml(zip)
    Nokogiri::XML(zip.read('xl/worksheets/_rels/sheet1.xml.rels')).root
  end

  def semantic_signature(node)
    [
      node.namespace&.href,
      node.name,
      node.attribute_nodes.map {
        |attribute| [attribute.namespace&.href, attribute.name, attribute.value]
      }.sort_by { |namespace, name, _value| [namespace.to_s, name] },
      node.element_children.map { |child| semantic_signature(child) }
    ]
  end

  it 'edits ordinary cells while preserving extension XML, ordering, and relationship targets' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'source.xlsx')
      output = File.join(dir, 'output.xlsx')
      create_workbook(source)
      add_extension_fixture(source)

      original_zip = Zip::File.open(source)
      original = worksheet_xml(original_zip)
      workbook = RubyXL::Parser.parse(source, :preserve_extensions => true)
      workbook[0][0][0].raw_value = 'new value'
      workbook.save(output)

      Zip::File.open(output) do |zip|
        saved = worksheet_xml(zip)
        relationships = relationships_xml(zip)

        original_value = original.at_xpath('xmlns:sheetData//xmlns:v', :xmlns => 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
        original_value.content = 'new value'
        expect(semantic_signature(saved)).to eq(semantic_signature(original))
        expect(saved.element_children.map { |element| [element.namespace.href, element.name] }).to eq(
          original.element_children.map { |element| [element.namespace.href, element.name] }
        )
        expect(saved.namespaces.transform_values(&:to_s)).to eq(original.namespaces.transform_values(&:to_s))
        expect(saved.attribute('Ignorable').value).to eq('z9')
        expect(saved.attribute_with_ns('label', custom_ignorable_ns).value).to eq('ignored-root-property')
        expect(saved.attribute_with_ns('unknownId', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships').value).to eq('rIdExt1')
        expect(saved.css('mc|AlternateContent mc|Choice', 'mc' => 'http://schemas.openxmlformats.org/markup-compatibility/2006').size).to eq(1)
        expect(saved.css('mc|AlternateContent mc|Fallback', 'mc' => 'http://schemas.openxmlformats.org/markup-compatibility/2006').size).to eq(1)
        expect(saved.at_xpath('.//p9:picture[@r:id="rIdExt1"]',
                               :p9 => custom_extension_ns,
                               :r => 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')).not_to be_nil
        expect(relationships.css('Relationship[Id="rIdExt1"]').first['Target']).to eq('../media/ext1.gif')
        expect(relationships.css('Relationship[Id="rIdExt2"]').first['Target']).to eq('../media/ext2.gif')
        expect(zip.find_entry('xl/media/ext1.gif').get_input_stream.read).to eq(gif)
        expect(zip.find_entry('xl/media/ext2.gif').get_input_stream.read).to eq(gif)
        content_types = Nokogiri::XML(zip.read('[Content_Types].xml')).root
        expect(content_types.css('Default[Extension="gif"]').first['ContentType']).to eq('image/gif')
      end

      reopened = RubyXL::Parser.parse(output, :preserve_extensions => true)
      expect(reopened[0][0][0].value).to eq('new value')
      expect(reopened[0][0][1].value).to eq('ordinary value')
    ensure
      original_zip&.close
    end
  end

  it 'reports missing extension targets and can drop the dependent extension blocks' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'source.xlsx')
      rejected = File.join(dir, 'rejected.xlsx')
      dropped = File.join(dir, 'dropped.xlsx')
      create_workbook(source)
      add_extension_fixture(source)

      workbook = RubyXL::Parser.parse(source, :preserve_extensions => true)
      workbook[0].generic_storage.reject! { |object| object.xlsx_path.to_s.end_with?('ext1.gif') }

      expect {
        workbook.save(rejected)
      }.to raise_error(RubyXL::ExtensionDependencyError) { |error|
        expect(error.dependencies).to contain_exactly(include(
          :part => 'xl/worksheets/sheet1.xml',
          :id => 'rIdExt1',
          :target => '<relationship removed>'
        ))
      }
      expect(File.exist?(rejected)).to be(false)

      workbook.save(dropped, :drop_missing_extensions => true)
      Zip::File.open(dropped) do |zip|
        saved = worksheet_xml(zip)
        relationships = relationships_xml(zip)
        expect(saved.at_xpath('.//p9:picture', :p9 => custom_extension_ns)).to be_nil
        expect(saved.at_xpath('.//z9:widget', :z9 => custom_ignorable_ns)).to be_nil
        expect(relationships.css('Relationship').map { |relationship| relationship['Id'] }).to eq(['rIdExt2'])
        expect(zip.find_entry('xl/media/ext1.gif')).to be_nil
        expect(zip.find_entry('xl/media/ext2.gif')).not_to be_nil
      end
    end
  end
end
