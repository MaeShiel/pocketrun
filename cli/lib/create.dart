import 'dart:io';

import 'package:path/path.dart' as p;

import 'doctor.dart';
import 'env.dart';
import 'sdk.dart';

/// `pocketrun new <name> [--org com.example]`: a Flutter project that runs in PocketRun as is.
Future<void> create(String name, {String org = 'com.example'}) async {
  if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
    fail('Use a lowercase name with letters, numbers and _ (for example my_app).');
  }
  final dir = p.join(Directory.current.path, name);
  if (Directory(dir).existsSync()) fail('$dir already exists.');
  log('Creating $name...');
  await flutter(['create', '--empty', '--platforms', 'android', '--org', org, name], dir: Directory.current.path, quiet: true);
  for (final file in Directory(inRoot('templates/app')).listSync(recursive: true).whereType<File>()) {
    final target = File(p.join(dir, p.relative(file.path, from: inRoot('templates/app'))));
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(file.readAsStringSync().replaceAll('{{name}}', name));
  }
  await writeRules(dir);
  log('Created $dir');
  log('Next:  cd $name   then   pocketrun start');
  if (org == 'com.example') log('Before a release APK, give it your own id: pocketrun new $name --org com.yourname');
}

/// `pocketrun add <package>`: adds a package at the exact version PocketRun has.
Future<void> add(List<String> packages) async {
  if (packages.isEmpty) fail('Usage: pocketrun add <package> [package...]');
  final sdk = await Sdk.load();
  final args = [
    for (final pkg in packages) sdk.packages.containsKey(pkg) ? '$pkg:${sdk.packages[pkg]}' : pkg,
  ];
  for (final pkg in packages) {
    log(sdk.packages.containsKey(pkg)
        ? '$pkg ${sdk.packages[pkg]} (the version inside PocketRun)'
        : '$pkg is not a PocketRun plugin; adding the latest version.');
  }
  await flutter(['pub', 'add', ...args], dir: Directory.current.path, quiet: true);
  if (!await doctor(Directory.current.path, quick: true)) {
    log('This package needs native code PocketRun does not have yet.');
    log('Run `pocketrun sdk sync` to add it (rebuilds and reinstalls PocketRun, a few minutes).');
  } else {
    log('Added. It works in PocketRun right away.');
  }
}

/// Writes AGENTS.md (+ Cursor and Claude Code pointers) telling AI assistants what PocketRun has.
Future<void> writeRules(String dir) async {
  final sdk = await Sdk.load();
  final rows = (sdk.packages.keys.toList()..sort()).map((k) => '| `$k` | `${sdk.packages[k]}` |').join('\n');
  File(p.join(dir, 'AGENTS.md')).writeAsStringSync('''
# Notes for AI assistants

This app is tested in **PocketRun**: a pre-installed Android app that runs this project's Dart code
from the PC with hot reload (`pocketrun start`). PocketRun can only run native (Android) code it
already contains, so follow these rules.

## Rules

1. **Flutter ${sdk.flutterVersion ?? '(see `pocketrun doctor`)'}**, Android only. Do not upgrade Flutter or the Dart SDK constraint.
2. **Plugins (packages with Android code): only the ones below, at exactly these versions.**
   Add them with `pocketrun add <package>`, never `flutter pub add`. If a feature truly needs a plugin
   that is not listed, say so and ask first; adding it needs `pocketrun sdk sync`, which rebuilds PocketRun.
3. **Pure-Dart packages are fine** (state management, http, json, intl, maps drawn in Dart, ...).
4. **No new native code**: do not edit `android/app/src/main/kotlin` or `MainActivity`, and do not add
   `MethodChannel`s of your own. Android permissions go in `android/app/src/main/AndroidManifest.xml`.
5. Release APKs: `pocketrun build apk` (signs, builds, installs). Never commit `android/key.properties`
   or keystores.

## Plugins inside PocketRun (build ${sdk.build})

| Package | Version |
|---|---|
$rows

Check the project any time with `pocketrun doctor`.
''');
  File(p.join(dir, 'CLAUDE.md')).writeAsStringSync('@AGENTS.md\n');
  File(p.join(dir, '.cursor', 'rules', 'pocketrun.mdc'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('---\ndescription: PocketRun compatibility rules\nalwaysApply: true\n---\n\n'
        'Follow AGENTS.md in the project root: only the plugins and versions listed there, '
        'added with `pocketrun add`; no native Android code or new MethodChannels.\n');
}
