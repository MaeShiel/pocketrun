import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:qr/qr.dart';

import 'devices.dart';
import 'env.dart';

/// `pocketrun build apk`: a signed release APK of the project in the current folder, installed on
/// the phone over adb, or offered as a Wi-Fi download behind a QR code.
Future<void> buildApk({String? appId, bool bump = false, bool install = true, bool qr = false, String? device}) async {
  final dir = Directory.current.path;
  final pubspec = File(p.join(dir, 'pubspec.yaml'));
  if (!pubspec.existsSync()) fail('No pubspec.yaml here. Run this in your Flutter project folder.');
  final gradle = File(p.join(dir, 'android', 'app', 'build.gradle.kts'));
  if (!gradle.existsSync()) {
    fail('android/app/build.gradle.kts not found. (Older Groovy build.gradle projects need signing set up by hand.)');
  }

  final name = RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(pubspec.readAsStringSync())!.group(1)!;
  if (bump) _bumpBuildNumber(pubspec);
  final version = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec.readAsStringSync())?.group(1) ?? '1.0.0+1';

  if (appId != null) _setAppId(gradle, appId);
  final id = _appId(gradle);
  if (id.startsWith('com.example')) {
    fail('The app id is still "$id". Give the app its own id once; an installed app can never change it:\n'
        '  pocketrun build apk --app-id com.yourname.$name');
  }

  await _ensureSigning(dir, gradle, id);
  log('Building $name $version ($id)...');
  await flutter(['build', 'apk', '--release'], dir: dir);

  final out = File(p.join(dir, 'build', 'pocketrun', '$name-${version.replaceAll('+', '-')}.apk'));
  out.parent.createSync(recursive: true);
  File(p.join(dir, 'build', 'app', 'outputs', 'flutter-apk', 'app-release.apk')).copySync(out.path);
  log('APK: ${out.path} (${(out.lengthSync() / 1048576).toStringAsFixed(1)} MB)');
  final signer = await _signer(out.path);
  if (signer != null) log('Signed by: $signer');

  if (install && !qr) {
    final devices = await listDevices();
    if (devices.isNotEmpty) return _install(await pickDevice(device), out.path, id);
    log('No phone connected over adb; offering a Wi-Fi download instead.');
    qr = true;
  }
  if (qr) await _serve(out);
}

String _appId(File gradle) =>
    RegExp(r'applicationId\s*=\s*"([^"]+)"').firstMatch(gradle.readAsStringSync())?.group(1) ??
    fail('No applicationId in ${gradle.path}.');

void _setAppId(File gradle, String id) {
  if (!RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$').hasMatch(id)) {
    fail('"$id" is not a valid app id. Use lowercase parts separated by dots, e.g. com.yourname.myapp');
  }
  gradle.writeAsStringSync(gradle.readAsStringSync().replaceFirst(
    RegExp(r'(\s*// TODO: Specify your own unique Application ID[^\n]*\n)?(\s*)applicationId\s*=\s*"[^"]+"'),
    '\n        applicationId = "$id"',
  ));
  log('App id set to $id.');
}

void _bumpBuildNumber(File pubspec) {
  final text = pubspec.readAsStringSync();
  final m = RegExp(r'^version:\s*([^+\s]+)(?:\+(\d+))?', multiLine: true).firstMatch(text);
  if (m == null) fail('No version: line in pubspec.yaml.');
  final next = '${m.group(1)}+${int.parse(m.group(2) ?? '0') + 1}';
  pubspec.writeAsStringSync(text.replaceFirst(m.group(0)!, 'version: $next'));
  log('Version bumped to $next.');
}

// ---------------------------------------------------------------------------------------------
// Signing. A release key is made once per app id and kept outside the project in
// ~/.pocketrun/keys (keystore + passwords), so a git push never publishes it. The project gets a
// git-ignored android/key.properties pointing at it, plus the usual Flutter signing block.

