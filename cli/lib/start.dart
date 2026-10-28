import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'devices.dart';
import 'doctor.dart';
import 'env.dart';
import 'sdk.dart';

final _vmServiceLine = RegExp(r'Dart VM service is listening on (http://\S+)');

/// `pocketrun start [-d device]`, run inside a Flutter project folder.
///
/// Restarts the PocketRun app on the device, attaches `flutter attach --machine` to its Dart VM,
/// hot-restarts into the project's code, then hot-reloads whenever a file under lib/ changes.
Future<void> start({String? deviceId}) async {
  final device = await pickDevice(deviceId);
  log('Device: $device');

  final sdk = await Sdk.load();
  final build = await installedBuild(device);
  if (build == null) fail('PocketRun is not installed on $device. Run: pocketrun install');
  if (build < sdk.build) log('Note: $device has PocketRun build $build; latest is ${sdk.build} (pocketrun install).');
  if (!await doctor(Directory.current.path, quick: true)) {
    log('Starting anyway; the parts listed above will fail inside PocketRun.');
  }

  var vmUrl = await _launchPocketRun(device);
  // Flutter only writes the Dart plugin registrant during run/attach, and a session started
  // before it existed leaves it out (plugins with Dart-side registration then fail with
  // MissingPluginException). After plugins change, attach once to write it, then start PocketRun
  // fresh and attach for real.
  final registrant = File('.dart_tool/flutter_build/dart_plugin_registrant.dart');
  final plugins = File('.flutter-plugins-dependencies');
  if (!registrant.existsSync() ||
      (plugins.existsSync() && registrant.lastModifiedSync().isBefore(plugins.lastModifiedSync()))) {
    log('Plugins changed; preparing the plugin registrant first...');
    await _attach(device, vmUrl, prepareOnly: true);
    if (registrant.existsSync()) registrant.setLastModifiedSync(DateTime.now());
    vmUrl = await _launchPocketRun(device);
  }
  exit(await _attach(device, vmUrl));
}

/// Starts PocketRun fresh and returns the device-side VM service URL from logcat.
Future<String> _launchPocketRun(Device device) async {
  await adb(['-s', device.id, 'shell', 'am', 'force-stop', appId]);
  await adb(['-s', device.id, 'logcat', '-c']);
  await adb(['-s', device.id, 'shell', 'am', 'start', '-n', activity]);
  for (var tries = 0; tries < 40; tries++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final log = await adbOut(['-s', device.id, 'logcat', '-d', '-s', 'flutter:I']);
    final match = _vmServiceLine.allMatches(log).lastOrNull;
    if (match != null) return match.group(1)!;
  }
  fail('PocketRun started but its Dart VM service never appeared in logcat.');
}

/// Attaches to PocketRun; returns flutter's exit code. [prepareOnly] detaches right after connecting.
Future<int> _attach(Device device, String vmUrl, {bool prepareOnly = false}) async {
  final flutter = await Process.start(
    'flutter',
    ['attach', '--machine', '-d', device.id, '--debug-url', vmUrl],
    runInShell: true,
  );
  String? appId;
  var nextId = 1;
  var busy = false;
  final watch = Stopwatch();

  void send(String method, Map<String, Object?> params) {
    flutter.stdin.writeln(jsonEncode([
      {'id': nextId++, 'method': method, 'params': params},
    ]));
  }

  void reload({required bool full}) {
    if (appId == null || busy) return;
    busy = true;
    watch
      ..reset()
      ..start();
    log(full ? 'Hot restart...' : 'Hot reload...');
    send('app.restart', {'appId': appId, 'fullRestart': full, 'pause': false, 'reason': 'pocketrun'});
  }

  flutter.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (!line.startsWith('[')) return stdout.writeln(line);
    for (final msg in (jsonDecode(line) as List).cast<Map<String, dynamic>>()) {
      final event = msg['event'];
      final params = (msg['params'] as Map?)?.cast<String, dynamic>() ?? const {};
      if (event == 'app.start') appId = params['appId'] as String?;
      // Preparing: Flutter writes the registrant while it hot-restarts, so restart once, then detach.
      if (prepareOnly) {
        if (event == 'app.started') {
          send('app.restart', {'appId': appId, 'fullRestart': true, 'pause': false, 'reason': 'pocketrun'});
        } else if (msg.containsKey('id') && (msg.containsKey('result') || msg.containsKey('error'))) {
          send('app.detach', {'appId': appId});
        }
        continue;
      }
      if (event == 'app.started') {
        log('Attached. Loading the project into PocketRun...');
        reload(full: true);
      }
      if (event == 'app.log') stdout.writeln('  ${params['log']}');
      if (event == 'app.progress' && params['finished'] != true && params['message'] != null) {
        log('${params['message']}');
      }
      if (event == 'app.stop') {
        log('Project stopped.');
        exit(0);
      }
      if (msg.containsKey('id') && (msg.containsKey('result') || msg.containsKey('error'))) {
        busy = false;
        final result = msg['result'];
        final success = msg['error'] == null && (result is! Map || result['code'] == 0);
        log(success ? 'Done in ${watch.elapsedMilliseconds} ms.' : 'Failed: ${msg['error'] ?? result}');
      }
    }
  });
  flutter.stderr.transform(utf8.decoder).listen(stderr.write);
  if (prepareOnly) return flutter.exitCode;

  // Hot reload on save, debounced so an editor writing several files counts once.
  Timer? debounce;
  Directory('lib').watch(recursive: true).listen((e) {
    if (!e.path.endsWith('.dart')) return;
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), () => reload(full: false));
  });

  log('Keys: r = reload, R = restart, q = quit');
  // Single keys without Enter in a real terminal; redirected or IDE consoles keep line mode.
  try {
    if (stdin.hasTerminal) stdin.lineMode = false;
  } on StdinException {
    // Not a console: keys arrive when Enter is pressed.
  }
  stdin.transform(utf8.decoder).listen((keys) {
    for (final key in keys.split('')) {
      switch (key) {
        case 'r':
          reload(full: false);
        case 'R':
          reload(full: true);
        case 'q':
          send('app.detach', {'appId': appId});
      }
    }
  });

  return flutter.exitCode;
}
