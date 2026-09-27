import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

// ── WatchHistory ──────────────────────────────────────────────────────────────
//
// "Resume where you left off": one Hive entry per TITLE (movie or series,
// keyed by TMDB id + media type). For a series the entry always holds the
// LATEST episode watched, so Continue Watching shows one card per show, the
// way it does everywhere else.
//
// Nothing here talks to the network or to InTorrent - it only remembers a
// position in time. Whoever plays the title again (any source) is expected
// to seek to it; see WatchTarget below and how torrent_player_screen.dart
// uses it.

/// Which title/episode a player session belongs to, for saving progress.
/// Built once by whatever opens the player (stream_bottom_sheet.dart) and
/// carried through TorrentLoadingScreen -> TorrentPlayerScreen unchanged.
class WatchTarget {
  final int tmdbId;
  final String mediaType; // 'movie' or 'tv'
  final String title;
  final String? posterPath;
  final String? backdropPath;
  final int? season;
  final int? episode;

  const WatchTarget({
    required this.tmdbId,
    required this.mediaType,
    required this.title,
    this.posterPath,
    this.backdropPath,
    this.season,
    this.episode,
  });
}

class WatchHistoryEntry {
  final int tmdbId;
  final String mediaType;
  final String title;
  final String? posterPath;
  final String? backdropPath;
  final int? season;
  final int? episode;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;

  const WatchHistoryEntry({
    required this.tmdbId,
    required this.mediaType,
    required this.title,
    this.posterPath,
    this.backdropPath,
    this.season,
    this.episode,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });

  /// 0.0-1.0 (0 when the duration isn't known yet).
  double get progress => duration.inMilliseconds > 0
      ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
      : 0.0;

  Map<String, dynamic> _toMap() => {
        'tmdbId': tmdbId,
        'mediaType': mediaType,
        'title': title,
        'posterPath': posterPath,
        'backdropPath': backdropPath,
        'season': season,
        'episode': episode,
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'updatedAtMs': updatedAt.millisecondsSinceEpoch,
      };

  static WatchHistoryEntry? _fromMap(Map<dynamic, dynamic> m) {
    final tmdbId = m['tmdbId'] as int?;
    final mediaType = m['mediaType'] as String?;
    final title = m['title'] as String?;
    if (tmdbId == null || mediaType == null || title == null) return null;
    return WatchHistoryEntry(
      tmdbId: tmdbId,
      mediaType: mediaType,
      title: title,
      posterPath: m['posterPath'] as String?,
      backdropPath: m['backdropPath'] as String?,
      season: m['season'] as int?,
      episode: m['episode'] as int?,
      position: Duration(milliseconds: (m['positionMs'] as int?) ?? 0),
      duration: Duration(milliseconds: (m['durationMs'] as int?) ?? 0),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
          (m['updatedAtMs'] as int?) ?? 0),
    );
  }
}

class WatchHistory {
  WatchHistory._();

  static const String boxName = 'watch_history';

  /// Don't bother remembering the first bit of a title (barely started) or
  /// the last bit (credits) - it isn't worth a "Continue Watching" card.
  static const Duration _minPosition = Duration(seconds: 20);
  static const Duration _finishWithin = Duration(seconds: 45);

  static const int _maxEntries = 25;

  static Box<dynamic>? get _box =>
      Hive.isBoxOpen(boxName) ? Hive.box<dynamic>(boxName) : null;

  static String _key(int tmdbId, String mediaType) => '$mediaType:$tmdbId';

  /// Records progress for [target]. Clears the entry instead of saving it
  /// when the title has barely started or is basically finished, so
  /// Continue Watching never shows a title with nothing left to resume.
  static Future<void> save(
    WatchTarget target, {
    required Duration position,
    required Duration duration,
  }) async {
    final box = _box;
    if (box == null) return;
    final key = _key(target.tmdbId, target.mediaType);

    final nearEnd = duration > Duration.zero &&
        duration - position <= _finishWithin;
    if (position < _minPosition || nearEnd) {
      await box.delete(key);
      return;
    }

    final entry = WatchHistoryEntry(
      tmdbId: target.tmdbId,
      mediaType: target.mediaType,
      title: target.title,
      posterPath: target.posterPath,
      backdropPath: target.backdropPath,
      season: target.season,
      episode: target.episode,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    await box.put(key, entry._toMap());

    // Keep the box small: drop the oldest entries past _maxEntries.
    if (box.length > _maxEntries) {
      final all = list();
      for (final old in all.skip(_maxEntries)) {
        await box.delete(_key(old.tmdbId, old.mediaType));
      }
    }
  }

  /// The saved resume point for a title, or for one specific episode of a
  /// series when [season]/[episode] are given and match what's stored.
  static WatchHistoryEntry? get(
    int tmdbId,
    String mediaType, {
    int? season,
    int? episode,
  }) {
    final raw = _box?.get(_key(tmdbId, mediaType));
    if (raw is! Map) return null;
    final entry = WatchHistoryEntry._fromMap(raw);
    if (entry == null) return null;
    if (season != null && episode != null) {
      if (entry.season != season || entry.episode != episode) return null;
    }
    return entry;
  }

  /// All entries, most recently watched first.
  static List<WatchHistoryEntry> list() {
    final box = _box;
    if (box == null) return const [];
    final out = <WatchHistoryEntry>[];
    for (final raw in box.values) {
      if (raw is Map) {
        final e = WatchHistoryEntry._fromMap(raw);
        if (e != null) out.add(e);
      }
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  static Future<void> remove(int tmdbId, String mediaType) async {
    try {
      await _box?.delete(_key(tmdbId, mediaType));
    } catch (e) {
      debugPrint('[WatchHistory] remove failed: $e');
    }
  }
}
