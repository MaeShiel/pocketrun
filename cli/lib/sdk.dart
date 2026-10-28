import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'devices.dart';
import 'env.dart';
import 'project.dart';

/// What the PocketRun app currently contains: its resolved Android plugins, the custom channels
/// its extensions provide, its manifest and its minSdk.
class Sdk {
  Sdk._(this.app, this.channels, this.minSdk, this.catalog);

  final ProjectNeeds app;
  final Set<String> channels;
  final int minSdk;
  final Map<String, dynamic> catalog;

  String? get flutterVersion => catalog['flutter'] as String?;
  int get build => catalog['build'] as int? ?? 0;
  Map<String, String> get packages => (catalog['packages'] as Map? ?? {}).cast<String, String>();

  static Future<Sdk> load() async {
    final app = await ProjectNeeds.read(appDir, pubGet: false);
    final channels = <String>{};
    final ext = Directory(p.join(appDir, 'android', 'app', 'src', 'main', 'kotlin'));
    for (final f in ext.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.kt'))) {
      channels.addAll(RegExp(r'Channel\([^,]+,\s*"([^"]+)"').allMatches(f.readAsStringSync()).map((m) => m.group(1)!));
    }
    return Sdk._(app, channels, _gradleMinSdk(), readJson(catalogPath));
  }
}

String get catalogPath => p.join(sdkDir, 'catalog.json');
String get registryPath => p.join(sdkDir, 'projects.json');
String get starterDir => p.join(sdkDir, 'starter');
String get _gradlePath => p.join(appDir, 'android', 'app', 'build.gradle.kts');
String get _manifestPath => p.join(appDir, 'android', 'app', 'src', 'main', 'AndroidManifest.xml');

int _gradleMinSdk() =>
    int.parse(RegExp(r'maxOf\(flutter\.minSdkVersion,\s*(\d+)\)').firstMatch(File(_gradlePath).readAsStringSync())!.group(1)!);

