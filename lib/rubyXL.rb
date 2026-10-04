require 'rubyXL/objects/root'
require 'rubyXL/parser'

module RubyXL
  @@suppress_warnings = false

  class << self
    # When +true+, the parser captures attributes and child elements that RubyXL
    # does not natively understand (extension nodes, +mc:Ignorable+, namespaced
    # attributes such as +x14ac:dyDescent+, etc.) instead of dropping them or
    # raising, and writes them back out with the part they were found on.
    # Defaults to +false+ (legacy behavior) so the mode is explicitly opted into.
    attr_accessor :preserve_extensions

    # What to do when, at save time, a preserved extension references a
    # relationship (rId) that no longer exists in the owning part (for example,
    # an image the extension points at was deleted):
    # * +:raise+ (default) - raise RubyXL::ExtensionDependencyError naming the
    #   part, the missing rIds and the offending extension, rejecting the write;
    # * +:drop+ - silently remove the entire offending extension and continue.
    attr_accessor :extension_dependency_policy
  end

  self.preserve_extensions = false
  self.extension_dependency_policy = :raise

  # Convert any path passed to absolute path (within the XLSX file).
  def self.from_root(path)
    return path unless path.absolute?
    path.relative_path_from(OOXMLTopLevelObject::ROOT)
  end
end