String get _keysDir => p.join(Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']!, '.pocketrun', 'keys');

Future<void> _ensureSigning(String dir, File gradle, String id) async {
  final keyProperties = File(p.join(dir, 'android', 'key.properties'));
  final text = gradle.readAsStringSync();
  if (text.contains('key.properties')) {
    if (!keyProperties.existsSync()) {
      fail('build.gradle.kts reads android/key.properties, but it is missing. Restore it (it points at the '
          'app\'s keystore) or the APK will not be able to update the installed app.');
    }
    return log('Signing: the project\'s own key (android/key.properties).');
  }

  final keystore = File(p.join(_keysDir, '$id.jks'));
  final saved = File(p.join(_keysDir, '$id.properties'));
  if (!keystore.existsSync()) {
    log('Creating a release key for $id...');
    keystore.parent.createSync(recursive: true);
    final password = _randomPassword();
    final result = await Process.run(_keytool, [
      '-genkeypair', '-noprompt', '-keystore', keystore.path, '-storetype', 'PKCS12', '-alias', 'upload',
      '-keyalg', 'RSA', '-keysize', '2048', '-validity', '10000', '-storepass', password, '-keypass', password,
      '-dname', 'CN=$id',
    ]);
    if (result.exitCode != 0) fail('keytool failed:\n${result.stdout}${result.stderr}');
    saved.writeAsStringSync('storePassword=$password\nkeyPassword=$password\nkeyAlias=upload\n'
        'storeFile=${keystore.path.replaceAll(r'\', '/')}\n');
    log('Release key saved in $_keysDir');
    log('BACK UP that folder (USB drive or password manager). Without it you cannot update $id later.');
  } else {
    log('Using the existing release key for $id from $_keysDir');
  }
  keyProperties.writeAsStringSync(saved.readAsStringSync());
  _ignoreKeyProperties(dir);
  gradle.writeAsStringSync(_addSigningBlock(text));
  log('Release signing added to android/app/build.gradle.kts.');
}

String get _keytool {
  final java = Platform.environment['JAVA_HOME'];
  final tool = java == null ? null : File(p.join(java, 'bin', Platform.isWindows ? 'keytool.exe' : 'keytool'));
  return tool != null && tool.existsSync() ? tool.path : 'keytool';
}

String _randomPassword() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
  final random = Random.secure();
  return List.generate(24, (_) => chars[random.nextInt(chars.length)]).join();
}

void _ignoreKeyProperties(String dir) {
  final ignore = File(p.join(dir, 'android', '.gitignore'));
  final text = ignore.existsSync() ? ignore.readAsStringSync() : '';
  if (!RegExp(r'^key\.properties$', multiLine: true).hasMatch(text)) {
    ignore.writeAsStringSync('$text\n# Release signing (pocketrun build apk); never commit it.\nkey.properties\n');
  }
}

String _addSigningBlock(String gradle) {
  final release = RegExp(r'    buildTypes \{\s*release \{[\s\S]*?signingConfig = signingConfigs\.getByName\("debug"\)\s*\}\s*\}');
  if (!release.hasMatch(gradle)) {
    fail('Could not find Flutter\'s default release block in build.gradle.kts to add signing. '
        'See https://docs.flutter.dev/deployment/android#configure-signing-in-gradle');
  }
  var out = gradle.replaceFirst(release, '''
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
            storePassword = keystoreProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            // Release key from android/key.properties (made by `pocketrun build apk`).
            signingConfig = signingConfigs.getByName("release")
        }
    }''');
  out = out.replaceFirst('\nandroid {', '''

// android/key.properties: storePassword, keyPassword, keyAlias, storeFile (git-ignored)
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) FileInputStream(file).use { load(it) }
}

android {''');
  return 'import java.io.FileInputStream\nimport java.util.Properties\n\n$out';
}

/// "CN=..." of the APK's signing certificate, via apksigner from the newest build-tools.
Future<String?> _signer(String apk) async {
  final tools = Directory(p.join(p.dirname(p.dirname(adbPath)), 'build-tools'));
  if (!tools.existsSync()) return null;
  final versions = tools.listSync().whereType<Directory>().map((d) => d.path).toList()..sort();
  for (final v in versions.reversed) {
    final apksigner = File(p.join(v, Platform.isWindows ? 'apksigner.bat' : 'apksigner'));
    if (!apksigner.existsSync()) continue;
    final out = (await Process.run(apksigner.path, ['verify', '--print-certs', apk], runInShell: true)).stdout as String;
    final dn = RegExp(r'certificate DN: (.+)').firstMatch(out)?.group(1)?.trim();
    if (dn != null && dn.contains('Android Debug')) {
      bad('Signed with the DEBUG key: fine for a test, but it cannot update a properly signed install.');
    }
    return dn;
  }
  return null;
}

