import 'dart:io';

import 'package:pocketrun_cli/create.dart';
import 'package:pocketrun_cli/devices.dart';
import 'package:pocketrun_cli/doctor.dart';
import 'package:pocketrun_cli/env.dart';
import 'package:pocketrun_cli/sdk.dart';
import 'package:pocketrun_cli/start.dart';

const _help = '''
PocketRun - run Flutter projects on your phone without installing them.

Phone
  pocketrun pair <ip:port> <code>   Pair over Wi-Fi (Wireless debugging > Pair device with pairing code)
  pocketrun connect <ip:port>       Connect to a paired phone
  pocketrun devices                 Connected devices and their PocketRun build
  pocketrun install                 Install the latest PocketRun build on the device

In a project folder
  pocketrun start                   Run this project inside PocketRun, hot reload on save
  pocketrun doctor                  Can this project run in PocketRun? What is missing?
  pocketrun add <package>           Add a package at the version PocketRun has
  pocketrun rules                   (Re)write AGENTS.md for Cursor / Claude
  pocketrun sdk sync [--force]      Add this project's plugins/permissions to PocketRun, rebuild, install

PocketRun itself
  pocketrun new <name> [--org id]   New Flutter project ready for PocketRun
  pocketrun sdk add <package...>    Preload plugins into PocketRun, rebuild, install
  pocketrun sdk build               Rebuild PocketRun (e.g. after a Flutter upgrade), install

Options: -d <device> picks the device (default: your phone before the emulator).
''';

Future<void> main(List<String> args) async {
  final rest = [...args];
  String? device;
  final d = rest.indexOf('-d');
  if (d >= 0 && d + 1 < rest.length) {
    device = rest[d + 1];
    rest.removeRange(d, d + 2);
  }
  String? option(String name) {
    final i = rest.indexOf(name);
    if (i < 0 || i + 1 >= rest.length) return null;
    final value = rest[i + 1];
    rest.removeRange(i, i + 2);
    return value;
  }

  final flag = rest.remove('--force');
  final noInstall = rest.remove('--no-install');
  final here = Directory.current.path;

  switch (rest) {
    case ['start']:
      await start(deviceId: device);
    case ['doctor']:
      exit(await doctor(here, device: device) ? 0 : 1);
    case ['pair', ...final a]:
      await pair(a);
    case ['connect', ...final a]:
      await connect(a);
    case ['devices']:
      await showDevices((await Sdk.load()).build);
    case ['install']:
      await installApk(await pickDevice(device));
    case ['add', ...final pkgs]:
      await add(pkgs);
    case ['rules']:
      await writeRules(here);
      log('Wrote AGENTS.md, CLAUDE.md and .cursor/rules/pocketrun.mdc');
    case ['new', ...]:
      final org = option('--org') ?? 'com.example';
      if (rest.length != 2) fail('Usage: pocketrun new <name> [--org com.yourname]');
      await create(rest[1], org: org);
    case ['sdk', 'sync']:
      await sync(here, force: flag, install: !noInstall, device: device);
    case ['sdk', 'add', ...final pkgs]:
      await sdkAdd(pkgs, install: !noInstall, device: device);
    case ['sdk', 'build']:
      await build(install: !noInstall, device: device);
    default:
      stdout.write(_help);
      exit(rest.isEmpty || rest.first == 'help' ? 0 : 64);
  }
}