/// Registry key for a project folder: relative to PocketRun when inside it, `~/...` under the home
/// folder, so projects.json has no machine-specific paths.
String projectKey(String dir) {
  final full = p.normalize(p.absolute(dir));
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  final String key;
  if (p.isWithin(root.path, full)) {
    key = p.relative(full, from: root.path);
  } else if (home != null && p.isWithin(home, full)) {
    key = '~/${p.relative(full, from: home)}';
  } else {
    key = full;
  }
  return key.replaceAll(r'\', '/');
}

Map<String, Map<String, dynamic>> _projects() => (readJson(registryPath)['projects'] as Map? ?? {}).map(
  // Keys written by older versions were absolute paths.
  (k, v) => MapEntry(p.isAbsolute(k as String) ? projectKey(k) : k, (v as Map).cast<String, dynamic>()),
);

/// `pocketrun sdk sync`: makes PocketRun cover the project in [dir], then rebuilds and installs it.
Future<void> sync(String dir, {bool force = false, bool install = true, String? device}) async {
  final needs = await ProjectNeeds.read(dir);
  log('Syncing ${needs.name} into PocketRun...');
  final key = projectKey(needs.dir);
  final projects = _projects()..remove(key);

  // A plugin can be in PocketRun at one version only.
  final conflicts = <String>[];
  for (final entry in projects.entries) {
    final theirs = (entry.value['plugins'] as Map).cast<String, dynamic>();
    for (final mine in needs.plugins.values) {
      final other = theirs[mine.name];
      if (other == null) continue;
      final otherPlugin = Plugin.fromJson(mine.name, (other as Map).cast<String, dynamic>());
      if (!otherPlugin.sameAs(mine)) {
        conflicts.add('${mine.label} here, but ${entry.value['name']} uses ${otherPlugin.label}');
      }
    }
  }
  if (conflicts.isNotEmpty && !force) {
    bad('Version conflicts with other registered projects:');
    for (final c in conflicts) {
      stdout.writeln('      $c');
    }
    fail('Use the same versions in both projects, or run `pocketrun sdk sync --force` to let '
        '${needs.name} win (the other project then needs a re-sync later).');
  }

  projects[key] = needs.toJson();
  writeJson(registryPath, {'projects': projects});
  _writePins(projects);
  _mergeManifest(needs);
  _raiseMinSdk(needs);
  await _recordPackages(needs);

  final sdk = await Sdk.load();
  final missing = needs.channels.difference(sdk.channels);
  if (missing.isNotEmpty) {
    bad('Custom native channels PocketRun does not provide yet: ${missing.join(', ')}');
    note('Port that Kotlin code from ${needs.name}/android into '
        'app/android/app/src/main/kotlin/dev/pocketrun/pocketrun/extensions/ (see NavRouteIntents.kt).');
  }
  await build(install: install, device: device);
}

/// Rewrites the generated plugin block in app/pubspec.yaml from every registered project.
void _writePins(Map<String, Map<String, dynamic>> projects) {
  final pins = <String, Plugin>{};
  for (final project in projects.values) {
    for (final e in (project['plugins'] as Map).entries) {
      pins[e.key as String] = Plugin.fromJson(e.key as String, (e.value as Map).cast<String, dynamic>());
    }
  }
  final names = pins.keys.toList()..sort();
  final lines = [
    for (final n in names)
      if (pins[n]!.path == null)
        '  $n: ${pins[n]!.version}'
      else
        "  $n:\n    path: '${pins[n]!.path!.replaceAll(r'\', '/')}'",
  ];
  final file = File(p.join(appDir, 'pubspec.yaml'));
  final text = file.readAsStringSync();
  final afterBegin = text.indexOf('\n', text.indexOf('  # pocketrun-sdk:begin')) + 1;
  final end = text.indexOf('  # pocketrun-sdk:end');
  file.writeAsStringSync('${text.substring(0, afterBegin)}${lines.map((l) => '$l\n').join()}${text.substring(end)}');
}

void _mergeManifest(ProjectNeeds needs) {
  final file = File(_manifestPath);
  final before = file.readAsStringSync();
  final after = Manifest.normalize(Manifest.merge(before, needs, from: needs.name));
  if (after != before) {
    file.writeAsStringSync(after);
    log('Added ${needs.name}\'s permissions/queries to PocketRun\'s manifest.');
  }
}

void _raiseMinSdk(ProjectNeeds needs) {
  final want = needs.minSdk;
  if (want == null || want <= _gradleMinSdk()) return;
  final file = File(_gradlePath);
  file.writeAsStringSync(
    file.readAsStringSync().replaceFirst(RegExp(r'maxOf\(flutter\.minSdkVersion,\s*\d+\)'), 'maxOf(flutter.minSdkVersion, $want)'),
  );
  log('Raised PocketRun minSdk to $want for ${needs.name}.');
}

/// Remembers the project's direct plugin dependencies (e.g. geolocator 14.1.2) so `pocketrun add`
/// and the AI rules can offer exactly those versions.
Future<void> _recordPackages(ProjectNeeds needs) async {
  final catalog = readJson(catalogPath);
  final packages = (catalog['packages'] as Map? ?? {}).cast<String, String>();
  final starterOnly = needs.dir == p.normalize(starterDir) ? _starterRequested() : null;
  for (final (name, version, path) in directDeps(needs.dir)) {
    if (starterOnly != null && !starterOnly.contains(name)) continue;
    if (path != null && _isPlugin(path)) packages[name] = version;
  }
  catalog['packages'] = Map.fromEntries(packages.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  writeJson(catalogPath, catalog);
}

/// Direct `dependencies:` of a project with resolved versions and package folders.
List<(String, String, String?)> directDeps(String dir) {
  final lock = File(p.join(dir, 'pubspec.lock'));
  final config = File(p.join(dir, '.dart_tool', 'package_config.json'));
  if (!lock.existsSync() || !config.existsSync()) return const [];
  final roots = <String, String>{
    for (final pkg in ((jsonDecode(config.readAsStringSync()) as Map)['packages'] as List).cast<Map>())
      pkg['name'] as String: _uriToPath(pkg['rootUri'] as String, p.join(dir, '.dart_tool')),
  };
  final out = <(String, String, String?)>[];
  String? name;
  var direct = false;
  for (final line in LineSplitter.split(lock.readAsStringSync())) {
    final top = RegExp(r'^  (\S+):$').firstMatch(line);
    if (top != null) {
      name = top.group(1);
      direct = false;
    } else if (line.contains('dependency: "direct main"')) {
      direct = true;
    } else if (direct && name != null) {
      final m = RegExp(r'^    version: "(.+)"').firstMatch(line);
      if (m != null) out.add((name, m.group(1)!, roots[name]));
    }
  }
  return out;
}

String _uriToPath(String uri, String base) =>
    uri.startsWith('file:') ? Uri.parse(uri).toFilePath() : p.normalize(p.join(base, Uri.decodeFull(uri)));

bool _isPlugin(String packageDir) {
  final pubspec = File(p.join(packageDir, 'pubspec.yaml'));
  return pubspec.existsSync() && RegExp(r'^\s+plugin:\s*$', multiLine: true).hasMatch(pubspec.readAsStringSync());
}

/// `pocketrun sdk build`: resolves and builds PocketRun, then installs it on the device.
Future<void> build({bool install = true, String? device}) async {
  final catalog = readJson(catalogPath);
  final next = (catalog['build'] as int? ?? 1) + 1;
  log('Building PocketRun (build $next)...');
  await flutter(['pub', 'get'], dir: appDir, quiet: true);
  await flutter(['build', 'apk', '--debug', '--build-number', '$next'], dir: appDir);
  catalog
    ..['build'] = next
    ..['flutter'] = pcFlutterVersion()
    ..['builtAt'] = DateTime.now().toIso8601String();
  writeJson(catalogPath, catalog);
  log('Built PocketRun build $next.');
  if (!install) return;
  final devices = await listDevices();
  if (devices.isEmpty) return log('No device connected; install later with: pocketrun install');
  await installApk(await pickDevice(device));
}

// ---------------------------------------------------------------------------------------------
// `pocketrun sdk add <package...>`: preloads plugins into PocketRun without a project.
// The starter project (sdk/starter) holds them; it resolves around the plugins PocketRun already
// pins, so adding a package never changes a version another project relies on.

const _requestedBegin = '  # pocketrun-starter:packages';
const _pinsBegin = '  # pocketrun-starter:pins';
const _blockEnd = '  # pocketrun-starter:end';

Set<String> _starterRequested() {
  final file = File(p.join(starterDir, 'pubspec.yaml'));
  if (!file.existsSync()) return {};
  final text = file.readAsStringSync();
  final block = text.substring(text.indexOf(_requestedBegin), text.indexOf(_pinsBegin));
  return RegExp(r'^  (\w+):', multiLine: true).allMatches(block).map((m) => m.group(1)!).toSet();
}

Future<void> sdkAdd(List<String> packages, {bool install = true, String? device}) async {
  if (packages.isEmpty) fail('Usage: pocketrun sdk add <package> [package...]');
  if (!Directory(starterDir).existsSync()) {
    log('Creating the SDK starter project...');
    await flutter(['create', '--empty', '--platforms', 'android', '--project-name', 'pocketrun_starter', starterDir],
        dir: sdkDir, quiet: true);
  }
  final requested = {..._starterRequestedVersions(), for (final pkg in packages) pkg: 'any'};
  final pins = <String, String>{};
  for (final project in _projects().entries.where((e) => e.key != projectKey(starterDir))) {
    for (final e in (project.value['plugins'] as Map).entries) {
      final plugin = Plugin.fromJson(e.key as String, (e.value as Map).cast<String, dynamic>());
      if (plugin.path == null && !requested.containsKey(plugin.name)) pins[plugin.name] = plugin.version;
    }
  }
  _writeStarterPubspec(requested, pins);
  log('Resolving ${packages.join(', ')} against PocketRun\'s current plugins...');
  await flutter(['pub', 'get'], dir: starterDir);

  // Freeze what pub picked, so the starter (and the catalog) stays stable.
  final resolved = {for (final (name, version, _) in directDeps(starterDir)) name: version};
  _writeStarterPubspec({for (final pkg in requested.keys) pkg: resolved[pkg] ?? requested[pkg]!}, pins);
  for (final pkg in packages) {
    log('  $pkg ${resolved[pkg] ?? '?'}');
  }
  await sync(starterDir, install: install, device: device);
}

Map<String, String> _starterRequestedVersions() {
  final file = File(p.join(starterDir, 'pubspec.yaml'));
  if (!file.existsSync() || !file.readAsStringSync().contains(_requestedBegin)) return {};
  final text = file.readAsStringSync();
  final block = text.substring(text.indexOf(_requestedBegin), text.indexOf(_pinsBegin));
  return {for (final m in RegExp(r'^  (\w+): (\S+)', multiLine: true).allMatches(block)) m.group(1)!: m.group(2)!};
}

void _writeStarterPubspec(Map<String, String> requested, Map<String, String> pins) {
  String lines(Map<String, String> m) => (m.keys.toList()..sort()).map((k) => '  $k: ${m[k]}\n').join();
  File(p.join(starterDir, 'pubspec.yaml')).writeAsStringSync('''
name: pocketrun_starter
description: "Plugins preloaded into PocketRun (managed by `pocketrun sdk add`)."
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: ^3.11.5

dependencies:
  flutter:
    sdk: flutter
$_requestedBegin
${lines(requested)}$_pinsBegin (PocketRun's existing versions; keeps them unchanged)
${lines(pins)}$_blockEnd

flutter:
  uses-material-design: true
''');
}
