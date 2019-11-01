// Copyright 2019 Google LLC
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

// The sass package's API is not necessarily stable. It is being imported with
// the Sass team's explicit knowledge and approval. See
// https://github.com/sass/dart-sass/issues/236.
import 'package:sass/src/ast/sass.dart';
import 'package:sass/src/importer.dart';
import 'package:sass/src/import_cache.dart';

import 'package:args/args.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:source_span/source_span.dart';
import 'package:tuple/tuple.dart';

import '../exception.dart';
import '../migration_visitor.dart';
import '../migrator.dart';
import '../patch.dart';
import '../utils.dart';
import '../util/node_modules_importer.dart';

import 'module/built_in_functions.dart';
import 'module/forward_type.dart';
import 'module/member_declaration.dart';
import 'module/reference_source.dart';
import 'module/references.dart';
import 'module/unreferencable_members.dart';
import 'module/unreferencable_type.dart';

/// Migrates stylesheets to the new module system.
class ModuleMigrator extends Migrator {
  final name = "module";
  final description = "Use the new module system.";

  @override
  final argParser = ArgParser()
    ..addOption('remove-prefix',
        abbr: 'p',
        help: 'Removes PREFIX from all migrated member names.',
        valueHelp: 'PREFIX')
    ..addFlag('import-only-all',
        help: 'Generates import-only stylesheets for all files with removed '
            'prefixes, not just the entrypoint.')
    ..addOption('forward',
        allowed: ['all', 'none', 'prefixed'],
        allowedHelp: {
          'none': "Doesn't forward any members.",
          'prefixed':
              'Forwards members that start with the prefix specified for '
                  '--remove-prefix.',
          'all': 'Forwards all members.'
        },
        defaultsTo: 'none',
        help: 'Specifies which members from dependencies to forward from the '
            'entrypoint.');

  /// Set of files that declare members that the migrator wants to rename.
  ///
  /// If one of these files would not be migrated, the migrator will error with
  /// a message telling the user to use `--migrate-deps` or add the missing
  /// file to their entrypoints.
  final _filesWithRenamedDeclarations = <Uri>{};

  @override
  Map<Uri, String> run() {
    var results = super.run();
    for (var file in _filesWithRenamedDeclarations) {
      if (!results.containsKey(file)) {
        throw MigrationException(
            'The migrator wants to rename a member in ${p.prettyUri(file)}, '
            'but it is not being migrated. You should re-run the migrator with '
            '--migrate-deps or with ${p.prettyUri(file)} as one of your '
            'entrypoints.');
      }
    }
    return results;
  }

  /// Runs the module migrator on [stylesheet] and its dependencies and returns
  /// a map of migrated contents.
  Map<Uri, String> migrateFile(
      ImportCache importCache, Stylesheet stylesheet, Importer importer) {
    var forward = ForwardType(argResults['forward']);
    if (forward == ForwardType.prefixed &&
        argResults['remove-prefix'] == null) {
      throw MigrationException(
          'You must provide --remove-prefix with --forward=prefixed so we know '
          'which prefixed members to forward.');
    }

    var references = References(importCache, stylesheet, importer);
    var visitor = _ModuleMigrationVisitor(
        importCache, references, globalResults['load-path'] as List<String>,
        migrateDependencies: migrateDependencies,
        prefixToRemove:
            (argResults['remove-prefix'] as String)?.replaceAll('_', '-'),
        forward: forward,
        importOnlyAll: argResults['import-only-all'] as bool);
    var migrated = visitor.run(stylesheet, importer);
    _filesWithRenamedDeclarations.addAll(visitor.renamedMembers.keys
        .map((declaration) => declaration.sourceUrl));
    return migrated;
  }
}

class _ModuleMigrationVisitor extends MigrationVisitor {
  /// Set of stylesheets currently being migrated.
  ///
  /// Used to ensure that a dependency declaring a variable that an upstream
  /// stylesheet already declared is not treated as reassignment (since that
  /// would cause a circular dependency).
  final _upstreamStylesheets = <Uri>{};

  /// Maps declarations of members that have been renamed to their new names.
  final renamedMembers = <MemberDeclaration, String>{};

  /// Tracks declarations that reassigned a variable within another module.
  ///
  /// When a reference to this declaration is encountered, the original
  /// declaration will be used for namespacing instead of this one.
  final _reassignedVariables = <MemberDeclaration<VariableDeclaration>>{};

  /// Maps canonical URLs to the original URL and importer from the `@import`
  /// rule that last imported that URL.
  final _originalImports = <Uri, Tuple2<String, Importer>>{};

  /// Tracks members that are unreferencable in the current scope.
  UnreferencableMembers _unreferencable = UnreferencableMembers();

  /// Namespaces of modules used in this stylesheet.
  Map<Uri, String> _namespaces;

  /// Set of canonical URLs that have a `@forward` rule in the current
  /// stylesheet.
  Set<Uri> _forwardedUrls;

  /// Set of canonical URLs that have a `@use` rule in the current stylesheet.
  ///
  /// This includes both `@use` rules migrated from `@import` rules and
  /// additional `@use` rules in the sets below.
  Set<Uri> _usedUrls;

  /// Set of additional `@use` rules for built-in modules.
  Set<String> _builtInUseRules;

  /// Set of additional `@use` rules for stylesheets at a load path.
  Set<String> _additionalLoadPathUseRules;

  /// Set of additional `@use` rules for stylesheets relative to the current
  /// one.
  Set<String> _additionalRelativeUseRules;

  /// The first `@import` rule in this stylesheet that was converted to a `@use`
  /// or `@forward` rule, or null if none has been visited yet.
  FileLocation _beforeFirstImport;

