import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const appId = 'dev.pocketrun.app';
const activity = '$appId/dev.pocketrun.pocketrun.MainActivity';

/// The PocketRun folder (holds app/, cli/, sdk/, templates/).
final Directory root = _findRoot();

Directory _findRoot() {
  final fromEnv = Platform.environment['POCKETRUN_HOME'];
  if (fromEnv != null) return Directory(fromEnv);
  // `dart run cli/bin/pocketrun.dart` or the compiled bin/pocketrun.exe.
  final start = Platform.script.path.endsWith('.dart')
      ? p.dirname(Platform.script.toFilePath())
      : p.dirname(Platform.resolvedExecutable);
  var dir = Directory(start);
  while (true) {
    if (File(p.join(dir.path, 'app', 'pubspec.yaml')).existsSync() && Directory(p.join(dir.path, 'cli')).existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) fail('Cannot find the PocketRun folder. Set POCKETRUN_HOME.');
    dir = parent;
  }
}

String inRoot(String relative) => p.join(root.path, relative);

String get appDir => inRoot('app');
String get sdkDir => inRoot('sdk');
String get apkPath => p.join(appDir, 'build', 'app', 'outputs', 'flutter-apk', 'app-debug.apk');

String get adbPath {
  final sdk = Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'] ??
      p.join(Platform.environment['LOCALAPPDATA'] ?? '', 'Android', 'Sdk');
  final adb = File(p.join(sdk, 'platform-tools', Platform.isWindows ? 'adb.exe' : 'adb'));
  return adb.existsSync() ? adb.path : 'adb';
}

Future<ProcessResult> adb(List<String> args) => Process.run(adbPath, args);

Future<String> adbOut(List<String> args) async => ((await adb(args)).stdout as String).trim();

/// Runs flutter, echoing its output, and fails when it fails.
Future<void> flutter(List<String> args, {required String dir, bool quiet = false}) async {
  final process = await Process.start('flutter', args, workingDirectory: dir, runInShell: true);
  final out = StringBuffer();
  process.stdout.transform(utf8.decoder).listen((s) => quiet ? out.write(s) : stdout.write(s));
  process.stderr.transform(utf8.decoder).listen((s) => quiet ? out.write(s) : stderr.write(s));
  final code = await process.exitCode;
  if (code != 0) {
    if (quiet) stderr.write(out);
    fail('`flutter ${args.join(' ')}` failed (exit $code).');
  }
}

/// The Flutter version installed on this PC, read from the SDK folder (fast; no `flutter` call).
String? pcFlutterVersion() {
  final which = Process.runSync(Platform.isWindows ? 'where' : 'which', ['flutter'], runInShell: true);
  final bin = LineSplitter.split(which.stdout as String).firstOrNull?.trim();
  if (bin == null || bin.isEmpty) return null;
  final sdk = p.dirname(p.dirname(bin));
  final json = File(p.join(sdk, 'bin', 'cache', 'flutter.version.json'));
  if (json.existsSync()) return (jsonDecode(json.readAsStringSync()) as Map)['frameworkVersion'] as String?;
  final version = File(p.join(sdk, 'version'));
  return version.existsSync() ? version.readAsStringSync().trim() : null;
}

Map<String, dynamic> readJson(String path, [Map<String, dynamic> fallback = const {}]) {
  final file = File(path);
  if (!file.existsSync()) return Map.of(fallback);
  return (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>();
}

void writeJson(String path, Object data) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(data)}\n');
}

void log(String message) => stdout.writeln('[pocketrun] $message');

void ok(String message) => stdout.writeln('  OK  $message');

void bad(String message) => stdout.writeln('  !!  $message');

void note(String message) => stdout.writeln('  --  $message');

Never fail(String message) {
  stderr.writeln('[pocketrun] $message');
  exit(1);
}
