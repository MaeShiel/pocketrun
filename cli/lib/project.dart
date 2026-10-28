import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'env.dart';

/// One Android plugin a project needs: hosted at an exact version, or a local/git path.
class Plugin {
  Plugin(this.name, this.version, {this.path});

  factory Plugin.fromJson(String name, Map<String, dynamic> j) =>
      Plugin(name, j['version'] as String, path: j['path'] as String?);

  final String name;
  final String version;

  /// Set for non-hosted plugins (path or git dependencies); PocketRun depends on them by path.
  final String? path;

  bool sameAs(Plugin other) => version == other.version && path == other.path;

  String get label => path == null ? '$name $version' : '$name (path ${p.basename(path!)})';

  Map<String, dynamic> toJson() => {'version': version, if (path != null) 'path': path};
}

/// What a Flutter project needs from PocketRun's native side.
class ProjectNeeds {
  ProjectNeeds._(this.dir);

  final String dir;
  String name = '';
  final plugins = <String, Plugin>{};
  final channels = <String>{};
  final permissions = <String, String>{}; // name -> full <uses-permission .../> element
  final features = <String, String>{};
  final queries = <String, String>{}; // normalized key -> element text
  int? minSdk;
  bool customMainActivity = false;

  /// Reads [dir]; runs `flutter pub get` first when the plugin list is missing or stale.
  static Future<ProjectNeeds> read(String dir, {bool pubGet = true}) async {
    final pubspec = File(p.join(dir, 'pubspec.yaml'));
    if (!pubspec.existsSync()) fail('No pubspec.yaml in $dir. Run this in a Flutter project folder.');
    final deps = File(p.join(dir, '.flutter-plugins-dependencies'));
    final lock = File(p.join(dir, 'pubspec.lock'));
    final stale = !deps.existsSync() ||
        deps.lastModifiedSync().isBefore(pubspec.lastModifiedSync()) ||
        (lock.existsSync() && deps.lastModifiedSync().isBefore(lock.lastModifiedSync()));
    if (stale && pubGet) await flutter(['pub', 'get'], dir: dir, quiet: true);

    final needs = ProjectNeeds._(p.normalize(p.absolute(dir)));
    needs.name = RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(pubspec.readAsStringSync())?.group(1) ?? '';
    if (deps.existsSync()) needs._readPlugins(deps);
    needs._readChannels();
    needs._readManifest();
    needs._readGradle();
    return needs;
  }

  void _readPlugins(File deps) {
    final json = jsonDecode(deps.readAsStringSync()) as Map;
    for (final entry in ((json['plugins'] as Map)['android'] as List? ?? const []).cast<Map>()) {
      final name = entry['name'] as String;
      final path = entry['path'] as String;
      final version = RegExp(r'^version:\s*(\S+)', multiLine: true)
              .firstMatch(File(p.join(path, 'pubspec.yaml')).readAsStringSync())
              ?.group(1) ??
          '0.0.0';
      final hosted = path.replaceAll('/', r'\').contains(r'\hosted\');
      plugins[name] = Plugin(name, version, path: hosted ? null : p.normalize(path));
    }
  }

  /// Platform channels the project's own Dart code opens (plugins bring their own native side).
  void _readChannels() {
    final lib = Directory(p.join(dir, 'lib'));
    if (!lib.existsSync()) return;
    final pattern = RegExp(r'''(?:Method|Event|BasicMessage)Channel\s*\(\s*['"]([^'"]+)['"]''');
    for (final file in lib.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      channels.addAll(pattern.allMatches(file.readAsStringSync()).map((m) => m.group(1)!));
    }
    final main = Directory(p.join(dir, 'android', 'app', 'src', 'main'));
    if (!main.existsSync()) return;
    for (final file in main.listSync(recursive: true).whereType<File>()) {
      final base = p.basenameWithoutExtension(file.path);
      if (base != 'MainActivity' || !(file.path.endsWith('.kt') || file.path.endsWith('.java'))) continue;
      final code = file.readAsStringSync();
      final plain = RegExp(r'class\s+MainActivity\s*:\s*FlutterActivity\(\)\s*(\{\s*\})?\s*$').hasMatch(code.trim()) ||
          RegExp(r'class\s+MainActivity\s+extends\s+FlutterActivity\s*\{\s*\}').hasMatch(code);
      customMainActivity = !plain;
    }
  }

  void _readManifest() {
    final file = File(p.join(dir, 'android', 'app', 'src', 'main', 'AndroidManifest.xml'));
    if (!file.existsSync()) return;
    final m = Manifest.parse(file.readAsStringSync());
    permissions.addAll(m.permissions);
    features.addAll(m.features);
    queries.addAll(m.queries);
  }

  void _readGradle() {
    for (final name in ['build.gradle.kts', 'build.gradle']) {
      final file = File(p.join(dir, 'android', 'app', name));
      if (!file.existsSync()) continue;
      final match = RegExp(r'minSdk(?:Version)?\s*=?\s*(?:maxOf\(\s*flutter\.minSdkVersion\s*,\s*)?(\d+)')
          .firstMatch(file.readAsStringSync());
      minSdk = match == null ? null : int.parse(match.group(1)!);
      return;
    }
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'plugins': {for (final pl in plugins.values) pl.name: pl.toJson()},
  };
}

/// The parts of an AndroidManifest.xml PocketRun has to cover, and merging them into another.
class Manifest {
  Manifest._();