  /// The last `@import` rule in this stylesheet that was converted to a `@use`
  /// or `@forward` rule, or null if none has been visited yet.
  FileLocation _afterLastImport;

  /// Whether @use and @forward are allowed in the current context.
  var _useAllowed = true;

  /// Set of variables declared outside the current stylesheet that overrode
  /// `!default` variables within the current stylesheet.
  Set<MemberDeclaration<VariableDeclaration>> _configuredVariables;

  /// A mapping between member declarations and references.
  ///
  /// This performs an initial pass to determine how a declaration seen in the
  /// main migration pass is used.
  final References references;

  /// Cache used to load stylesheets.
  final ImportCache importCache;

  /// List of paths that stylesheets can be loaded from.
  final List<String> loadPaths;

  /// The prefix to be removed from any members with it, or null if no prefix
  /// should be removed.
  final String prefixToRemove;

  /// The value of the --forward flag.
  final ForwardType forward;

  /// Whether to generate import-only stylesheets for all files with removed
  /// prefixes.
  final bool importOnlyAll;

  /// Constructs a new module migration visitor.
  ///
  /// [importCache] must be the same one used by [references].
  ///
  /// [loadPaths] should be the same list used to create [importCache].
  ///
  /// Note: We always set [migratedDependencies] to true since the module
  /// migrator needs to always run on dependencies. The `migrateFile` method of
  /// the module migrator will filter out the dependencies' migration results.
  ///
  /// This converts the OS-specific relative [loadPaths] to absolute URL paths.
  _ModuleMigrationVisitor(
      this.importCache, this.references, List<String> loadPaths,
      {bool migrateDependencies,
      this.prefixToRemove,
      this.forward,
      this.importOnlyAll})
      : loadPaths =
            loadPaths.map((path) => p.toUri(p.absolute(path)).path).toList(),
        super(importCache, migrateDependencies: migrateDependencies);

  /// Checks which global declarations need to be renamed, then runs the
  /// migrator.
  @override
  Map<Uri, String> run(Stylesheet stylesheet, Importer importer) {
    references.globalDeclarations.forEach(_renameDeclaration);
    var migrated = super.run(stylesheet, importer);

    // If a prefix was removed from any members, add an import-only stylesheet
    // that forwards the entrypoint with that prefix.
    if (prefixToRemove != null && renamedMembers.isNotEmpty) {
      if (importOnlyAll) {
        for (var url in migrated.keys.toList()) {
          if (url == stylesheet.span.sourceUrl) continue;
          var results = _generateImportOnly(url);
          if (results != null) migrated[results.item1] = results.item2;
        }
      }
      var url = stylesheet.span.sourceUrl;
      var results = _generateImportOnly(url, isEntrypoint: true);
      if (results != null) migrated[results.item1] = results.item2;
    }
    return migrated;
  }

  /// Generates an import-only stylesheet for [url] that forwards any members
  /// that used to have a prefix with that prefix, but forwards other members
  /// as-is.
  ///
  /// If [url] is an entrypoint, [isEntrypoint] should be true to ensure that
  /// any members that are forwarded through the entrypoint are also included.
  ///
  /// If there are no previously-prefixed members to forward, this returns null.
  /// Otherwise, this returns a tuple of the import-only stylesheet's URL and
  /// its contents.
  Tuple2<Uri, String> _generateImportOnly(Uri url,
      {bool isEntrypoint = false}) {
    var semicolon = url.path.endsWith('.sass') ? '' : ';';
    var forwardWithPrefix = <MemberDeclaration>{};
    var forwardWithoutPrefix = <MemberDeclaration>{};
    for (var declaration in references.globalDeclarations) {
      var visible = declaration.sourceUrl == url ||
          (isEntrypoint &&
              _shouldForward(declaration.name) &&
              !declaration.name.startsWith('-'));
      if (!visible) continue;

      if (declaration.name.startsWith(prefixToRemove)) {
        forwardWithPrefix.add(declaration);
      } else {
        forwardWithoutPrefix.add(declaration);
      }
    }
    if (forwardWithPrefix.isEmpty) return null;

    var importOnlyUrl = getImportOnlyUrl(url);
    var dependency =
        _absoluteUrlToDependency(url, relativeTo: importOnlyUrl)?.item1;
    if (forwardWithoutPrefix.isEmpty) {
      return Tuple2(importOnlyUrl,
          '@forward "$dependency" as $prefixToRemove*$semicolon\n');
    }
    var hidden = forwardWithoutPrefix.map((declaration) {
      var name = '$prefixToRemove${declaration.name}';
      return declaration.member is VariableDeclaration ? '\$$name' : name;
    }).join(', ');
    var shown = forwardWithoutPrefix
        .map((declaration) => declaration.member is VariableDeclaration
            ? '\$${declaration.name}'
            : declaration.name)
        .join(', ');
    return Tuple2(
        importOnlyUrl,
        '@forward "$dependency" as $prefixToRemove* hide $hidden$semicolon\n'
        '@forward "$dependency" show $shown$semicolon\n');
  }

  /// If [declaration] should be renamed, adds it to [renamedMembers].
  ///
  /// Members are renamed if they start with [prefixToRemove] or if they start
  /// with `-` or `_` and are referenced outside the stylesheet they were
  /// declared in.
  void _renameDeclaration(MemberDeclaration declaration) {
    var name = declaration.name;
    if (name.startsWith('-') &&
        references.referencedOutsideDeclaringStylesheet(declaration)) {
      // Remove leading `-` since private members can't be accessed outside
      // the module they're declared in.
      name = name.substring(1);
    }
    name = _unprefix(name);
    if (name != declaration.name) renamedMembers[declaration] = name;
  }

