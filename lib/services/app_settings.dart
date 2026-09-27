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

  /// Hide TMDB entries with no poster / no release date / 0.0 rating (see
  /// MediaFilter). ON by default.
  static const String keyHideIncompleteTitles = 'hide_incomplete_titles';

  /// The mandatory first-launch flow (screens/onboarding_screen.dart) has
  /// been completed. Checked by splash_screen.dart on every cold start.
  static const String keyOnboardingComplete = 'onboarding_complete';

  /// Preferred audio/content language, an [LanguageOption.code] from
  /// onboarding_catalog.dart (e.g. 'hi'). Drives the "For You" row and is a
  /// tie-breaker in the source picker.
  static const String keyPreferredLanguage = 'preferred_language';

  /// Exactly [kOnboardingTagCount] TMDB genre ids the person picked at
  /// onboarding, stored as a comma-separated string (Hive on this project
  /// stores plain values, so a List<int> round-trips as a List<dynamic> --
  /// a String is simpler to read back reliably).
  static const String keyPreferredTags = 'preferred_tags';

  /// Preferred playback quality, one of [kOnboardingQualities] (e.g.
  /// '1080p'). The source picker sorts/badges this quality first.
  static const String keyPreferredQuality = 'preferred_quality';

  static Box<dynamic>? get _box =>
      Hive.isBoxOpen(boxName) ? Hive.box<dynamic>(boxName) : null;

  static bool get smartPreBuffer =>
      (_box?.get(keySmartPreBuffer, defaultValue: false) as bool?) ?? false;

  static Future<void> setSmartPreBuffer(bool value) async {
    await _box?.put(keySmartPreBuffer, value);
  }

  static bool get hideIncompleteTitles =>
      (_box?.get(keyHideIncompleteTitles, defaultValue: true) as bool?) ?? true;

  static Future<void> setHideIncompleteTitles(bool value) async {
    await _box?.put(keyHideIncompleteTitles, value);
  }

  static bool get onboardingComplete =>
      (_box?.get(keyOnboardingComplete, defaultValue: false) as bool?) ?? false;

  static String? get preferredLanguage =>
      (_box?.get(keyPreferredLanguage) as String?)?.trim().isEmpty ?? true
          ? null
          : _box?.get(keyPreferredLanguage) as String?;

  static List<int> get preferredTagIds {
    final raw = _box?.get(keyPreferredTags) as String?;
    if (raw == null || raw.trim().isEmpty) return const [];
    return raw
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toList();
  }

  static String? get preferredQuality =>
      (_box?.get(keyPreferredQuality) as String?)?.trim().isEmpty ?? true
          ? null
          : _box?.get(keyPreferredQuality) as String?;

  /// Saves the whole onboarding result in one write and marks it complete.
  static Future<void> completeOnboarding({
    required String language,
    required List<int> tagIds,
    required String quality,
  }) async {
    final box = _box;
    if (box == null) return;
    await box.putAll({
      keyPreferredLanguage: language,
      keyPreferredTags: tagIds.join(','),
      keyPreferredQuality: quality,
      keyOnboardingComplete: true,
    });
  }
}
