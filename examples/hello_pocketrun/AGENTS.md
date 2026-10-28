# Notes for AI assistants

This app is tested in **PocketRun**: a pre-installed Android app that runs this project's Dart code
from the PC with hot reload (`pocketrun start`). PocketRun can only run native (Android) code it
already contains, so follow these rules.

## Rules

1. **Flutter 3.41.9**, Android only. Do not upgrade Flutter or the Dart SDK constraint.
2. **Plugins (packages with Android code): only the ones below, at exactly these versions.**
   Add them with `pocketrun add <package>`, never `flutter pub add`. If a feature truly needs a plugin
   that is not listed, say so and ask first; adding it needs `pocketrun sdk sync`, which rebuilds PocketRun.
3. **Pure-Dart packages are fine** (state management, http, json, intl, maps drawn in Dart, ...).
4. **No new native code**: do not edit `android/app/src/main/kotlin` or `MainActivity`, and do not add
   `MethodChannel`s of your own. Android permissions go in `android/app/src/main/AndroidManifest.xml`.
5. Release APKs come from `flutter build apk --release` (Phase 5: `pocketrun build apk`).

## Plugins inside PocketRun (build 4)

| Package | Version |
|---|---|
| `audioplayers` | `6.7.1` |
| `camera` | `0.12.0+2` |
| `connectivity_plus` | `7.3.1` |
| `device_info_plus` | `13.3.0` |
| `file_picker` | `13.1.0` |
| `flutter_local_notifications` | `22.3.3` |
| `flutter_secure_storage` | `11.2.0` |
| `flutter_tts` | `4.2.5` |
| `geocoding` | `5.0.0` |
| `geolocator` | `14.1.2` |
| `image_picker` | `1.2.4` |
| `just_audio` | `0.10.6` |
| `mobile_scanner` | `7.4.2` |
| `path_provider` | `2.1.6` |
| `permission_handler` | `12.0.1` |
| `sensors_plus` | `7.1.1` |
| `share_plus` | `13.3.1` |
| `shared_preferences` | `2.5.6` |
| `speech_to_text` | `7.4.0` |
| `sqflite` | `2.4.2+1` |
| `url_launcher` | `6.3.3` |
| `video_player` | `2.11.1` |
| `wakelock_plus` | `1.7.0` |
| `webview_flutter` | `4.14.1` |

Check the project any time with `pocketrun doctor`.