Future<void> _install(Device device, String apk, String id) async {
  log('Installing on $device...');
  final result = await adb(['-s', device.id, 'install', '-r', apk]);
  final out = '${result.stdout}${result.stderr}';
  if (out.contains('Success')) {
    await adb(['-s', device.id, 'shell', 'monkey', '-p', id, '-c', 'android.intent.category.LAUNCHER', '1']);
    return log('Installed and opened $id.');
  }
  if (out.contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE')) {
    fail('The phone has a copy of $id signed with a different key, so this cannot update it.\n'
        'Uninstall it first (this deletes its data): adb -s ${device.id} uninstall $id');
  }
  if (out.contains('INSTALL_FAILED_VERSION_DOWNGRADE')) {
    fail('The phone has a newer version of $id. Raise the version: pocketrun build apk --bump');
  }
  if (out.contains('INSUFFICIENT_STORAGE')) fail('Not enough free space on $device.');
  fail('Install failed:\n$out');
}

// ---------------------------------------------------------------------------------------------
// Wi-Fi download: a one-file web server on this PC, behind a random path, shown as a QR code.

Future<void> _serve(File apk) async {
  final ip = await _lanAddress() ?? fail('No Wi-Fi/Ethernet address found on this PC.');
  final token = List.generate(4, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  final fileName = p.basename(apk.path);
  HttpServer server;
  try {
    server = await HttpServer.bind(InternetAddress.anyIPv4, 8790);
  } on SocketException {
    server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
  }
  final page = 'http://${ip.address}:${server.port}/$token/';

  stdout.writeln();
  _printQr(page);
  log('Scan this with the phone camera (same Wi-Fi), or open $page');
  log('Tap Download, open the file, and allow "Install unknown apps" for the browser if Android asks.');
  log('If Windows asks, allow PocketRun on private networks. Ctrl+C stops the download server.');

  await for (final request in server) {
    final path = request.uri.path;
    final response = request.response;
    if (path == '/$token/' || path == '/$token') {
      response.headers.contentType = ContentType.html;
      response.write('<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">'
          '<title>$fileName</title><body style="font-family:sans-serif;padding:24px;text-align:center">'
          '<h2>$fileName</h2><p>${(apk.lengthSync() / 1048576).toStringAsFixed(1)} MB</p>'
          '<p><a href="$fileName" style="display:inline-block;padding:16px 32px;background:#3949ab;color:#fff;'
          'border-radius:12px;text-decoration:none;font-size:20px">Download</a></p>'
          '<p>Then open the file and tap Install.</p></body>');
    } else if (path == '/$token/$fileName') {
      log('Download started by ${request.connectionInfo?.remoteAddress.address}');
      response.headers
        ..contentType = ContentType('application', 'vnd.android.package-archive')
        ..contentLength = apk.lengthSync()
        ..set('Content-Disposition', 'attachment; filename="$fileName"');
      await response.addStream(apk.openRead());
      log('Download finished.');
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }
}

/// This PC's address on the home network (skips Hyper-V, WSL, VPN and other virtual adapters).
Future<InternetAddress?> _lanAddress() async {
  final skip = RegExp(r'vEthernet|Virtual|VMware|VirtualBox|WSL|Hyper-V|Loopback|Tailscale|ZeroTier|VPN', caseSensitive: false);
  final candidates = [
    for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4))
      if (!skip.hasMatch(nic.name))
        for (final a in nic.addresses)
          if (!a.isLoopback && !a.isLinkLocal) a,
  ];
  bool private(InternetAddress a) =>
      a.address.startsWith('192.168.') || a.address.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(a.address);
  return candidates.where(private).firstOrNull ?? candidates.firstOrNull;
}

/// Draws [data] as a QR code with half-block characters, light modules as full blocks, for the
/// usual light-on-dark terminal.
void _printQr(String data) {
  final image = QrImage(QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.L));
  const quiet = 2;
  final size = image.moduleCount;
  bool dark(int row, int col) => row >= 0 && col >= 0 && row < size && col < size && image.isDark(row, col);
  final buffer = StringBuffer();
  for (var row = -quiet; row < size + quiet; row += 2) {
    buffer.write('  ');
    for (var col = -quiet; col < size + quiet; col++) {
      final top = dark(row, col);
      final bottom = dark(row + 1, col);
      buffer.write(switch ((top, bottom)) {
        (false, false) => '█',
        (false, true) => '▀',
        (true, false) => '▄',
        (true, true) => ' ',
      });
    }
    buffer.writeln();
  }
  stdout.write(buffer);
}
