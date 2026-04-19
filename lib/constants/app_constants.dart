class AppConstants {
  // ── TMDB ───────────────────────────────────────────────────────────────────
  static const String tmdbKey = '0e477a8908e5042e73a8db7f8cf3892d';
  static const String tmdbReadToken =
      'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiIwZTQ3N2E4OTA4ZTUwNDJlNzNhOGRiN2Y4Y2YzODkyZCIsIm5iZiI6MTc3MzA2MzU1Mi40MDIsInN1YiI6IjY5YWVjZDgwZTE5ZjY1MWY3Y2MxY2I2ZCIsInNjb3BlcyI6WyJhcGlfcmVhZCJdLCJ2ZXJzaW9uIjoxfQ.vR9dMon_AwZ8EhBpBFdVqVYe3NxmAdStZaO5O7G_74I';
  static const String tmdbBase = 'https://api.themoviedb.org/3';
  static const String imgBase = 'https://image.tmdb.org/t/p';

  // ── STREAM SOURCES ─────────────────────────────────────────────────────────
  static const String torrentioBase = 'https://torrentio.strem.fun';
  static const String torrentioFilter =
      'sort=qualitysize|qualityfilter=480p,scr,cam';

  // Embed fallbacks (WebView player only)
  static const String vidsrcBase = 'https://vidsrc.to';

  // ── INFLEX DEBRID BACKEND (Render) ─────────────────────────────────────────
  // Replace with your actual Render deployment URL.
  // UptimeRobot should ping /health every 5 minutes to keep it warm.
  static const String debridBackendBase =
      'https://inflexbackend.onrender.com';

  // ── TELEGRAM FILESTREAM PROXY ──────────────────────────────────────────────
  // Self-hosted TG-FileStreamBot. Converts file_id → seekable HTTP stream.
  // https://github.com/EverythingSuckz/TG-FileStreamBot
  static const String fileStreamBase = 'https://tgfilestream-pv4w.onrender.com/';

  // ── DEBRID BOT (fps.ms) ────────────────────────────────────────────────────
  // The Python bot runs at banana.fps.ms:10352.
  // The Render backend communicates with it directly — the app never calls it.
  // Documented here for reference only.
  // Leech bot — communicates via Render backend only, app never calls it directly.
  static const String debridBotBase = 'https://a20656-8b7d.h.jrnm.app';
  // ── IMAGE HELPERS ──────────────────────────────────────────────────────────
  static String poster(String? path, {String size = 'w342'}) =>
      path != null ? '$imgBase/$size$path' : '';
  static String backdrop(String? path) =>
      path != null ? '$imgBase/original$path' : '';
  static String posterSmall(String? path) =>
      path != null ? '$imgBase/w185$path' : '';

  // ── COLORS ─────────────────────────────────────────────────────────────────
  static const goldColor = 0xFFFFCC00;
  static const bgColor = 0xFF050508;
  static const cardColor = 0xFF0E0E16;
  static const surfaceColor = 0xFF111118;
}
