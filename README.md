# PocketRun

Your own "Expo Go" for Flutter: install PocketRun on the phone once, then run Flutter projects
from the PC inside it with hot reload, without installing each project.

| Folder | What |
|---|---|
| `app/` | The PocketRun Android app: a debug-mode Flutter app holding the native plugins (the SDK) |
| `cli/` | The `pocketrun` command (Dart); compiled to `bin/pocketrun.exe`, which is on the user PATH |
| `sdk/` | `catalog.json` (plugins offered, Flutter version, build), `projects.json` (registered projects), `starter/` (preloaded plugins) |
| `templates/app/` | Files `pocketrun new` puts in a new project |
| `examples/hello_pocketrun/` | Demo: live camera preview + text-to-speech |

## Everyday use

```sh
pocketrun pair 192.168.40.25:37145 123456   # once per phone (Wireless debugging > Pair device with pairing code)
pocketrun install                           # put the latest PocketRun on the phone
cd my_project
pocketrun doctor                            # can it run? what is missing?
pocketrun start                             # run it; saving a .dart file hot-reloads (~1 s)
```

Keys in `start`: `r` reload, `R` restart, `q` quit. `-d <device>` picks a device; by default a real
phone wins over the emulator. `pocketrun help` lists every command.

New projects: `pocketrun new my_app --org com.yourname`, then `pocketrun add camera` (adds the exact
version inside PocketRun). Each new project gets `AGENTS.md` (+ `CLAUDE.md`, `.cursor/rules/`) telling
Cursor or Claude which plugins exist; `pocketrun rules` rewrites it after the SDK changes.

## Installing a finished app (release APK)

When a project is ready, build a real app that runs without the PC or PocketRun:

```sh
cd my_app
pocketrun build apk --app-id com.yourname.myapp   # first time: sets the app id for good
pocketrun build apk --bump                         # later releases: raise the build number, update the phone
pocketrun build apk --qr                           # no adb: download it over Wi-Fi by scanning a QR code
```

- **Signing:** the first build of an app id creates its release key in `~/.pocketrun/keys`
  (`<app id>.jks` + `<app id>.properties`), outside the project so it never gets committed. The project
  gets a git-ignored `android/key.properties` and Flutter's standard signing block in
  `android/app/build.gradle.kts`. **Back up `~/.pocketrun/keys`**: without the key, an installed app can
  never be updated. Projects that already sign with their own `key.properties` (like NavRoute) keep it.
- **Install:** with a phone connected over adb the APK is installed and opened. Without one (or with
  `--qr`) the PC serves it on the home network behind a random URL and prints a QR code; the phone's
  browser downloads it (allow "Install unknown apps" once). Windows may ask to allow PocketRun on
  private networks.
- **Output:** `build/pocketrun/<name>-<version>.apk`.
- **Android developer verification:** installs over adb are not affected. Since 2026-09-30, opening an
  unregistered APK file is restricted on certified phones in Brazil, Indonesia, Singapore and Thailand;
  Google plans that worldwide in 2027 (free "limited distribution" accounts allow up to 20 devices).

## How it works

PocketRun is a debug build, so its Dart VM accepts new code. `pocketrun start` runs
`flutter attach --machine` against PocketRun's VM service, hot-restarts into the project's code,
then hot-reloads every time a `.dart` file under `lib/` is saved. The engine is cached for the whole
process, so the project survives Back and the camera or file-picker round trip.

Only Dart code is live. Native parts must already be inside PocketRun, at the exact versions:

- **Plugins:** generated block in `app/pubspec.yaml`, pinning the Android implementation packages
  (e.g. `geolocator_android 5.2.1`) of every registered project. A plugin can be in PocketRun at one
  version only; `sdk sync` refuses conflicts unless `--force`.
- **Permissions and `<queries>`:** merged into `app/android/app/src/main/AndroidManifest.xml`
  (conflicting `maxSdkVersion`s resolved with `tools:replace`).
- **minSdk:** raised to the highest a project needs.
- **Custom channels** (a project's own Kotlin): ported by hand into
  `app/android/app/src/main/kotlin/.../extensions/` (NavRoute's `navroute/intents`). `doctor` lists them.
- **Flutter version:** the PC's must match the one PocketRun was built with (`pocketrun sdk build` after upgrading).

Changing any of these: `pocketrun sdk sync` (in the project) or `pocketrun sdk add <pkg>` (preload),
which rebuild and install PocketRun. `sdk add` resolves new plugins around the versions already
pinned, so it never moves a version another project relies on.

Flutter writes the Dart plugin registrant only while it hot-restarts, and a session started without
it never registers Dart-side plugins (MissingPluginException). When a project's plugins changed,
`start` does one preparation attach + restart, then restarts PocketRun and attaches for real.

## SDK (build 4)

NavRoute's plugins plus preloaded: camera, video_player, just_audio, audioplayers, webview_flutter,
flutter_local_notifications, connectivity_plus, device_info_plus, sensors_plus,
flutter_secure_storage, mobile_scanner, wakelock_plus, flutter_tts, speech_to_text. Exact versions:
`sdk/catalog.json`. Not preloaded: local_auth (needs a FlutterFragmentActivity), Google Maps (API key).

## Supported projects

| Project | Status |
|---|---|
| NavRoute 1.4.0+10 | Every feature passes (Phase 2, emulator); `doctor` all green on build 4 |
| hello_pocketrun | Camera preview and text-to-speech work on first `start`; release APK `dev.pocketrun.hello` installs, runs and updates (`--bump`) on the emulator |

### NavRoute checklist (Phase 2, Pixel 9 Pro XL emulator, 2026-10-27)

| Feature | Uses | Result |
|---|---|---|
| Import CSV (picker, column match, 4 rows, 2 cities) | file_picker, sqflite | Pass |
| Find missing locations | geocoding | Pass (3 found) |
| Location permission + "Nearest first" distances | permission_handler, geolocator | Pass |
| City map + main map, clustering, GPS dot | flutter_map (OSM tiles) | Pass |
| Navigate hand-off to Google Maps | url_launcher | Pass |
| Offline-maps detection | `navroute/intents` channel | Pass |
| Proof photo from gallery and camera | image_picker | Pass (survives camera round trip) |
| Export .xlsx to Documents/NavRoute/Exports | path_provider, excel | Pass |
| Share export | share_plus | Pass |
| Create backup / restore backup | path_provider, sqflite | Pass |
| Settings saved across a full PocketRun restart | shared_preferences | Pass |
| Search, Optimize, Route Mode, History, Visit Log | Dart only | Pass |

PocketRun runs in debug mode, so it shows Flutter assertion errors that release builds hide,
the same as `flutter run`. Found one in NavRoute itself: the odometer dialog in
`route_mode_screen.dart` disposes its `TextEditingController` while the dialog is still closing
(red screen when starting or ending Route Mode; the route still starts).

Data NavRoute saves inside PocketRun lives in PocketRun's storage, separate from the installed
NavRoute app. Files it writes to shared folders (Documents/NavRoute) are real files on the device.

## License

MIT - see [LICENSE](LICENSE).
