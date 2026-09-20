import 'package:hive/hive.dart';

// ── AppSettings ───────────────────────────────────────────────────────────────
//
// Tiny persistent settings store on top of the Hive box 'settings' that
// main.dart already opens at startup. Every getter falls back to its default
// if the box could not be opened, so settings can never crash the app.
//
// Screens that need to react to changes can listen to the box:
//   Hive.box('settings').listenable(keys: [AppSettings.keySmartPreBuffer])
// (needs package:hive_flutter).

class AppSettings {
  AppSettings._();

  static const String boxName = 'settings';

  /// EXPERIMENTAL. When on, the player waits until the start of the movie is
  /// fully buffered (no fixed timer) and only gives up when the source stops
  /// loading. Off by default: it can mean a longer wait on weak sources.
  static const String keySmartPreBuffer = 'smart_pre_buffer';

  static Box<dynamic>? get _box =>
      Hive.isBoxOpen(boxName) ? Hive.box<dynamic>(boxName) : null;

  static bool get smartPreBuffer =>
      (_box?.get(keySmartPreBuffer, defaultValue: false) as bool?) ?? false;

  static Future<void> setSmartPreBuffer(bool value) async {
    await _box?.put(keySmartPreBuffer, value);
  }
}