  final permissions = <String, String>{};
  final features = <String, String>{};
  final queries = <String, String>{};

  static final _permission = RegExp(r'<uses-permission\b[^>]*?android:name="([^"]+)"[^>]*?/>', dotAll: true);
  static final _feature = RegExp(r'<uses-feature\b[^>]*?android:name="([^"]+)"[^>]*?/>', dotAll: true);
  static final _queries = RegExp(r'<queries>([\s\S]*?)</queries>');
  static final _queryItem = RegExp(r'<package\b[^>]*/>|<intent>[\s\S]*?</intent>|<provider\b[^>]*/>');

  static Manifest parse(String xml) {
    final m = Manifest._();
    final noComments = xml.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
    for (final match in _permission.allMatches(noComments)) {
      m.permissions[match.group(1)!] = match.group(0)!;
    }
    for (final match in _feature.allMatches(noComments)) {
      m.features[match.group(1)!] = match.group(0)!;
    }
    for (final block in _queries.allMatches(noComments)) {
      for (final item in _queryItem.allMatches(block.group(1)!)) {
        m.queries[_key(item.group(0)!)] = item.group(0)!;
      }
    }
    return m;
  }

  /// Plugins often declare storage permissions with their own maxSdkVersion; PocketRun's value
  /// (the highest a project asked for) must win the manifest merge instead of failing the build.
  static String normalize(String xml) {
    var out = xml.replaceAllMapped(_permission, (m) {
      final element = m.group(0)!;
      if (!element.contains('android:maxSdkVersion') || element.contains('tools:replace')) return element;
      return element.replaceFirst(RegExp(r'\s*/>$'), '\n        tools:replace="android:maxSdkVersion" />');
    });
    if (out.contains('tools:') && !out.contains('xmlns:tools')) {
      out = out.replaceFirst('<manifest ', '<manifest xmlns:tools="http://schemas.android.com/tools"\n    ');
    }
    return out;
  }

  static String _key(String element) => element.replaceAll(RegExp(r'\s+'), ' ').replaceAll('> <', '><').trim();

  /// Adds [needs]' permissions, features and queries missing from [xml]; returns the new text.
  static String merge(String xml, ProjectNeeds needs, {required String from}) {
    final have = parse(xml);
    var out = xml;
    final addTop = [
      for (final e in needs.permissions.entries)
        if (!have.permissions.containsKey(e.key)) e.value,
      for (final e in needs.features.entries)
        if (!have.features.containsKey(e.key)) e.value,
    ];
    if (addTop.isNotEmpty) {
      final at = out.indexOf('<application');
      out = '${out.substring(0, at)}<!-- Added for $from -->\n    ${addTop.join('\n    ')}\n\n    ${out.substring(at)}';
    }
    final addQueries = [
      for (final e in needs.queries.entries)
        if (!have.queries.containsKey(e.key)) e.value,
    ];
    if (addQueries.isNotEmpty) {
      final items = '<!-- Added for $from -->\n        ${addQueries.join('\n        ')}';
      final at = out.lastIndexOf('</queries>');
      out = at >= 0
          ? '${out.substring(0, at)}    $items\n    ${out.substring(at)}'
          : out.replaceFirst('</manifest>', '    <queries>\n        $items\n    </queries>\n</manifest>');
    }
    return out;
  }
}
