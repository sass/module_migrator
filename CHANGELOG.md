## 1.1.0

* Add support for glob inputs on the command line.

### Module Migrator

* Add new `--import-only-for-all` flag that generates import-only stylesheets
  for all files with removed prefixes, instead of just entrypoints.

## 1.0.1

### Module Migrator

* Improve ordering of `@use` and `@forward` rules.

* Fix a bug in the migrating of configurable variables. Variables should now
  only be considered configured when the configuring declaration is upstream of
  the `!default` declaration.

* When namespacing a negated variable, adds parentheses around it to prevent the
  `-` from being parsed as part of the namespace.

* Fix a bug in the migrating of removed color functions when the amount is a
  variable being namespaced.

## 1.0.0

* Initial release.