  /// Returns a semicolon unless the current stylesheet uses the indented
  /// syntax, in which case this returns an empty string.
  String get _semicolonIfNotIndented =>
      currentUrl.path.endsWith('.sass') ? "" : ";";

  /// Returns whether the member named [name] should be forwarded in the
  /// entrypoint.
  ///
  /// [name] should be the original name of that member, even if it started with
  /// [prefixToRemove].
  bool _shouldForward(String name) {
    switch (forward) {
      case ForwardType.all:
        return true;
      case ForwardType.none:
        return false;
      case ForwardType.prefixed:
        return name.startsWith(prefixToRemove);
      default:
        throw StateError('--forward should not allow invalid values');
    }
  }

  /// If the current stylesheet is the entrypoint, return a string of additional
  /// `@forward` rules not already added by [_migrateImport].
  String _getAdditionalForwardRules() {
    if (_upstreamStylesheets.isNotEmpty) return '';

    var loadPathForwards = <String>[];
    var relativeForwards = <String>[];
    for (var url in references.globalDeclarations
        .map((declaration) => declaration.sourceUrl)
        .toSet()) {
      if (url == currentUrl || _forwardedUrls.contains(url)) continue;
      var tuple = _makeForwardRule(url);
      if (tuple == null) continue;
      (tuple.item2 ? relativeForwards : loadPathForwards)
          .add('${tuple.item1}$_semicolonIfNotIndented\n');
    }
    var forwards = [...loadPathForwards..sort(), ...relativeForwards..sort()];
    return forwards.isEmpty ? '' : '\n' + forwards.join('');
  }

  /// Stores per-file state and determines namespaces for this stylesheet before
  /// visiting it and restores the per-file state afterwards.
  @override
  void visitStylesheet(Stylesheet node) {
    var oldNamespaces = _namespaces;
    var oldForwardedUrls = _forwardedUrls;
    var oldUsedUrls = _usedUrls;
    var oldBuiltInUseRules = _builtInUseRules;
    var oldLoadPathUseRules = _additionalLoadPathUseRules;
    var oldRelativeUseRules = _additionalRelativeUseRules;
    var oldBeforeFirstImport = _beforeFirstImport;
    var oldAfterLastImport = _afterLastImport;
    var oldUseAllowed = _useAllowed;
    _namespaces = _determineNamespaces(node.span.sourceUrl);
    _forwardedUrls = {};
    _usedUrls = {};
    _builtInUseRules = {};
    _additionalLoadPathUseRules = {};
    _additionalRelativeUseRules = {};
    _beforeFirstImport = null;
    _afterLastImport = null;
    _useAllowed = true;
    super.visitStylesheet(node);
    _namespaces = oldNamespaces;
    _forwardedUrls = oldForwardedUrls;
    _usedUrls = oldUsedUrls;
    _builtInUseRules = oldBuiltInUseRules;
    _additionalLoadPathUseRules = oldLoadPathUseRules;
    _additionalRelativeUseRules = oldRelativeUseRules;
    _beforeFirstImport = oldBeforeFirstImport;
    _afterLastImport = oldAfterLastImport;
    _useAllowed = oldUseAllowed;
  }

  /// Adds additional patches for extra `@use` and `@forward` rules.
  @override
  void beforePatch(Stylesheet node) {
    useRulesToString(Set<String> useRules) => (useRules.toList()..sort())
        .map((use) => '$use$_semicolonIfNotIndented\n')
        .join();

    if (_builtInUseRules.isNotEmpty) {
      // This is added before existing patches to ensure that this patch is
      // inserted before a patch converting an existing `@import` rule to a
      // `@use` rule.
      addPatch(
          Patch.insert(_beforeFirstImport ?? node.span.start,
              useRulesToString(_builtInUseRules)),
          beforeExisting: true);
    }
    var extras = useRulesToString(_additionalLoadPathUseRules) +
        useRulesToString(_additionalRelativeUseRules) +
        _getAdditionalForwardRules();
    if (extras == '') return;
    var insertionPoint = _afterLastImport ?? node.span.start;
    // If there was already a blank line after the insertion point, or the
    // insertion point was at the end of the file, remove the additional line
    // break at the end of the extra rules.
    if (insertionPoint == node.span.start) extras = '$extras\n';
    var whitespace = extendThroughWhitespace(insertionPoint.pointSpan());
    if (whitespace.text.contains('\n\n') || whitespace.end == node.span.end) {
      extras = extras.substring(0, extras.length - 1);
    }
    if (insertionPoint == _afterLastImport) extras = '\n$extras';
    addPatch(Patch.insert(insertionPoint, extras));
  }

  /// Determines namespaces for all `@use` rules that the stylesheet at [url]
  /// will contain after migration.
  Map<Uri, String> _determineNamespaces(Uri url) {
    var namespaces = <Uri, String>{};
    var sourcesByNamespace = <String, Set<ReferenceSource>>{};
    for (var reference in references.sources.keys) {
      if (reference.span.sourceUrl != url) continue;
      var source = references.sources[reference];
      var namespace = source.defaultNamespace;
      if (namespace == null) continue;

      // Existing `@use` rules should always keep their namespaces.
      if (source is UseSource) {
        namespaces[source.url] = namespace;
      } else {
        sourcesByNamespace.putIfAbsent(namespace, () => {}).add(source);
      }
    }

    // First assign namespaces to module URLs without conflicts.
    var conflictingNamespaces = <String, Set<ReferenceSource>>{};
    sourcesByNamespace.forEach((namespace, sources) {
      if (sources.length == 1 && !namespaces.containsValue(namespace)) {
        namespaces[sources.first.url] = namespace;
      } else {
        conflictingNamespaces[namespace] = sources;
      }
    });

    // Then resolve conflicts where they exist.
    conflictingNamespaces.forEach((namespace, sources) {
      _resolveNamespaceConflict(namespace, sources, namespaces);
    });
    return namespaces;
  }

