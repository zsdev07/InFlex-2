class MediaItem {
  final int id;
  final String title;
  final String? posterPath;
  final String? backdropPath;
  final String? overview;
  final double voteAverage;
  final String? releaseDate;
  final String mediaType; // 'movie' or 'tv'
  final String? originalLanguage;

  MediaItem({
    required this.id,
    required this.title,
    this.posterPath,
    this.backdropPath,
    this.overview,
    this.voteAverage = 0,
    this.releaseDate,
    required this.mediaType,
    this.originalLanguage,
  });

  factory MediaItem.fromJson(Map<String, dynamic> json, {String type = 'movie'}) {
    final isMovie = json.containsKey('title');
    return MediaItem(
      id: json['id'],
      title: json['title'] ?? json['name'] ?? 'Unknown',
      posterPath: json['poster_path'],
      backdropPath: json['backdrop_path'],
      overview: json['overview'],
      voteAverage: (json['vote_average'] ?? 0).toDouble(),
      releaseDate: json['release_date'] ?? json['first_air_date'],
      mediaType: json['media_type'] ?? (isMovie ? 'movie' : 'tv'),
      originalLanguage: json['original_language'],
    );
  }

  int get year {
    if (releaseDate == null || releaseDate!.isEmpty) return 0;
    return int.tryParse(releaseDate!.split('-')[0]) ?? 0;
  }

  String get ratingStr => voteAverage.toStringAsFixed(1);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'poster_path': posterPath,
        'backdrop_path': backdropPath,
        'overview': overview,
        'vote_average': voteAverage,
        'release_date': releaseDate,
        'media_type': mediaType,
        'original_language': originalLanguage,
      };
}

class MediaDetails extends MediaItem {
  final List<Genre> genres;
  final int? runtime;
  final int? numberOfSeasons;
  final String? imdbId;
  final List<CastMember> cast;
  final List<Season> seasons;

  MediaDetails({
    required super.id,
    required super.title,
    super.posterPath,
    super.backdropPath,
    super.overview,
    super.voteAverage,
    super.releaseDate,
    required super.mediaType,
    super.originalLanguage,
    this.genres = const [],
    this.runtime,
    this.numberOfSeasons,
    this.imdbId,
    this.cast = const [],
    this.seasons = const [],
  });

  factory MediaDetails.fromJson(Map<String, dynamic> json, String type) {
    final base = MediaItem.fromJson(json, type: type);
    final externalIds = json['external_ids'] as Map<String, dynamic>?;
    final credits = json['credits'] as Map<String, dynamic>?;
    final castList = (credits?['cast'] as List<dynamic>?)
            ?.map((c) => CastMember.fromJson(c))
            .toList() ??
        [];
    final seasonsList = (json['seasons'] as List<dynamic>?)
            ?.map((s) => Season.fromJson(s))
            .where((s) => s.seasonNumber > 0)
            .toList() ??
        [];

    return MediaDetails(
      id: base.id,
      title: base.title,
      posterPath: base.posterPath,
      backdropPath: base.backdropPath,
      overview: base.overview,
      voteAverage: base.voteAverage,
      releaseDate: base.releaseDate,
      mediaType: type,
      originalLanguage: base.originalLanguage,
      genres: (json['genres'] as List<dynamic>?)
              ?.map((g) => Genre.fromJson(g))
              .toList() ??
          [],
      runtime: json['runtime'],
      numberOfSeasons: json['number_of_seasons'],
      imdbId: externalIds?['imdb_id'],
      cast: castList.take(15).toList(),
      seasons: seasonsList,
    );
  }
}

class Genre {
  final int id;
  final String name;
  Genre({required this.id, required this.name});
  factory Genre.fromJson(Map<String, dynamic> j) =>
      Genre(id: j['id'], name: j['name']);
}

class CastMember {
  final int id;
  final String name;
  final String? profilePath;
  final String? character;
  CastMember({required this.id, required this.name, this.profilePath, this.character});
  factory CastMember.fromJson(Map<String, dynamic> j) => CastMember(
        id: j['id'],
        name: j['name'] ?? '',
        profilePath: j['profile_path'],
        character: j['character'],
      );
}

class Season {
  final int seasonNumber;
  final String name;
  final int episodeCount;
  final String? posterPath;
  Season({required this.seasonNumber, required this.name, required this.episodeCount, this.posterPath});
  factory Season.fromJson(Map<String, dynamic> j) => Season(
        seasonNumber: j['season_number'] ?? 0,
        name: j['name'] ?? 'Season',
        episodeCount: j['episode_count'] ?? 0,
        posterPath: j['poster_path'],
      );
}

class Episode {
  final int id;
  final int episodeNumber;
  final String name;
  final String? overview;
  final String? stillPath;
  final double voteAverage;
  Episode({required this.id, required this.episodeNumber, required this.name, this.overview, this.stillPath, this.voteAverage = 0});
  factory Episode.fromJson(Map<String, dynamic> j) => Episode(
        id: j['id'],
        episodeNumber: j['episode_number'] ?? 0,
        name: j['name'] ?? '',
        overview: j['overview'],
        stillPath: j['still_path'],
        voteAverage: (j['vote_average'] ?? 0).toDouble(),
      );
}

class TorrentStream {
  final String title;
  final String infoHash;
  final int? fileIdx;
  final String quality;
  final String? size;
  final String streamUrl;
  final String source;
  final bool isEmbed;

  TorrentStream({
    required this.title,
    required this.infoHash,
    this.fileIdx,
    required this.quality,
    this.size,
    required this.streamUrl,
    this.source = 'Unknown',
    this.isEmbed = false,
  });
}
