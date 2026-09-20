import '../models/media_model.dart';
import 'app_settings.dart';

// ── MediaFilter ───────────────────────────────────────────────────────────────
//
// TMDB is user-edited, so search results and lists contain a lot of junk:
// placeholder entries with no poster, no release date ("0" as the year) and a
// 0.0 rating. They can't be streamed (no real release exists), they just
// clutter the grid with empty tiles.
//
// A title is hidden when ANY of these is true:
//   • no title, or the "Unknown" fallback
//   • no poster
//   • no release date
//   • rating is 0.0 -- UNLESS it is a genuinely new/upcoming release
//     (released in the last 90 days or due within a year) that has both a
//     poster and a synopsis: brand-new titles legitimately have no votes yet.
//
// It also removes exact duplicates (same type + TMDB id).
//
// Settings > Content > "Hide incomplete titles" turns the hiding off
// (duplicates are still removed).

class MediaFilter {
  MediaFilter._();

  static const int _freshDays = 90;
  static const int _upcomingDays = 365;

  /// Why [m] would be hidden, or null if it is fine to show.
  static String? rejectReason(MediaItem m, {DateTime? now}) {
    final title = m.title.trim();
    if (title.isEmpty || title == 'Unknown') return 'no title';

    final poster = m.posterPath;
    if (poster == null || poster.trim().isEmpty) return 'no poster';

    if (m.year == 0) return 'no release date';

    if (m.voteAverage <= 0) {
      final fresh = _isFreshOrUpcoming(m.releaseDate, now ?? DateTime.now());
      final hasSynopsis = (m.overview ?? '').trim().isNotEmpty;
      if (!(fresh && hasSynopsis)) return 'no rating';
    }
    return null;
  }

  /// Removes duplicates and (unless disabled in Settings) incomplete titles.
  static List<MediaItem> clean(List<MediaItem> items) {
    final hide = AppSettings.hideIncompleteTitles;
    final seen = <String>{};
    final out = <MediaItem>[];
    for (final m in items) {
      if (!seen.add('${m.mediaType}:${m.id}')) continue;
      if (hide && rejectReason(m) != null) continue;
      out.add(m);
    }
    return out;
  }

  static bool _isFreshOrUpcoming(String? releaseDate, DateTime now) {
    final d = DateTime.tryParse(releaseDate ?? '');
    if (d == null) return false;
    final daysFromNow = d.difference(now).inDays; // negative = in the past
    return daysFromNow >= -_freshDays && daysFromNow <= _upcomingDays;
  }
}