  /// Resolves a conflict between a set of sources with the same default
  /// namespace, adding namespaces for all of them to [namespaces].
  void _resolveNamespaceConflict(String namespace, Set<ReferenceSource> sources,
      Map<Uri, String> namespaces) {
    // Give first priority to a built-in module.
    var builtIns = sources.whereType<BuiltInSource>();
    if (builtIns.isNotEmpty) {
      namespaces[builtIns.first.url] =
          _resolveBuiltInNamespace(namespace, namespaces);
    }
    // Then handle `@import` rules, in order of path segment count.
    for (var sources in _orderSources(sources.whereType<ImportSource>())) {
      // We remove the last segment since it's already present in the
      // namespace and any segments with dots since they're not valid in a
      // namespace.
      var paths = {
        for (var source in sources)
          source: Uri.parse(source.import.url).pathSegments.toList()
            ..removeLast()
            ..removeWhere((segment) => segment.contains('.'))
      };
      // Start each rule's namespace at the default.
      var aliases = {for (var source in sources) source: namespace};

      // While multiple rules have the same namespace or any rule's
      // namespace is already present, add the next path segment to all
      // namespaces at once.
      while (!valuesAreUnique(aliases) ||
          aliases.values.any(namespaces.containsValue)) {
        // If any of the rules runs out of path segments, fallback to just
        // adding numerical suffixes.
        if (paths.values.any((segments) => segments.isEmpty)) {
          for (var source in sources) {
            namespaces[source.url] =
                _incrementUntilAvailable(namespace, namespaces);
          }
          return;
        }
        aliases = {
          for (var source in sources)
            source: '${paths[source].removeLast()}-${aliases[source]}'
        };
      }
      for (var source in sources) {
        namespaces[source.url] = aliases[source];
      }
    }
  }

  /// If [module] is not already a value in [existingNamespaces], returns it.
  /// If it is, but "sass-$module" is not, returns that. Otherwise, returns it
  /// with the lowest available number appended to the end.
  String _resolveBuiltInNamespace(
      String module, Map<Uri, String> existingNamespaces) {
    return existingNamespaces.containsValue(module) &&
            !existingNamespaces.containsValue('sass-$module')
        ? 'sass-$module'
        : _incrementUntilAvailable(module, existingNamespaces);
  }

  /// If [defaultNamespace] has not already been used in this
  /// [existingNamespaces], returns it. Otherwise, returns it with the lowest
  /// available number appended to the end.
  String _incrementUntilAvailable(
      String defaultNamespace, Map<Uri, String> existingNamespaces) {
    var count = 1;
    var namespace = defaultNamespace;
    while (existingNamespaces.containsValue(namespace)) {
      namespace = '$defaultNamespace${++count}';
    }
    return namespace;
  }

  /// Given a set of import sources, groups them by the number of path segments
  /// and sorts those groups from fewer to more segments.
  List<Set<ImportSource>> _orderSources(Iterable<ImportSource> sources) {
    var byPathLength = <int, Set<ImportSource>>{};
    for (var source in sources) {
      var pathSegments = Uri.parse(source.import.url).pathSegments;
      byPathLength.putIfAbsent(pathSegments.length, () => {}).add(source);
    }
    return [
      for (var length in byPathLength.keys.toList()..sort())
        byPathLength[length]
    ];
  }

  /// Visits the children of [node] with a new scope for tracking unreferencable
  /// members.
  @override
  void visitChildren(ParentStatement node) {
    _unreferencable = UnreferencableMembers(_unreferencable);
    super.visitChildren(node);
    _unreferencable = _unreferencable.parent;
  }

  /// Adds a namespace to any function call that requires it.
  @override
  void visitFunctionExpression(FunctionExpression node) {
    if (node.namespace != null) {
      super.visitFunctionExpression(node);
      return;
    }
    if (references.sources.containsKey(node)) {
      var declaration = references.functions[node];
      _unreferencable.check(declaration, node);
      _renameReference(nameSpan(node), declaration);
      _patchNamespaceForFunction(node, declaration, (namespace) {
        addPatch(patchBefore(node.name, '$namespace.'));
      });
    }

    if (node.name.asPlain == "get-function") {
      var declaration = references.getFunctionReferences[node];
      _unreferencable.check(declaration, node);
      _renameReference(getStaticNameForGetFunctionCall(node), declaration);

      // Ignore get-function calls that already have a module argument.
      var moduleArg = node.arguments.named['module'];
      if (moduleArg == null && node.arguments.positional.length > 2) {
        moduleArg = node.arguments.positional[2];
      }
      if (moduleArg != null) return;

      // Warn for get-function calls without a static name.
      var nameArg =
          node.arguments.named['name'] ?? node.arguments.positional.first;
      if (nameArg is! StringExpression ||
          (nameArg as StringExpression).text.asPlain == null) {
        emitWarning(
            "get-function call may require \$module parameter", nameArg.span);
        return;
      }

      _patchNamespaceForFunction(node, declaration, (namespace) {
        var beforeParen = node.span.end.offset - 1;
        addPatch(Patch(node.span.file.span(beforeParen, beforeParen),
            ', \$module: "$namespace"'));
      }, getFunctionCall: true);
    }
    super.visitFunctionExpression(node);
  }

