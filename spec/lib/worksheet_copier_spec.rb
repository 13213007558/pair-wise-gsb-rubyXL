# frozen_string_literal: true

require 'spec_helper'
require 'rubyXL/convenience_methods'
require 'digest'

describe RubyXL::WorksheetCopier do
  PNG_SOURCE = ("\x89PNG\r\n\x1a\n" + 'SOURCE-IMAGE-DATA' * 10).b
  PNG_TARGET = ("\x89PNG\r\n\x1a\n" + 'TARGET-IMAGE-DATA-THAT-DIFFERS' * 10).b

  TMP_DIR = File.expand_path('../../.tmp/worksheet_copier_spec', __dir__)

  before(:all) do
    FileUtils.mkdir_p(TMP_DIR)
  end

  after(:all) do
    FileUtils.rm_rf(TMP_DIR)
  end

  def drawing_xml(rid)
    %(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><xdr:twoCellAnchor><xdr:from><xdr:col>1</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>1</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:to><xdr:col>3</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>5</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to><xdr:pic><xdr:nvPicPr><xdr:cNvPr id="2" name="Pic 1"/><xdr:cNvPicPr/></xdr:nvPicPr><xdr:blipFill><a:blip r:embed="#{rid}"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill><xdr:spPr><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/></xdr:twoCellAnchor></xdr:wsDr>)
  end

  # Attaches a drawing with one image to the worksheet. Both workbooks use the same
  # part names (drawing1.xml, image1.png) but different image bytes.
  def attach_image(worksheet, png_bytes, rel_id)
    drawing = RubyXL::DrawingFile.new(Pathname('/xl/drawings/drawing1.xml'), drawing_xml('rId1'))
    drawing_rels = RubyXL::OOXMLRelationshipsFile.new
    drawing_rels.relationships << RubyXL::Relationship.new(:id => 'rId1', :type => RubyXL::BinaryImageFile::REL_TYPE,
                                                           :target => '../media/image1.png')
    drawing.relationship_container = drawing_rels
    image = RubyXL::BinaryImageFile.new(Pathname('/xl/media/image1.png'), png_bytes)
    image.content_type = 'image/png'
    drawing.generic_storage = [image]
    worksheet.generic_storage << drawing
    worksheet.relationship_container ||= RubyXL::OOXMLRelationshipsFile.new
    worksheet.relationship_container.relationships <<
      RubyXL::Relationship.new(:id => rel_id, :type => RubyXL::DrawingFile::REL_TYPE,
                               :target => '../drawings/drawing1.xml')
    worksheet.drawing = RubyXL::RID.new(:r_id => rel_id)
  end

  def attach_comment(worksheet, text, rel_id)
    comments = RubyXL::CommentsFile.new
    comments.authors = RubyXL::Authors.new(:_ => [RubyXL::StringNode.new(:value => 'tester')])
    comments.comment_list = RubyXL::CommentList.new(:_ => [
      RubyXL::Comment.new(:ref => RubyXL::Reference.new('A1'), :author_id => 0,
                          :text => RubyXL::RichText.new(:t => RubyXL::Text.new(:value => text)))
    ])
    worksheet.comments << comments
    worksheet.relationship_container ||= RubyXL::OOXMLRelationshipsFile.new
    worksheet.relationship_container.relationships <<
      RubyXL::Relationship.new(:id => rel_id, :type => RubyXL::CommentsFile::REL_TYPE,
                               :target => '../comments1.xml')
  end

  def attach_hyperlink(worksheet, rel_id, url, ref, location = nil)
    worksheet.relationship_container ||= RubyXL::OOXMLRelationshipsFile.new
    worksheet.relationship_container.relationships <<
      RubyXL::Relationship.new(:id => rel_id, :type => RubyXL::HyperlinkRelFile::REL_TYPE,
                               :target => url, :target_mode => 'External')
    worksheet.hyperlinks ||= RubyXL::Hyperlinks.new
    worksheet.hyperlinks << RubyXL::Hyperlink.new(:ref => RubyXL::Reference.new(ref), :r_id => rel_id,
                                                  :location => location)
  end

  def add_shared_string_cell(workbook, worksheet, row, col, str)
    index = workbook.shared_strings_container.get_index(str, true)
    cell = worksheet.add_cell(row, col)
    cell.datatype = RubyXL::DataType::SHARED_STRING
    cell.raw_value = index.to_s
    cell
  end

  def add_number_format_style(workbook, cell, format_code)
    stylesheet = workbook.stylesheet
    fmt_id = stylesheet.register_number_format(format_code)
    xf = stylesheet.cell_xfs[cell.style_index || 0].dup
    xf.num_fmt_id = fmt_id
    xf.apply_number_format = true
    cell.style_index = workbook.register_new_xf(xf)
    fmt_id
  end

  def build_source_workbook(path)
    workbook = RubyXL::Workbook.new
    worksheet = workbook[0]
    worksheet.sheet_name = 'Report'

    add_shared_string_cell(workbook, worksheet, 0, 0, 'hello')
    add_shared_string_cell(workbook, worksheet, 1, 0, 'world')
    styled = worksheet.add_cell(2, 0, 42)
    add_number_format_style(workbook, styled, '0.000"uA"')
    worksheet.add_cell(3, 0, 0, 'Report!A1+1')

    attach_image(worksheet, PNG_SOURCE, 'rId5')
    attach_comment(worksheet, 'a note', 'rId6')
    attach_hyperlink(worksheet, 'rId7', 'https://example.com', 'B2')
    worksheet.hyperlinks << RubyXL::Hyperlink.new(:ref => RubyXL::Reference.new('B3'),
                                                  :location => 'Report!A1')

    workbook.add_worksheet('Data')
    workbook.save(path)
    workbook
  end

  def build_target_workbook(path)
    workbook = RubyXL::Workbook.new
    worksheet = workbook[0]
    worksheet.sheet_name = 'Existing'

    add_shared_string_cell(workbook, worksheet, 0, 0, 'hello') # Same string as source: must be reused.
    styled = worksheet.add_cell(1, 0, 7)
    add_number_format_style(workbook, styled, '0.0"uA"') # Same custom id as source's, different content.

    attach_image(worksheet, PNG_TARGET, 'rId5') # Same part names as source, different bytes.

    workbook.save(path)
    workbook
  end
  ### ZIP/XML level verification helpers ###

  def rels_path_for(part_name)
    dir = File.dirname(part_name)
    File.join(dir, '_rels', "#{File.basename(part_name)}.rels")
  end

  def resolve_part(base_part, target)
    path = Pathname(target)
    path = (Pathname('/' + File.dirname(base_part)) + path).cleanpath if path.relative?
    path.to_s.sub(%r{\A/}, '')
  end

  def relationships_in(zip, rels_entry)
    doc = Nokogiri::XML(zip.read(rels_entry))
    doc.xpath('//*[local-name()="Relationship"]')
  end

  def assert_all_relationships_resolve(xlsx_path)
    Zip::File.open(xlsx_path) do |zip|
      zip.each do |entry|
        next unless entry.name.end_with?('.rels')
        owner_dir = File.dirname(File.dirname(entry.name))
        owner_dir = '' if owner_dir == '.'
        relationships_in(zip, entry.name).each do |rel|
          next if rel['TargetMode'] == 'External'
          resolved = (Pathname("/#{owner_dir}") + rel['Target']).cleanpath.to_s.sub(%r{\A/}, '')
          expect(zip.find_entry(resolved)).not_to be_nil,
            "dangling relationship in #{entry.name}: #{rel['Id']} -> #{rel['Target']}"
        end
      end
    end
  end

  # Follow sheet -> drawing -> image relationships in a saved package and return
  # the media part name the sheet's picture ultimately points to.
  def image_part_for_sheet(zip, sheet_name)
    workbook_doc = Nokogiri::XML(zip.read('xl/workbook.xml'))
    sheet_rid = workbook_doc.xpath('//*[local-name()="sheet"]').find { |s| s['name'] == sheet_name }['id'] ||
                workbook_doc.xpath('//*[local-name()="sheet"]').find { |s| s['name'] == sheet_name }
                  .attribute_with_ns('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships').value
    wb_rels = relationships_in(zip, 'xl/_rels/workbook.xml.rels')
    sheet_path = resolve_part('xl/workbook.xml', wb_rels.find { |r| r['Id'] == sheet_rid }['Target'])

    sheet_rels = relationships_in(zip, rels_path_for(sheet_path))
    drawing_rel = sheet_rels.find { |r| r['Type'].end_with?('/drawing') }
    return nil if drawing_rel.nil?
    drawing_path = resolve_part(sheet_path, drawing_rel['Target'])

    drawing_rels = relationships_in(zip, rels_path_for(drawing_path))
    image_rel = drawing_rels.find { |r| r['Type'].end_with?('/image') }
    resolve_part(drawing_path, image_rel['Target'])
  end

  def media_parts(zip)
    zip.map(&:name).select { |n| n.start_with?('xl/media/') }
  end

  ### Test fixtures ###

  let(:source_path) { File.join(TMP_DIR, 'source.xlsx') }
  let(:target_path) { File.join(TMP_DIR, 'target.xlsx') }
  let(:output_path) { File.join(TMP_DIR, 'output.xlsx') }

  let!(:source_digest) do
    build_source_workbook(source_path)
    Digest::SHA256.file(source_path).hexdigest
  end

  let!(:target_workbook) do
    build_target_workbook(target_path)
    RubyXL::Parser.parse(target_path)
  end

  let(:source_workbook) { RubyXL::Parser.parse(source_path) }

  describe '#copy_worksheet_from' do
    it 'copies the worksheet with its cells into the target workbook' do
      new_sheet = target_workbook.copy_worksheet_from(source_workbook, 'Report')

      expect(new_sheet.sheet_name).to eq('Report')
      expect(target_workbook.worksheets.last).to equal(new_sheet)
      expect(target_workbook.worksheets.map(&:sheet_name)).to eq([ 'Existing', 'Report' ])
      expect(new_sheet[0][0].value).to eq('hello')
      expect(new_sheet[1][0].value).to eq('world')
      expect(new_sheet[2][0].value).to eq(42)
    end

    it 'accepts a worksheet object directly and de-duplicates the sheet name' do
      first = target_workbook.copy_worksheet_from(source_workbook['Report'])
      second = target_workbook.copy_worksheet_from(source_workbook['Report'])

      expect(first.sheet_name).to eq('Report')
      expect(second.sheet_name).to eq('Report (2)')
    end

    it 'renames the sheet with :as and remaps self-references to the new sheet' do
      new_sheet = target_workbook.copy_worksheet_from(source_workbook, 'Report', :as => 'Imported')

      expect(new_sheet.sheet_name).to eq('Imported')
      expect(new_sheet[3][0].formula.expression).to eq('Imported!A1+1')
      internal_link = new_sheet.hyperlinks.find { |h| h.location }
      expect(internal_link.location).to eq('Imported!A1')
    end

    it 'merges shared strings by content' do
      target_workbook.copy_worksheet_from(source_workbook, 'Report')
      target_workbook.save(output_path)

      output = RubyXL::Parser.parse(output_path)
      strings = output.shared_strings_container.strings.map(&:to_s)
      expect(strings.count('hello')).to eq(1)
      expect(strings.count('world')).to eq(1)
      expect(output['Report'][0][0].value).to eq('hello')
      expect(output['Report'][1][0].value).to eq('world')
    end

    it 'merges styles by content, not by id or name' do
      target_workbook.copy_worksheet_from(source_workbook, 'Report')
      target_workbook.save(output_path)

      output = RubyXL::Parser.parse(output_path)
      # Same custom numFmt id in both workbooks, different codes: both must survive.
      codes = output.stylesheet.number_formats.map(&:format_code)
      expect(codes).to include('0.0"uA"')
      expect(codes).to include('0.000"uA"')
      # The copied cell keeps its own format; the pre-existing cell is untouched.
      expect(output['Report'][2][0].number_format.format_code).to eq('0.000"uA"')
      expect(output['Existing'][1][0].number_format.format_code).to eq('0.0"uA"')
    end

    it 'copies comments' do
      target_workbook.copy_worksheet_from(source_workbook, 'Report')
      target_workbook.save(output_path)

      output = RubyXL::Parser.parse(output_path)
      comments = output['Report'].comments
      expect(comments.size).to eq(1)
      expect(comments.first.comment_list.first.text.to_s).to eq('a note')
      expect(comments.first.authors.first.value).to eq('tester')
    end

    it 'copies external hyperlinks and remaps internal ones' do
      target_workbook.copy_worksheet_from(source_workbook, 'Report', :as => 'Imported')
      target_workbook.save(output_path)

      assert_all_relationships_resolve(output_path)

      Zip::File.open(output_path) do |zip|
        workbook_doc = Nokogiri::XML(zip.read('xl/workbook.xml'))
        sheet_node = workbook_doc.xpath('//*[local-name()="sheet"]').find { |s| s['name'] == 'Imported' }
        sheet_rid = sheet_node.attribute_with_ns('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships').value
        wb_rels = relationships_in(zip, 'xl/_rels/workbook.xml.rels')
        sheet_path = resolve_part('xl/workbook.xml', wb_rels.find { |r| r['Id'] == sheet_rid }['Target'])
        sheet_rels = relationships_in(zip, rels_path_for(sheet_path))
        external = sheet_rels.find { |r| r['TargetMode'] == 'External' }
        expect(external['Target']).to eq('https://example.com')
      end

      output = RubyXL::Parser.parse(output_path)
      links = output['Imported'].hyperlinks
      expect(links.map(&:location).compact).to eq([ 'Imported!A1' ])
    end
  end
  describe 'image migration' do
    it 'gives the copied image a fresh part URI when names collide, and keeps every relationship resolvable' do
      target_workbook.copy_worksheet_from(source_workbook, 'Report')
      target_workbook.save(output_path)

      assert_all_relationships_resolve(output_path)

      Zip::File.open(output_path) do |zip|
        expect(media_parts(zip).size).to eq(2)
        # The pre-existing sheet still points at its own image, byte-identical.
        existing_image = image_part_for_sheet(zip, 'Existing')
        expect(zip.read(existing_image)).to eq(PNG_TARGET)
        # The copied sheet points at a different part holding the source image bytes.
        copied_image = image_part_for_sheet(zip, 'Report')
        expect(copied_image).not_to eq(existing_image)
        expect(zip.read(copied_image)).to eq(PNG_SOURCE)
      end
    end

    it 'reuses image parts by content on repeated copies without re-pointing existing sheets' do
      target_workbook.copy_worksheet_from(source_workbook, 'Report')
      target_workbook.copy_worksheet_from(source_workbook, 'Report')
      target_workbook.save(output_path)

      assert_all_relationships_resolve(output_path)

      Zip::File.open(output_path) do |zip|
        # No third image part: the second copy reuses the identical image by content.
        expect(media_parts(zip).size).to eq(2)

        existing_image = image_part_for_sheet(zip, 'Existing')
        expect(zip.read(existing_image)).to eq(PNG_TARGET)

        first_copy = image_part_for_sheet(zip, 'Report')
        second_copy = image_part_for_sheet(zip, 'Report (2)')
        expect(zip.read(first_copy)).to eq(PNG_SOURCE)
        expect(second_copy).to eq(first_copy)
      end
    end
  end

  describe 'source workbook integrity' do
    it 'leaves the source file on disk untouched' do
      target_workbook.copy_worksheet_from(source_workbook, 'Report')
      target_workbook.save(output_path)

      expect(Digest::SHA256.file(source_path).hexdigest).to eq(source_digest)
    end

    it 'does not mutate the in-memory source workbook' do
      source = source_workbook
      before = source.stream.string

      target_workbook.copy_worksheet_from(source, 'Report')
      target_workbook.copy_worksheet_from(source, 'Report', :as => 'Again')

      expect(source.stream.string).to eq(before)
      expect(source.worksheets.map(&:sheet_name)).to eq([ 'Report', 'Data' ])
    end
  end

  describe 'cross-sheet references' do
    before do
      workbook = RubyXL::Parser.parse(source_path)
      workbook['Report'].add_cell(4, 0, 0, 'Data!A1*2')
      workbook.save(source_path)
    end

    it 'rejects references to other sheets of the source workbook by default' do
      expect {
        target_workbook.copy_worksheet_from(source_workbook, 'Report')
      }.to raise_error(RubyXL::ExternalReferenceError) { |error|
        expect(error.sheet_names).to eq([ 'Data' ])
        expect(error.message).to include('Data')
      }
    end

    it 'rewrites them as external links with :external_references => :keep' do
      new_sheet = target_workbook.copy_worksheet_from(source_workbook, 'Report',
                                                      :external_references => :keep)
      expect(new_sheet[4][0].formula.expression).to eq("'[source.xlsx]Data'!A1*2")
    end

    it 'leaves references to the copied sheet itself mapped to the new sheet' do
      new_sheet = target_workbook.copy_worksheet_from(source_workbook, 'Report',
                                                      :as => 'Clone',
                                                      :external_references => :keep)
      expect(new_sheet[3][0].formula.expression).to eq('Clone!A1+1')
    end
  end

  describe 'unsupported parts' do
    before do
      workbook = RubyXL::Parser.parse(source_path)
      worksheet = workbook['Report']
      worksheet.generic_storage << RubyXL::TableFile.new(Pathname('/xl/tables/table1.xml'), '<table/>')
      worksheet.relationship_container.relationships <<
        RubyXL::Relationship.new(:id => 'rId40', :type => RubyXL::TableFile::REL_TYPE,
                                 :target => '../tables/table1.xml')
      worksheet.table_parts = RubyXL::TableParts.new(:_ => [RubyXL::RID.new(:r_id => 'rId40')])
      workbook.save(source_path)
    end

    it 'reports the dependency closure before executing' do
      plan = target_workbook.plan_worksheet_copy(source_workbook, 'Report')

      expect(plan).not_to be_supported
      expect(plan.unsupported_parts.size).to eq(1)
      expect(plan.unsupported_parts.first.kind).to eq('table')
      expect(plan.unsupported_parts.first.target).to eq('/xl/tables/table1.xml')
      # The closure lists every dependency, supported ones included.
      kinds = plan.parts.map(&:kind)
      expect(kinds).to include('worksheet', 'styles', 'shared strings', 'comments', 'drawing', 'image')
      expect(plan.to_s).to include('table1.xml')
    end

    it 'raises by default, carrying the full closure in the error' do
      expect {
        target_workbook.copy_worksheet_from(source_workbook, 'Report')
      }.to raise_error(RubyXL::UnsupportedPartsError) { |error|
        expect(error.plan).not_to be_supported
        expect(error.message).to include('table1.xml')
      }
    end

    it 'copies without the unsupported parts when :unsupported_parts => :skip' do
      new_sheet = target_workbook.copy_worksheet_from(source_workbook, 'Report',
                                                      :unsupported_parts => :skip)
      expect(new_sheet.table_parts).to be_nil

      target_workbook.save(output_path)
      assert_all_relationships_resolve(output_path)

      Zip::File.open(output_path) do |zip|
        expect(zip.map(&:name).grep(/tables/)).to be_empty
      end
    end
  end

  describe '#plan_worksheet_copy' do
    it 'reports a fully supported closure for a well-behaved sheet' do
      plan = target_workbook.plan_worksheet_copy(source_workbook, 'Report')

      expect(plan).to be_supported
      expect(plan.source_sheet_name).to eq('Report')
      expect(plan.parts.map(&:kind)).to include('worksheet', 'styles', 'shared strings',
                                                'comments', 'drawing', 'image', 'external link')
    end

    it 'does not modify either workbook' do
      source = source_workbook
      source_before = source.stream.string
      target_before = target_workbook.stream.string

      target_workbook.plan_worksheet_copy(source, 'Report')

      expect(source.stream.string).to eq(source_before)
      expect(target_workbook.stream.string).to eq(target_before)
    end
  end

  describe 'Worksheet#copy_to' do
    it 'copies the sheet into the given workbook' do
      new_sheet = source_workbook['Report'].copy_to(target_workbook)
      expect(new_sheet.sheet_name).to eq('Report')
      expect(target_workbook.worksheets.last).to equal(new_sheet)
    end
  end
end
