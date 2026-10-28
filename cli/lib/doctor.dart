import 'devices.dart';
import 'env.dart';
import 'project.dart';
import 'sdk.dart';

/// Compares the project in [dir] with PocketRun. Returns true when it can run as is.
/// [quick] skips `flutter pub get` and the device check (used by `start`).
Future<bool> doctor(String dir, {bool quick = false, String? device}) async {
  final needs = await ProjectNeeds.read(dir, pubGet: !quick);
  final sdk = await Sdk.load();
  var ready = true;
  var needsSync = false;
  if (!quick) log('Checking ${needs.name} against PocketRun build ${sdk.build}...');

  final pc = pcFlutterVersion();
  if (sdk.flutterVersion != null && pc != sdk.flutterVersion) {
    ready = false;
    bad('Flutter on this PC is $pc but PocketRun was built with ${sdk.flutterVersion}. Run: pocketrun sdk build');
  } else if (!quick) {
    ok('Flutter $pc');
  }

  for (final plugin in needs.plugins.values) {
    final have = sdk.app.plugins[plugin.name];
    if (have == null) {
      ready = false;
      needsSync = true;
      bad('${plugin.label}: not in PocketRun');
    } else if (!have.sameAs(plugin)) {
      ready = false;
      needsSync = true;
      bad('${plugin.label}: PocketRun has ${have.label}');
    } else if (!quick) {
      ok(plugin.label);
    }
  }

  for (final channel in needs.channels) {
    if (sdk.channels.contains(channel)) {
      if (!quick) ok('Custom channel "$channel" (PocketRun extension)');
    } else {
      ready = false;
      bad('Custom channel "$channel": PocketRun has no native code for it');
    }
  }
  if (needs.customMainActivity && !quick) {
    note('${needs.name} has its own MainActivity code; only its channels above are covered.');
  }

  final appManifest = needs.permissions.keys.where((k) => !sdk.app.permissions.containsKey(k)).toList();
  final appQueries = needs.queries.keys.where((k) => !sdk.app.queries.containsKey(k)).toList();
  if (appManifest.isNotEmpty || appQueries.isNotEmpty) {
    ready = false;
    needsSync = true;
    bad('Manifest: missing ${[...appManifest, if (appQueries.isNotEmpty) '${appQueries.length} <queries> entries'].join(', ')}');
  } else if (!quick) {
    ok('Permissions and <queries>');
  }
  if ((needs.minSdk ?? 0) > sdk.minSdk) {
    ready = false;
    needsSync = true;
    bad('minSdk ${needs.minSdk} needed; PocketRun has ${sdk.minSdk}');
  }

  if (!quick) {
    final devices = await listDevices();
    if (devices.isNotEmpty) {
      final d = await pickDevice(device);
      final build = await installedBuild(d);
      if (build == null) {
        ready = false;
        bad('PocketRun is not installed on $d. Run: pocketrun install');
      } else if (build < sdk.build) {
        ready = false;
        bad('$d has PocketRun build $build; latest is ${sdk.build}. Run: pocketrun install');
      } else {
        ok('$d has PocketRun build $build');
      }
    } else {
      note('No device connected (not checked).');
    }
  }

  if (ready) {
    if (!quick) log('Ready: ${needs.name} runs in PocketRun. Start it with: pocketrun start');
  } else if (needsSync) {
    log('Run `pocketrun sdk sync` in this folder to add what is missing to PocketRun.');
  }
  return ready;
}