  /// Calls [patchNamespace] when the function [node] requires a namespace.
  ///
  /// This also patches the name for any built-in functions whose names change
  /// in the module system.
  ///
  /// When the function is a color function that's not present in the module
  /// system (like `lighten`), this also migrates its `$amount` argument to the
  /// appropriate `color.adjust` argument.
  ///
  /// If [node] is a get-function call, [getFunctionCall] should be true.
  void _patchNamespaceForFunction(
      FunctionExpression node,
      MemberDeclaration<FunctionRule> declaration,
      void patchNamespace(String namespace),
      {bool getFunctionCall = false}) {
    var span = getFunctionCall
        ? getStaticNameForGetFunctionCall(node)
        : nameSpan(node);
    if (span == null) return;
    var name = span.text.replaceAll('_', '-');

    var namespace = _namespaceForDeclaration(declaration);
    if (namespace != null) {
      patchNamespace(namespace);
      return;
    }

    if (!builtInFunctionModules.containsKey(name)) return;

    namespace = builtInFunctionModules[name];
    name = builtInFunctionNameChanges[name] ?? name;
    if (namespace == 'color' && removedColorFunctions.containsKey(name)) {
      if (getFunctionCall) {
        emitWarning(
            "$name is not available in the module system and should be "
            "manually migrated to color.adjust",
            span);
        return;
      } else if (node.arguments.positional.length == 2 &&
          node.arguments.named.isEmpty) {
        _patchRemovedColorFunction(name, node.arguments.positional.last);
        name = 'adjust';
      } else if (node.arguments.named.containsKey('amount')) {
        var arg = node.arguments.named['amount'];
        _patchRemovedColorFunction(name, arg,
            existingArgName: _findArgNameSpan(arg));
        name = 'adjust';
      } else {
        emitWarning("Could not migrate malformed '$name' call", node.span);
        return;
      }
    }
    patchNamespace(_findOrAddBuiltInNamespace(namespace));
    if (name != span.text.replaceAll('_', '-')) addPatch(Patch(span, name));
  }

  /// Given a named argument [arg], returns a span from the start of the name
  /// to the start of the argument itself (e.g. "$amount: ").
  FileSpan _findArgNameSpan(Expression arg) {
    var start = arg.span.start.offset - 1;
    while (arg.span.file.getText(start, start + 1) != r'$') {
      start--;
    }
    return arg.span.file.span(start, arg.span.start.offset);
  }

  /// Patches the amount argument [arg] for a removed color function
  /// (e.g. `lighten`) to add the appropriate name (such as `$lightness`) and
  /// negate the argument if necessary.
  void _patchRemovedColorFunction(String name, Expression arg,
      {FileSpan existingArgName}) {
    var parameter = removedColorFunctions[name];
    // Surround the argument in parens if negated to avoid `-` being parsed
    // as part of the namespace.
    var needsParens = parameter.endsWith('-') &&
        (arg is BinaryOperationExpression ||
            arg is FunctionExpression ||
            (arg is VariableExpression &&
                references.variables[arg]?.sourceUrl != currentUrl));
    var leftParen = needsParens ? '(' : '';
    if (existingArgName == null) {
      addPatch(patchBefore(arg, '$parameter$leftParen'));
    } else {
      addPatch(Patch(existingArgName, '$parameter$leftParen'));
    }
    if (needsParens) addPatch(patchAfter(arg, ')'));
  }

  /// Visits a `@function` rule, renaming if necessary.
  @override
  void visitFunctionRule(FunctionRule node) {
    _useAllowed = false;
    _renameReference(nameSpan(node), MemberDeclaration(node));
    super.visitFunctionRule(node);
  }

  /// Migrates an `@import` rule to a `@use` rule after migrating the imported
  /// file.
  @override
  void visitImportRule(ImportRule node) {
    var imports =
        partitionOnType<Import, StaticImport, DynamicImport>(node.imports);
    var staticImports = imports.item1;
    var dynamicImports = imports.item2;

    var start = node.span.start;
    var first = true;
    for (var import in dynamicImports) {
      if (first) {
        first = false;
      } else {
        addPatch(Patch.insert(start, "\n"));
      }

      _migrateImport(import, start);
    }

    if (staticImports.isNotEmpty) {
      if (dynamicImports.isNotEmpty) addPatch(Patch.insert(start, "\n"));

      _useAllowed = false;
      super.visitImportRule(node);

      // Delete any dynamic imports intermixed with static imports, as well as
      // any whitespace surrounding them and the preceding comma separator (or
      // following if the first import is dynamic).
      for (var import in dynamicImports) {
        var extended = extendThroughWhitespace(import.span);
        addPatch(patchDelete(
            extendForward(extended, ",") ?? extendBackward(extended, ",")));
      }
    } else {
      addPatch(patchDelete(node.span));
    }

    if (_useAllowed) {
      _beforeFirstImport ??= node.span.start;
      if (currentUrl.path.endsWith('.sass')) {
        _afterLastImport = node.span.end;
      } else {
        _afterLastImport =
            extendForward(extendThroughWhitespace(node.span), ';')?.end ??
                node.span.end;
      }
    }
  }

