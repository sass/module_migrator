// Copyright 2018 Google LLC
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:io';

import 'package:sass_migrator/runner.dart';

import 'package:path/path.dart' as p;
import 'package:term_glyph/term_glyph.dart' as glyph;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

/// Runs all migration tests. See migrations/README.md for details.
void main() {
  glyph.ascii = true;
  testMigrator("module");
}

void testMigrator(String migrator) {
  var migrationTests = Directory("test/migrations/$migrator");
  group(migrator, () {
    for (var file in migrationTests.listSync().whereType<File>()) {
      if (file.path.endsWith(".hrx")) {
        test(p.basenameWithoutExtension(file.path),
            () => testHrx(file, migrator));
      }
    }
  });
}

/// Run the migration test in [hrxFile]. See migrations/README.md for details.
testHrx(File hrxFile, String migrator) async {
  var files = HrxTestFiles(hrxFile.readAsStringSync());
  await files.unpack();
  p.PathMap<String> migrated;
  var entrypoints =
      files.input.keys.where((path) => path.startsWith("entrypoint"));
  var arguments = [migrator]..addAll(files.arguments)..addAll(entrypoints);
  await expect(
      () => IOOverrides.runZoned(() async {
            migrated = await MigratorRunner().run(arguments);
          }, getCurrentDirectory: () => Directory(d.sandbox)),
      prints(files.expectedLog?.replaceAll("\$TEST_DIR", d.sandbox) ?? ""));
  for (var file in files.input.keys) {
    expect(migrated[p.join(d.sandbox, file)], equals(files.output[file]),
        reason: 'Incorrect migration of $file.');
  }
}

class HrxTestFiles {
  Map<String, String> input = {};
  Map<String, String> output = {};
  List<String> arguments = [];
  String expectedLog;

  HrxTestFiles(String hrxText) {
    // TODO(jathak): Replace this with an actual HRX parser.
    String filename;
    String contents;
    for (var line in hrxText.substring(0, hrxText.length - 1).split("\n")) {
      if (line.startsWith("<==> ")) {
        if (filename != null) {
          _load(filename, contents.substring(0, contents.length - 1));
        }
        filename = line.substring(5).trim();
        contents = "";
      } else {
        contents += line + "\n";
      }
    }
    if (filename != null) _load(filename, contents);
  }

  void _load(String filename, String contents) {
    if (filename.startsWith("input/")) {
      input[filename.substring(6)] = contents;
    } else if (filename.startsWith("output/")) {
      output[filename.substring(7)] = contents;
    } else if (filename == "log.txt") {
      expectedLog = contents;
    } else if (filename == "arguments") {
      arguments = contents.trim().split(" ");
    }
  }

  /// Unpacks this test's input files into a temporary directory.
  Future unpack() async {
    for (var file in input.keys) {
      var parts = p.split(file);
      d.Descriptor descriptor = d.file(parts.removeLast(), input[file]);
      while (parts.isNotEmpty) {
        descriptor = d.dir(parts.removeLast(), [descriptor]);
      }
      await descriptor.create();
    }
  }
}
