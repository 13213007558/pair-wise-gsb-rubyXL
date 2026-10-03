# v3.4.25 (May 19, 2022)

# Unreleased

* Add `Workbook#compress_styles` for semantically merging equivalent stylesheet entries (numFmts, fonts, fills, borders, cellStyleXfs, cellXfs and dxfs), with xfId/apply-flag-aware inheritance and theme-safe color handling; returns old-ID => new-ID mappings and compression statistics

* Improve code style and consistently (@weshatheleopard)
* Update `Gemfile.lock`, dependency versions used when developing the gem (@weshatheleopard)

# v3.4.24 (May 16, 2022)

* Add `Cell#add_hyperlink` for adding a hyperlink to a cell (@weshatheleopard)
* Add `Reference#valid?` for checking if a cell reference is valid (@weshatheleopard)
* Add `Worksheet#cell_at` for finding a cell by its Excel-style reference (@weshatheleopard)
* Prevent creation of sheets with reserved names (specifically, `History`) (@weshatheleopard)
* Update `Gemfile.lock`, dependency versions used when developing the gem (@weshatheleopard)