  /// Migrates a single imported URL to a `@use` rule.
  ///
  /// The [importStart] is the original location of the beginning of the
  /// `@import` rule, at which point the new `@use` should be injected.
  void _migrateImport(DynamicImport import, FileLocation importStart) {
    var oldConfiguredVariables = _configuredVariables;
    _configuredVariables = {};
    _upstreamStylesheets.add(currentUrl);
    if (!_useAllowed) {
      _unreferencable = UnreferencableMembers(_unreferencable);
      for (var declaration in references.allDeclarations) {
        if (declaration.sourceUrl != currentUrl) continue;
        _unreferencable.add(declaration, UnreferencableType.fromImporter);
      }
    }

    var parsedUrl = Uri.parse(import.url);
    if (migrateDependencies) visitDependency(parsedUrl, import.span);
    _upstreamStylesheets.remove(currentUrl);

    // Associate the importer for this URL with the resolved URL so that we can
    // re-use this import URL later on.
    var tuple = importCache.canonicalize(parsedUrl, importer, currentUrl);
    var resolvedUrl = tuple.item2;
    _originalImports.putIfAbsent(
        resolvedUrl, () => Tuple2(import.url, tuple.item1));

    var asClause = '';
    if (!_useAllowed) {
      _unreferencable = _unreferencable.parent;
      for (var declaration in references.allDeclarations) {
        if (declaration.sourceUrl != resolvedUrl) continue;
        _unreferencable.add(declaration, UnreferencableType.fromNestedImport);
      }
    } else {
      var defaultNamespace = namespaceForPath(import.url);
      // If a member from this dependency is actually referenced, it should
      // already have a namespace from [_determineNamespaces], so we just use
      // a simple number suffix to resolve conflicts at this point.
      _namespaces.putIfAbsent(resolvedUrl,
          () => _incrementUntilAvailable(defaultNamespace, _namespaces));
      var namespace = _namespaces[resolvedUrl];
      if (namespace != defaultNamespace) asClause = ' as $namespace';
    }

    // Pass the variables that were configured by the importing file to `with`,
    // and forward the rest and add them to `oldConfiguredVariables` because
    // they were configured by a further-out import.
    var locallyConfiguredVariables =
        <String, MemberDeclaration<VariableDeclaration>>{};
    var externallyConfiguredVariables =
        <String, MemberDeclaration<VariableDeclaration>>{};
    for (var variable in _configuredVariables) {
      if (variable.sourceUrl == currentUrl) {
        locallyConfiguredVariables[variable.name] = variable;
      } else if (_upstreamStylesheets.contains(variable.sourceUrl)) {
        externallyConfiguredVariables[variable.name] = variable;
        oldConfiguredVariables.add(variable);
      }
    }
    _configuredVariables = oldConfiguredVariables;

    if (externallyConfiguredVariables.isNotEmpty) {
      if (!_useAllowed) {
        var firstConfig = externallyConfiguredVariables.values.first;
        throw MigrationSourceSpanException(
            "This declaration attempts to override a default value in an "
            "indirect, nested import of ${p.prettyUri(resolvedUrl)}, which is "
            "not possible in the module system.",
            firstConfig.member.span);
      }
      addPatch(Patch.insert(
          importStart,
          "@forward ${import.span.text} show " +
              externallyConfiguredVariables.keys
                  .map((variable) => "\$$variable")
                  .join(", ") +
              "$_semicolonIfNotIndented\n"));
    }

    var configuration = "";
    var configured = <String>[];
    for (var name in locallyConfiguredVariables.keys) {
      var variable = locallyConfiguredVariables[name];
      if (variable.member.isGuarded ||
          references.variables.containsValue(variable)) {
        configured.add("\$$name: \$$name");
      } else {
        // TODO(jathak): Handle the case where the expression of this
        // declaration has already been patched.
        var span = variable.member.span;
        var before = span.start.offset;
        var beforeDeclaration =
            span.file.span(before - span.start.column, before);
        if (beforeDeclaration.text.trim() == '') {
          addPatch(patchDelete(beforeDeclaration));
        }
        addPatch(patchDelete(span));
        var start = span.end.offset;
        var end = start + _semicolonIfNotIndented.length;
        if (span.file.span(end, end + 1).text == '\n') end++;
        addPatch(patchDelete(span.file.span(start, end)));
        var nameFormat = _useAllowed ? '\$$name' : '"$name"';
        configured.add("$nameFormat: ${variable.member.expression}");
      }
    }
    if (configured.length == 1) {
      configuration = " with (" + configured.first + ")";
    } else if (configured.isNotEmpty) {
      var indent = ' ' * importStart.column;
      configuration =
          " with (\n$indent  " + configured.join(',\n$indent  ') + "\n$indent)";
    }
    if (!_useAllowed) {
      var namespace = _findOrAddBuiltInNamespace('meta');
      configuration = configuration.replaceFirst(' with', r', $with:');
      addPatch(Patch.insert(importStart,
          '@include $namespace.load-css(${import.span.text}$configuration)'));
    } else {
      if (_upstreamStylesheets.isEmpty &&
          configuration.isEmpty &&
          !references.anyMemberReferenced(resolvedUrl, currentUrl)) {
        var tuple = _makeForwardRule(resolvedUrl);
        if (tuple != null) {
          _forwardedUrls.add(resolvedUrl);
          addPatch(Patch.insert(importStart, tuple.item1));
          return;
        }
      }
      _usedUrls.add(resolvedUrl);
      addPatch(Patch.insert(
          importStart, '@use ${import.span.text}$asClause$configuration'));
    }
  }

