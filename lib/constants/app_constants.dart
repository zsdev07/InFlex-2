class AppConstants {
  // TMDB
  static const String tmdbKey = '0e477a8908e5042e73a8db7f8cf3892d';
  static const String tmdbReadToken = 'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiIwZTQ3N2E4OTA4ZTUwNDJlNzNhOGRiN2Y4Y2YzODkyZCIsIm5iZiI6MTc3MzA2MzU1Mi40MDIsInN1YiI6IjY5YWVjZDgwZTE5ZjY1MWY3Y2MxY2I2ZCIsInNjb3BlcyI6WyJhcGlfcmVhZCJdLCJ2ZXJzaW9uIjoxfQ.vR9dMon_AwZ8EhBpBFdVqVYe3NxmAdStZaO5O7G_74I';
  static const String tmdbBase = 'https://api.themoviedb.org/3';
  static const String imgBase = 'https://image.tmdb.org/t/p';

  // Stream Sources
  static const String torrentioBase = 'https://torrentio.strem.fun';
  static const String torrentioFilter = 'sort=qualitysize|qualityfilter=480p,scr,cam';

  // Embed Sources (fallback scrapers)
  static const String vidsrcBase = 'https://vidsrc.to';
  static const String embedsuBase = 'https://embed.su';
  static const String autoembedBase = 'https://autoembed.cc';
  static const String twoEmbedBase = 'https://www.2embed.cc';

  // Image sizes
  static String poster(String? path, {String size = 'w342'}) =>
      path != null ? '$imgBase/$size$path' : '';
  static String backdrop(String? path) =>
      path != null ? '$imgBase/original$path' : '';
  static String posterSmall(String? path) =>
      path != null ? '$imgBase/w185$path' : '';

  // Colors
  static const goldColor = 0xFFFFCC00;
  static const bgColor = 0xFF050508;
  static const cardColor = 0xFF0E0E16;
  static const surfaceColor = 0xFF111118;
}
