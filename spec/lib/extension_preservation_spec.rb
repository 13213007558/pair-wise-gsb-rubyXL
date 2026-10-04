# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

describe 'Extension preservation mode' do
  CUSTOM_NS = 'http://example.com/custom/1.0'
  EXT_URI = '{46BE6895-7355-4A93-B00E-2C351335B9C9}'
  MC_NS = 'http://schemas.openxmlformats.org/markup-compatibility/2006'
  X14AC_NS = 'http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac'
  REL_NS = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'

  PNG_DATA = ["89504E470D0A1A0A0000000D494844520000000100000001080600000" \
              "01F15C4890000000D49444154789C626001000000FFFF030000060005" \
              "57BFABD40000000049454E44AE426082"].pack('H*')

  before(:each) do
    RubyXL.preserve_extensions = true
    RubyXL.extension_dependency_policy = :raise
    RubyXL.class_variable_set(:@@suppress_warnings, true)

    @dir = Dir.mktmpdir
    @file = File.join(@dir, 'ext_input.xlsx')
    @out = File.join(@dir, 'ext_output.xlsx')
    build_fixture(@file)
  end

  after(:each) do
    RubyXL.preserve_extensions = false
    RubyXL.extension_dependency_policy = :raise
    RubyXL.class_variable_set(:@@suppress_warnings, false)
    FileUtils.remove_entry(@dir)
  end

  # Builds an .xlsx that mixes ordinary cells with:
  # * a custom namespace and mc:Ignorable on the worksheet root;
  # * an unknown namespaced attribute (x14ac:dyDescent) on a row;
  # * an unknown child element (cust:sheetFlag) outside any extLst;
  # * an extLst extension whose payload references an image relationship (rId10);
  # * an mc:AlternateContent wrapping dataValidations (Choice + Fallback).
  def build_fixture(path)
    wb = RubyXL::Workbook.new
    ws = wb.worksheets.first
    ws.add_cell(0, 0, 'original')
    ws.add_cell(1, 0, 123)
    wb.write(path)

    entries = {}
    Zip::File.open(path) { |zf| zf.each { |e| entries[e.name] = e.get_input_stream(&:read) } }

    sheet = entries['xl/worksheets/sheet1.xml']
    sheet.sub!(/<worksheet\b[^>]*>/) { |tag|
      "#{tag[0..-2]} xmlns:cust=\"#{CUSTOM_NS}\" mc:Ignorable=\"x14ac cust\">"
    }
    sheet.sub!(/<row r="1"/, '<row r="1" x14ac:dyDescent="0.3"')
    sheet.sub!('</worksheet>', <<-XML.gsub(/\n\s*/, ' ') + '</worksheet>')
      <cust:sheetFlag cust:level="3"/>
      <extLst>
        <ext uri="#{EXT_URI}"><cust:extData cust:version="2"><cust:pic r:embed="rId10"/><cust:note>keep me</cust:note></cust:extData></ext>
        <ext uri="{11111111-2222-3333-4444-555555555555}"><cust:safe cust:ok="1"/></ext>
      </extLst>
      <mc:AlternateContent xmlns:mc="#{MC_NS}">
        <mc:Choice Requires="x14ac"><dataValidations><dataValidation sqref="C1"/></dataValidations></mc:Choice>
        <mc:Fallback><dataValidations><dataValidation sqref="C1"/></dataValidations></mc:Fallback>
      </mc:AlternateContent>
    XML

    entries['xl/worksheets/_rels/sheet1.xml.rels'] = <<-XML.gsub(/\n\s*/, ' ')
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId10" Type="#{REL_NS}/image" Target="../media/image1.png"/>
      </Relationships>
    XML
    entries['xl/media/image1.png'] = PNG_DATA
    entries['[Content_Types].xml'].sub!('</Types>',
      '<Default Extension="png" ContentType="image/png"/></Types>')

    File.delete(path)
    Zip::File.open(path, create: true) { |zf|
      entries.each { |name, data| zf.get_output_stream(name) { |f| f.write(data) } }
    }
  end

  def read_entry(path, name)
    Zip::File.open(path) { |zf| zf.find_entry(name).get_input_stream(&:read) }
  end

  def entry_names(path)
    Zip::File.open(path) { |zf| zf.entries.map(&:name) }
  end

  def sheet_doc(path)
    Nokogiri::XML(read_entry(path, 'xl/worksheets/sheet1.xml'))
  end

  # Canonical representation of an element subtree: namespace URIs and local
  # names only (prefixes are allowed to change), attributes sorted, child
  # element order preserved.
  def canonical(node)
    attrs = node.attribute_nodes.map { |a| ["{#{a.namespace&.href}}#{a.name}", a.value] }.sort
    ["{#{node.namespace&.href}}#{node.name}", attrs, node.element_children.map { |c| canonical(c) }]
  end

  def remove_image_dependency(ws)
    ws.relationship_container.relationships.reject! { |r| r.id == 'rId10' }
    ws.generic_storage.reject! { |g| g.xlsx_path.to_s.include?('image1') }
  end

  context 'when disabled (default)' do
    it 'keeps the legacy behavior of rejecting unknown child nodes' do
      RubyXL.preserve_extensions = false
      expect { RubyXL::Parser.parse(@file) }.to raise_error(RuntimeError, /Unknown child node/)
    end
  end

  context 'round trip' do
    before(:each) do
      @wb = RubyXL::Parser.parse(@file)
      @ws = @wb['Sheet1']
      @ws.add_cell(0, 0, 'updated')
      @wb.write(@out)
      @doc = sheet_doc(@out)
    end

    it 'updates ordinary cells' do
      wb2 = RubyXL::Parser.parse(@out)
      expect(wb2['Sheet1'][0][0].value).to eq('updated')
      expect(wb2['Sheet1'][1][0].value).to eq(123)
    end

    it 'preserves mc:Ignorable and the custom namespace declaration' do
      ignorable = @doc.root.attribute_with_ns('Ignorable', MC_NS)
      expect(ignorable&.value).to eq('x14ac cust')
      expect(@doc.root.namespace_definitions.map(&:href)).to include(CUSTOM_NS)
    end

    it 'preserves unknown namespaced attributes on known elements' do
      row = @doc.at_xpath('//*[local-name()="row" and @r="1"]')
      expect(row.attribute_with_ns('dyDescent', X14AC_NS)&.value).to eq('0.3')
    end

    it 'preserves unknown child elements outside extLst' do
      flag = @doc.at_xpath('//*[local-name()="sheetFlag"]')
      expect(flag).not_to be_nil
      expect(flag.namespace.href).to eq(CUSTOM_NS)
      expect(flag.attribute_with_ns('level', CUSTOM_NS)&.value).to eq('3')
    end

    it 'preserves the extension XML semantically (URIs, order, relationship refs)' do
      original_exts = sheet_doc(@file).xpath('//*[local-name()="ext"]')
      saved_exts = @doc.xpath('//*[local-name()="ext"]')
      expect(saved_exts.size).to eq(2)
      expect(canonical(saved_exts[0])).to eq(canonical(original_exts[0]))
      expect(canonical(saved_exts[1])).to eq(canonical(original_exts[1]))

      pic = saved_exts[0].at_xpath('.//*[local-name()="pic"]')
      expect(pic.attribute_with_ns('embed', REL_NS)&.value).to eq('rId10')
    end

    it 'keeps the relationship target of the extension intact' do
      expect(entry_names(@out)).to include('xl/media/image1.png')
      rels = read_entry(@out, 'xl/worksheets/_rels/sheet1.xml.rels')
      expect(rels).to include('rId10')
    end

    it 'keeps mc:AlternateContent verbatim while the feature is not edited' do
      ac = @doc.at_xpath('//*[local-name()="AlternateContent"]')
      expect(ac).not_to be_nil
      expect(ac.at_xpath('.//*[local-name()="Choice"]')).not_to be_nil
      expect(ac.at_xpath('.//*[local-name()="Fallback"]')).not_to be_nil
    end
  end

  context 'dependency checking' do
    it 'rejects the write and reports the concrete dependency when a target is deleted' do
      wb = RubyXL::Parser.parse(@file)
      remove_image_dependency(wb['Sheet1'])

      expect { wb.write(@out) }.to raise_error(RubyXL::ExtensionDependencyError) { |error|
        expect(error.message).to include('rId10')
        expect(error.message).to include('Sheet1')
        expect(error.message).to include(EXT_URI)
        expect(error.missing_dependencies.size).to eq(1)
        expect(error.missing_dependencies.first[1]).to eq(['rId10'])
      }
      expect(File.exist?(@out)).to be(false)
    end

    it 'drops the entire offending extension when policy is :drop' do
      RubyXL.extension_dependency_policy = :drop

      wb = RubyXL::Parser.parse(@file)
      ws = wb['Sheet1']
      ws.add_cell(0, 0, 'updated')
      remove_image_dependency(ws)
      wb.write(@out)

      doc = sheet_doc(@out)
      # Only the offending extension is dropped; the unrelated one survives.
      exts = doc.xpath('//*[local-name()="ext"]')
      expect(exts.size).to eq(1)
      expect(exts.first['uri']).to eq('{11111111-2222-3333-4444-555555555555}')
      expect(doc.at_xpath('//*[local-name()="extData"]')).to be_nil
      expect(doc.at_xpath('//*[local-name()="safe"]')).not_to be_nil
      # Unrelated preserved content survives as well.
      expect(doc.at_xpath('//*[local-name()="sheetFlag"]')).not_to be_nil
      # Ordinary edits still land.
      wb2 = RubyXL::Parser.parse(@out)
      expect(wb2['Sheet1'][0][0].value).to eq('updated')
    end
  end

  context 'mc:AlternateContent policy' do
    it 'drops the stale Choice/Fallback pair when RubyXL rewrites the same feature' do
      wb = RubyXL::Parser.parse(@file)
      ws = wb['Sheet1']
      ws.data_validations ||= RubyXL::DataValidations.new
      ws.data_validations << RubyXL::DataValidation.new(:type => 'whole', :sqref => RubyXL::Sqref.new('D1'))
      wb.write(@out)

      doc = sheet_doc(@out)
      expect(doc.at_xpath('//*[local-name()="AlternateContent"]')).to be_nil
      validations = doc.xpath('//*[local-name()="dataValidations"]')
      expect(validations.size).to eq(1)
      expect(validations.first.at_xpath('.//*[local-name()="dataValidation"]')['sqref']).to eq('D1')
    end
  end
end
