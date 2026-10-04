# Unreleased

* Add opt-in extension preservation mode (`RubyXL.preserve_extensions = true`):
  unknown attributes and child elements (including `mc:Ignorable` and foreign
  namespaces) are captured at parse time and written back with their part, so
  editing supported content no longer destroys unrecognized extension markup.
  Preserved `mc:AlternateContent` is dropped when RubyXL regenerates the same
  feature, avoiding contradictory Choice/Fallback output. Preserved extensions
  are checked for dangling relationship references before saving; the caller
  chooses the reaction via `RubyXL.extension_dependency_policy` (`:raise` with
  `RubyXL::ExtensionDependencyError`, or `:drop` the offending extension).

# v3.4.25 (May 19, 2022)

* Improve code style and consistently (@weshatheleopard)
* Update `Gemfile.lock`, dependency versions used when developing the gem (@weshatheleopard)

# v3.4.24 (May 16, 2022)

* Add `Cell#add_hyperlink` for adding a hyperlink to a cell (@weshatheleopard)
* Add `Reference#valid?` for checking if a cell reference is valid (@weshatheleopard)
* Add `Worksheet#cell_at` for finding a cell by its Excel-style reference (@weshatheleopard)
* Prevent creation of sheets with reserved names (specifically, `History`) (@weshatheleopard)
* Update `Gemfile.lock`, dependency versions used when developing the gem (@weshatheleopard)
