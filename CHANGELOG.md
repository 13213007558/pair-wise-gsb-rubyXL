# Unreleased

* Add `Workbook#copy_worksheet_from` / `Worksheet#copy_to` for copying a worksheet
  across workbooks together with its images, comments, hyperlinks, styles and shared
  strings. Relationship IDs and part URIs are re-assigned in the target package;
  shared resources are reused by content. References to the copied sheet are remapped
  to the new sheet; references to other sheets of the source workbook can be kept as
  external links or rejected. Unsupported part types are reported via
  `Workbook#plan_worksheet_copy` (dependency closure) before the copy is executed.
* Add `ContentTypes#content_type_for` and allow `GenericStorageObject#content_type`
  to override the class-level content type of a part.

# v3.4.25 (May 19, 2022)

* Improve code style and consistently (@weshatheleopard)
* Update `Gemfile.lock`, dependency versions used when developing the gem (@weshatheleopard)

# v3.4.24 (May 16, 2022)

* Add `Cell#add_hyperlink` for adding a hyperlink to a cell (@weshatheleopard)
* Add `Reference#valid?` for checking if a cell reference is valid (@weshatheleopard)
* Add `Worksheet#cell_at` for finding a cell by its Excel-style reference (@weshatheleopard)
* Prevent creation of sheets with reserved names (specifically, `History`) (@weshatheleopard)
* Update `Gemfile.lock`, dependency versions used when developing the gem (@weshatheleopard)