  /// If [url] contains any member declarations that should be forwarded from
  /// the entrypoint, returns a tuple of the `@forward` rule that should be used
  /// and a boolean that is true when the URL of this rule is relative.
  ///
  /// If nothing from [url] should be forwarded, returns null.
  Tuple2<String, bool> _makeForwardRule(Uri url) {
    var shown = <String>{};
    var hidden = <String>{};

    // Divide all global members from dependencies into sets based on whether
    // they should be forwarded or not.
    for (var declaration in references.globalDeclarations) {
      if (declaration.sourceUrl != url) continue;

      var newName = renamedMembers[declaration] ?? declaration.name;
      if (declaration.member is VariableDeclaration) newName = "\$$newName";

      if (_shouldForward(declaration.name) &&
          !declaration.name.startsWith('-')) {
        shown.add(newName);
      } else if (!newName.startsWith('-') && !newName.startsWith(r'$-')) {
        hidden.add(newName);
      }
    }
    if (shown.isEmpty) return null;

    var tuple = _absoluteUrlToDependency(url);
    var forward = '@forward "${tuple.item1}"';
    if (hidden.isNotEmpty) {
      var hiddenMembers = hidden.toList()..sort();
      forward += ' hide ${hiddenMembers.join(", ")}';
    }
    return Tuple2(forward, tuple.item2);
  }

  /// Adds a namespace to any mixin include that requires it.
  @override
  void visitIncludeRule(IncludeRule node) {
    _useAllowed = false;
    super.visitIncludeRule(node);
    if (node.namespace != null) return;

    var declaration = references.mixins[node];
    _unreferencable.check(declaration, node);
    _renameReference(nameSpan(node), declaration);
    var namespace = _namespaceForDeclaration(declaration);
    if (namespace != null) {
      addPatch(Patch(subspan(nameSpan(node), end: 0), '$namespace.'));
    }
  }

  /// Visits a `@mixin` rule, renaming it if necessary.
  @override
  void visitMixinRule(MixinRule node) {
    _useAllowed = false;
    _renameReference(nameSpan(node), MemberDeclaration(node));
    super.visitMixinRule(node);
  }

  /// If [node] is for a built-in module, adds its URL to [_usedUrls] so we
  /// don't add a duplicate one, but ignore other `@use` rules, as we'll assume
  /// they've already been migrated.
  ///
  /// The migrator will use the information from [references] to migrate
  /// references to members of these dependencies.
  void visitUseRule(UseRule node) {
    if (node.url.scheme == 'sass') _usedUrls.add(node.url);
  }

  /// Similar to `@use` rules, don't visit `@forward` rules.
  ///
  /// The migrator will use the information from [references] to migrate
  /// references to members of these dependencies.
  void visitForwardRule(ForwardRule node) {}

  /// Adds a namespace to any variable that requires it.
  @override
  void visitVariableExpression(VariableExpression node) {
    if (node.namespace != null) return;
    var declaration = references.variables[node];
    _unreferencable.check(declaration, node);
    if (_reassignedVariables.contains(declaration)) {
      declaration = references.variableReassignments[declaration];
    }
    _renameReference(nameSpan(node), declaration);
    var namespace = _namespaceForDeclaration(declaration);
    if (namespace != null) {
      // Surround the variable in parens if negated to avoid `-` being parsed
      // as part of the namespace.
      var negated = matchesBeforeSpan(node.span, '-');
      if (negated) addPatch(patchBefore(node, '('));
      addPatch(patchBefore(node, '$namespace.'));
      if (negated) addPatch(patchAfter(node, ')'));
    }
  }

  /// Visits the variable declaration, tracking configured variables and
  /// renaming or namespacing if necessary.
  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    var declaration = MemberDeclaration(node);
    if (references.defaultVariableDeclarations.containsKey(declaration)) {
      _configuredVariables
          .add(references.defaultVariableDeclarations[declaration]);
    }
    _renameReference(nameSpan(node), declaration);

    var existingNode = references.variableReassignments[declaration];
    var originalUrl = existingNode?.sourceUrl;
    if (existingNode != null &&
        originalUrl != currentUrl &&
        !node.isGuarded &&
        !_upstreamStylesheets.contains(originalUrl)) {
      var namespace = _namespaceForDeclaration(existingNode);
      addPatch(patchBefore(node, '$namespace.'));
      _reassignedVariables.add(declaration);
    }

