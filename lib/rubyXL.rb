require 'rubyXL/objects/root'
require 'rubyXL/parser'

module RubyXL
  RELATIONSHIPS_NS = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'.freeze

  @@suppress_warnings = false
  @@preserve_extensions = false

  class << self
    attr_accessor :preserve_extensions
  end

  # Convert any path passed to absolute path (within the XLSX file).
  def self.from_root(path)
    return path unless path.absolute?
    path.relative_path_from(OOXMLTopLevelObject::ROOT)
  end
end
