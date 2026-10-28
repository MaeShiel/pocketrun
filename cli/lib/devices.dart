import 'dart:convert';
import 'dart:io';

import 'env.dart';

class Device {
  Device(this.id, this.model);

  final String id;
  final String model;

  bool get isEmulator => id.startsWith('emulator-');

  @override
  String toString() => '$id ($model)';
}

Future<List<Device>> listDevices() async {
  final out = await adbOut(['devices', '-l']);
  return [
    for (final line in LineSplitter.split(out).skip(1))
      if (RegExp(r'^(\S+)\s+device\b').firstMatch(line) case final m?)
        Device(m.group(1)!, RegExp(r'model:(\S+)').firstMatch(line)?.group(1)?.replaceAll('_', ' ') ?? '?'),
  ];
}

/// The device to use: `-d` if given, else a real phone before an emulator.
Future<Device> pickDevice(String? wanted) async {
  final devices = await listDevices();
  if (wanted != null) {
    return devices.where((d) => d.id == wanted).firstOrNull ??
        fail('Device $wanted is not connected. Connected: ${devices.isEmpty ? 'none' : devices.join(', ')}');
  }
  if (devices.isEmpty) {
    fail('No device connected. Pair your phone (pocketrun pair) or start the emulator.');
  }
  return devices.where((d) => !d.isEmulator).firstOrNull ?? devices.first;
}

/// PocketRun's versionCode on [device], or null when it isn't installed.
Future<int?> installedBuild(Device device) async {
  final out = await adbOut(['-s', device.id, 'shell', 'dumpsys', 'package', appId]);
  final match = RegExp(r'versionCode=(\d+)').firstMatch(out);
  return match == null ? null : int.parse(match.group(1)!);
}

Future<void> installApk(Device device) async {
  if (!File(apkPath).existsSync()) fail('PocketRun is not built yet. Run: pocketrun sdk build');
  log('Installing PocketRun on $device...');
  final result = await adb(['-s', device.id, 'install', '-r', apkPath]);
  final out = '${result.stdout}${result.stderr}';
  if (out.contains('Success')) return log('Installed.');
  if (out.contains('INSUFFICIENT_STORAGE')) {
    fail('Not enough free space on $device. Free some space, or uninstall PocketRun first '
        '(this deletes the test data projects saved inside it): adb -s ${device.id} uninstall $appId');
  }
  fail('Install failed:\n$out');
}

/// `pocketrun pair <ip:port> <code>`: Android "Wireless debugging > Pair device with pairing code".
Future<void> pair(List<String> args) async {
  if (args.length < 2) {
    fail('Usage: pocketrun pair <ip:port> <code>\n'
        'On the phone: Developer options > Wireless debugging > Pair device with pairing code.');
  }
  final result = await adb(['pair', args[0], args[1]]);
  final out = '${result.stdout}${result.stderr}'.trim();
  if (!out.contains('Successfully paired')) fail('Pairing failed: $out');
  log('Paired.');

  // The connect port differs from the pairing port; adb usually finds it over mDNS.
  final ip = args[0].split(':').first;
  for (var tries = 0; tries < 10; tries++) {
    final services = await adbOut(['mdns', 'services']);
    final match = RegExp('_adb-tls-connect\\._tcp\\s+(${RegExp.escape(ip)}:\\d+)').firstMatch(services);
    if (match != null) return connect([match.group(1)!]);
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  log('Now connect with the IP address & Port shown on the Wireless debugging screen:');
  log('  pocketrun connect <ip:port>');
}

Future<void> connect(List<String> args) async {
  if (args.isEmpty) fail('Usage: pocketrun connect <ip:port>   (from the Wireless debugging screen)');
  final out = await adbOut(['connect', args[0]]);
  if (!out.contains('connected')) fail('Connect failed: $out');
  log('Connected to ${args[0]}.');
}

Future<void> showDevices(int? latestBuild) async {
  final devices = await listDevices();
  if (devices.isEmpty) return log('No devices. Pair your phone (pocketrun pair) or start the emulator.');
  for (final d in devices) {
    final build = await installedBuild(d);
    final state = switch (build) {
      null => 'PocketRun not installed (pocketrun install)',
      _ when latestBuild != null && build < latestBuild => 'PocketRun build $build, outdated (pocketrun install)',
      _ => 'PocketRun build $build',
    };
    stdout.writeln('  $d  -  $state');
  }
}
