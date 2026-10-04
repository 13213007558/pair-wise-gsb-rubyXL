require 'rubyXL/objects/root'
require 'rubyXL/parser'
require 'rubyXL/number_format_renderer'

module RubyXL
  @@suppress_warnings = false

  # Convert any path passed to absolute path (within the XLSX file).
  def self.from_root(path)
    return path unless path.absolute?
    path.relative_path_from(OOXMLTopLevelObject::ROOT)
  end
end
