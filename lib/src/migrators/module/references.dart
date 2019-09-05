// Copyright 2019 Google LLC
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

// The sass package's API is not necessarily stable. It is being imported with
// the Sass team's explicit knowledge and approval. See
// https://github.com/sass/dart-sass/issues/236.
import 'package:sass/src/ast/sass.dart';
import 'package:sass/src/visitor/recursive_ast.dart';

import 'package:collection/collection.dart';

import 'bidirectional_map.dart';
import 'scope.dart';
import '../../utils.dart';

/// A mapping between member declarations and references.
///
/// Generating this object is the first pass of the module migrator. It then
/// uses the information stored here on the second pass to determine how a
/// member is used.
class References {
  References._();

  /// Map between variable references and their declarations.
  ///
  /// This map is frozen after it is built to prevent further modification.
  final variables = BidirectionalMap<VariableExpression,
      SassNode /*VariableDeclaration|Argument*/ >();

  /// Map between mixin references and their declarations.
  ///
  /// This map is frozen after it is built to prevent further modification.
  final mixins = BidirectionalMap<IncludeRule, MixinRule>();

  /// Map between function references and their declarations.
  ///
  /// This map is frozen after it is built to prevent further modification.
  final functions = BidirectionalMap<FunctionExpression, FunctionRule>();

  final _stylesheets = <Uri, Stylesheet>{};

  /// Maps canonical stylesheet URLs to the parsed stylesheet used when building
  /// this object.
  ///
  /// Users of this object should get stylesheets from this object instead of
  /// re-parsing them.
  Map<Uri, Stylesheet> get stylesheets => UnmodifiableMapView(_stylesheets);

  /// Constructs a new References object based on the stylesheet at [entrypoint]
  /// and its dependencies.
  static References build(Uri entrypoint) =>
      _ReferenceVisitor().build(entrypoint);
}

/// A visitor that builds a References object.
class _ReferenceVisitor extends RecursiveAstVisitor {
  /// The References object being built.
  final _references = References._();

  /// The current global scope.
  ///
  /// This persists across imports, but not across module uses.
  Scope _scope;

  /// Mapping from canonical stylesheet URLs to the global scope of the module
  /// contained within it.
  ///
  /// Note: Stylesheets only depended on through imports will not have their
  /// own scope in this map; they will instead share a global scope with the
  /// stylesheet that imported them.
  final _moduleScopes = <Uri, Scope>{};

  /// Namespaces present within the current stylesheet.
  ///
  /// Note: Unlike the similar property in _ModuleMigrationVisitor, this only
  /// includes namespaces for use rules that already exist within the file.
  /// It doesn't not include namespaces for to-be-migrated imports.
  Map<String, Uri> _namespaces;

  /// Returns the stylesheet at [url].
  ///
  /// This reuses the stylesheet if it's already been parsed.
  Stylesheet getStylesheet(Uri url) {
    url = canonicalize(url);
    if (url == null) return null;
    return _references.stylesheets[url] ?? parseStylesheet(url);
  }

  /// Constructs a new References object based on the stylesheet at [entrypoint]
  /// and its dependencies.
  References build(Uri entrypoint) {
    var stylesheet = getStylesheet(entrypoint);
    _scope = Scope();
    _moduleScopes[stylesheet.span.sourceUrl] = _scope;
    visitStylesheet(stylesheet);
    _references.variables.freeze();
    _references.mixins.freeze();
    _references.functions.freeze();
    return _references;
  }

  /// Visits a stylesheet with an empty [_namespaces], storing it in
  /// [_references].
  @override
  void visitStylesheet(Stylesheet node) {
    _references._stylesheets[node.span.sourceUrl] = node;
    var _oldNamespaces = _namespaces;
    _namespaces = {};
    super.visitStylesheet(node);
    _namespaces = _oldNamespaces;
  }

  /// Visits the stylesheet this import rule points to using the existing global
  /// scope.
  @override
  void visitImportRule(ImportRule node) {
    super.visitImportRule(node);
    for (var import in node.imports) {
      if (import is DynamicImport) {
        var url = node.span.sourceUrl.resolveUri(Uri.parse(import.url));
        var stylesheet = getStylesheet(url);
        if (stylesheet != null) visitStylesheet(stylesheet);
      }
    }
  }

  /// Visits the stylesheet this use rule points to using a new global scope
  /// for this module.
  @override
  void visitUseRule(UseRule node) {
    super.visitUseRule(node);
    var url = node.span.sourceUrl.resolveUri(node.url);
    var stylesheet = getStylesheet(url);
    if (stylesheet == null) return;
    var canonicalUrl = stylesheet.span.sourceUrl;
    if (!_moduleScopes.containsKey(canonicalUrl)) {
      _scope = Scope();
      _moduleScopes[canonicalUrl] = _scope;
      visitStylesheet(stylesheet);
    }
    var namespace = namespaceForPath(node.url.path);
    _namespaces[namespace] = canonicalUrl;
  }

  /// Visits each of [node]'s expressions and children.
  ///
  /// All of [node]'s arguments are declared as local variables in a new scope.
  @override
  void visitCallableDeclaration(CallableDeclaration node) {
    _scope = Scope(_scope);
    for (var argument in node.arguments.arguments) {
      _scope.variables[argument.name] = argument;
      if (argument.defaultValue != null) visitExpression(argument.defaultValue);
    }
    super.visitChildren(node);
    _scope = _scope.parent;
  }

  /// Visits the children of [node] with a local scope.
  ///
  /// Note: The children of a stylesheet are at the root, so we should not add
  /// a local scope.
  @override
  void visitChildren(ParentStatement node) {
    if (node is Stylesheet) {
      super.visitChildren(node);
      return;
    }
    _scope = Scope(_scope);
    super.visitChildren(node);
    _scope = _scope.parent;
  }

  /// Returns the scope for a given [namespace].
  ///
  /// If [namespace] is null or does not exist within this stylesheet, this
  /// returns the current stylesheet's scope.
  Scope _scopeForNamespace(String namespace) =>
      _moduleScopes[_namespaces[namespace]] ?? _scope;

  /// Declares a variable in the current scope.
  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    _scopeForNamespace(node.namespace).variables[node.name] = node;
    super.visitVariableDeclaration(node);
  }

  /// Visits the variable reference in [node], storing it in [_references].
  @override
  void visitVariableExpression(VariableExpression node) {
    var declaration =
        _scopeForNamespace(node.namespace).findVariable(node.name);
    if (declaration != null) {
      _references.variables[node] = declaration;
    }
    super.visitVariableExpression(node);
  }

  /// Declares a mixin in the current scope.
  @override
  void visitMixinRule(MixinRule node) {
    _scope.mixins[node.name] = node;
    super.visitMixinRule(node);
  }

  /// Visits an include rule, storing the mixin reference within [_references].
  @override
  void visitIncludeRule(IncludeRule node) {
    var declaration = _scopeForNamespace(node.namespace).findMixin(node.name);
    if (declaration != null) {
      _references.mixins[node] = declaration;
      super.visitIncludeRule(node);
    }
  }

  /// Declares a function in the current scope.
  @override
  void visitFunctionRule(FunctionRule node) {
    _scope.functions[node.name] = node;
    super.visitFunctionRule(node);
  }

  /// Visits a function call, storing it within [_references] if it corresponds
  /// to a user-defined function.
  @override
  void visitFunctionExpression(FunctionExpression node) {
    if (node.name.asPlain == null) return;

    var declaration =
        _scopeForNamespace(node.namespace).findFunction(node.name.asPlain);
    if (declaration != null) {
      _references.functions[node] = declaration;
    }
  }
}