    super.visitVariableDeclaration(node);
  }

  /// If [declaration] was renamed, patches [span] to use the same name.
  void _renameReference(FileSpan span, MemberDeclaration declaration) {
    if (declaration == null) return;
    if (renamedMembers.containsKey(declaration)) {
      addPatch(Patch(span, renamedMembers[declaration]));
      return;
    }

    if (_isPrefixedImportOnly(declaration)) {
      addPatch(patchDelete(span, end: declaration.forward.prefix.length));
    }
  }

  /// Returns true if [declaration] was forwarded from a regular stylesheet by
  /// an import-only stylesheet of the same name.
  bool _isPrefixedImportOnly(MemberDeclaration declaration) {
    if (declaration.forward?.prefix == null) return false;
    var containing = declaration.sourceUrl.toString();
    var forwarded = declaration.forwardedUrl.toString();
    if (!p.url.equals(p.url.dirname(containing), p.url.dirname(forwarded))) {
      return false;
    }
    return p.url.basename(containing) ==
        p.url.withoutExtension(p.url.basename(forwarded)) +
            ".import" +
            p.url.extension(containing);
  }

  /// Returns [name] with [prefixToRemove] removed.
  String _unprefix(String name) {
    if (prefixToRemove == null || prefixToRemove.length > name.length) {
      return name;
    }
    var startOfName = name.substring(0, prefixToRemove.length);
    if (prefixToRemove != startOfName) return name;
    return name.substring(prefixToRemove.length);
  }

  /// Returns the namespace that built-in module [module] is loaded under.
  ///
  /// This adds an additional `@use` rule if [module] has not been loaded yet.
  String _findOrAddBuiltInNamespace(String module) {
    var url = Uri.parse("sass:$module");
    _namespaces.putIfAbsent(
        url, () => _resolveBuiltInNamespace(module, _namespaces));
    var namespace = _namespaces[url];
    if (!_usedUrls.contains(url)) {
      _usedUrls.add(url);
      var asClause = namespace == module ? '' : ' as $namespace';
      _builtInUseRules.add('@use "sass:$module"$asClause');
    }
    return namespace;
  }

  /// Finds the namespace for the stylesheet containing [declaration], adding a
  /// new `@use` rule if necessary.
  String _namespaceForDeclaration(MemberDeclaration declaration) {
    if (declaration == null) return null;

    var url = declaration.sourceUrl;
    if (url == currentUrl) return null;

    // If we can load [declaration] from a library entrypoint URL, do so. Choose
    // the shortest one if there are multiple options.
    var libraryUrls = references.libraries[declaration];
    if (libraryUrls != null) {
      url = minBy(libraryUrls, (url) => url.pathSegments.length);
    }

    if (!_usedUrls.contains(url)) {
      // Add new `@use` rule for indirect dependency
      var tuple = _absoluteUrlToDependency(url);
      var defaultNamespace = namespaceForPath(tuple.item1);
      // There are a few edge cases where the reference in [node] wasn't tracked
      // by [references.sources], so we add a namespace with simple conflict
      // resolution if one for this URL doesn't already exist.
      _namespaces.putIfAbsent(
          url, () => _incrementUntilAvailable(defaultNamespace, _namespaces));
      var namespace = _namespaces[url];
      var asClause = defaultNamespace == namespace ? '' : ' as $namespace';
      _usedUrls.add(url);
      (tuple.item2 ? _additionalRelativeUseRules : _additionalLoadPathUseRules)
          .add('@use "${tuple.item1}"$asClause');
    }
    return _namespaces[url];
  }

  /// Converts an absolute URL for a stylesheet into the simplest string that
  /// could be used to depend on that stylesheet from the current one in a
  /// `@use`, `@forward`, or `@import` rule.
  ///
  /// The first item of the returned tuple is the dependency, the second item
  /// is true when this dependency is resolved relative to the current URL and
  /// false when it's resolved relative to a load path.
  Tuple2<String, bool> _absoluteUrlToDependency(Uri url, {Uri relativeTo}) {
    relativeTo ??= currentUrl;
    var tuple = _originalImports[url];
    if (tuple?.item2 is NodeModulesImporter) return Tuple2(tuple.item1, false);

    var loadPathUrls = loadPaths.map((path) => p.toUri(p.absolute(path)));
    var potentialUrls = [
      p.url.relative(url.path, from: p.url.dirname(relativeTo.path)),
      for (var loadPath in loadPathUrls)
        if (p.url.isWithin(loadPath.path, url.path))
          p.url.relative(url.path, from: loadPath.path)
    ];
    var relativePath = minBy(potentialUrls, (url) => url.length);
    var isRelative = relativePath == potentialUrls.first;

    var basename = p.url.basenameWithoutExtension(relativePath);
    if (basename.startsWith('_')) basename = basename.substring(1);
    return Tuple2(
        p.url.relative(p.url.join(p.url.dirname(relativePath), basename)),
        isRelative);
  }

  /// Disallows `@use` after `@at-root` rules.
  @override
  void visitAtRootRule(AtRootRule node) {
    _useAllowed = false;
    super.visitAtRootRule(node);
  }

  /// Disallows `@use` after at-rules.
  @override
  void visitAtRule(AtRule node) {
    _useAllowed = false;
    super.visitAtRule(node);
  }

  /// Disallows `@use` after `@debug` rules.
  @override
  void visitDebugRule(DebugRule node) {
    _useAllowed = false;
    super.visitDebugRule(node);
  }

  /// Disallows `@use` after `@each` rules.
  @override
  void visitEachRule(EachRule node) {
    _useAllowed = false;
    super.visitEachRule(node);
  }

  /// Disallows `@use` after `@error` rules.
  @override
  void visitErrorRule(ErrorRule node) {
    _useAllowed = false;
    super.visitErrorRule(node);
  }

  /// Disallows `@use` after `@for` rules.
  @override
  void visitForRule(ForRule node) {
    _useAllowed = false;
    super.visitForRule(node);
  }

  /// Disallows `@use` after `@if` rules.
  @override
  void visitIfRule(IfRule node) {
    _useAllowed = false;
    super.visitIfRule(node);
  }

  /// Disallows `@use` after `@media` rules.
  @override
  void visitMediaRule(MediaRule node) {
    _useAllowed = false;
    super.visitMediaRule(node);
  }

  /// Disallows `@use` after style rules.
  @override
  void visitStyleRule(StyleRule node) {
    _useAllowed = false;
    super.visitStyleRule(node);
  }

  /// Disallows `@use` after `@supports` rules.
  @override
  void visitSupportsRule(SupportsRule node) {
    _useAllowed = false;
    super.visitSupportsRule(node);
  }

  /// Disallows `@use` after `@warn` rules.
  @override
  void visitWarnRule(WarnRule node) {
    _useAllowed = false;
    super.visitWarnRule(node);
  }

  /// Disallows `@use` after `@while` rules.
  @override
  void visitWhileRule(WhileRule node) {
    _useAllowed = false;
    super.visitWhileRule(node);
  }
}
