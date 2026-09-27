import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../constants/app_constants.dart';
import '../models/media_model.dart';
import 'media_filter.dart';
import 'app_settings.dart';

class TmdbService {
  static final _client = http.Client();
  static const _base = AppConstants.tmdbBase;

  static const _headers = {
    'Authorization': 'Bearer ${AppConstants.tmdbReadToken}',
    'accept': 'application/json',
  };

  static Future<Map<String, dynamic>> _get(String path,
      [Map<String, String>? params]) async {
    final uri = Uri.parse('$_base$path').replace(queryParameters: {
      'language': 'en-US',
      ...?params,
    });
    final res = await _client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 200) return jsonDecode(res.body);
    throw Exception('TMDB error ${res.statusCode}: $path');
  }

  static Future<List<MediaItem>> getTrending() async {
    final data = await _get('/trending/all/week', {'region': 'IN'});
    return MediaFilter.clean((data['results'] as List)
        .where((j) => j['media_type'] == 'movie' || j['media_type'] == 'tv')
        .map((j) => MediaItem.fromJson(j))
        .toList());
  }

  static Future<List<MediaItem>> getHindiMovies({int page = 1}) async {
    final data = await _get('/discover/movie', {
      'with_original_language': 'hi',
      'sort_by': 'popularity.desc',
      'page': '$page',
    });
    return MediaFilter.clean((data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList());
  }

  static Future<List<MediaItem>> getHindiShows({int page = 1}) async {
    final data = await _get('/discover/tv', {
      'with_original_language': 'hi',
      'sort_by': 'popularity.desc',
      'page': '$page',
    });
    return MediaFilter.clean((data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'tv'))
        .toList());
  }

  static Future<List<MediaItem>> getNewBollywood() async {
    final data = await _get('/discover/movie', {
      'with_original_language': 'hi',
      'sort_by': 'release_date.desc',
      'primary_release_year': '2025',
    });
    return MediaFilter.clean((data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList());
  }

  static Future<List<MediaItem>> getSouthDubbed() async {
    final data = await _get('/discover/movie', {
      'with_original_language': 'te,ta,ml,kn',
      'sort_by': 'popularity.desc',
    });
    return MediaFilter.clean((data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList());
  }

  static Future<List<MediaItem>> getHindiDubbedHollywood() async {
    final data = await _get('/discover/movie', {
      'sort_by': 'popularity.desc',
      'with_original_language': 'en',
      'region': 'IN',
      'vote_count.gte': '500',
    });
    return MediaFilter.clean((data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList());
  }

  static Future<List<MediaItem>> getHindiDubbedAnimated() async {
    final data = await _get('/discover/movie', {
      'with_genres': '16',
      'sort_by': 'popularity.desc',
      'vote_count.gte': '200',
    });
    return MediaFilter.clean((data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList());
  }

  // ── Watch-provider rows ("Popular · Movie Channels") ────────────────────────
  //
  // TMDB ids for the streaming services a title is available on. Verify
  // these against a live TMDB response if a channel's row looks wrong -
  // provider ids can differ by region and I could not call the API from
  // where this was written.
  static const int providerNetflix = 8;
  static const int providerPrimeVideo = 119;
  static const int providerDisneyPlus = 337;
  static const int providerAppleTv = 350;

  /// (name, TMDB provider id) - the channels shown on the home screen, in
  /// order. Capped at 4 by whoever renders them.
  static const List<(String, int)> providerChannels = [
    ('Netflix', providerNetflix),
    ('Prime Video', providerPrimeVideo),
    ('Disney+', providerDisneyPlus),
    ('Apple TV+', providerAppleTv),
  ];

  /// Movies available on watch-provider [providerId] (see [providerChannels]),
  /// for the given TMDB [region] (ISO 3166-1, e.g. 'IN', 'US').
  static Future<List<MediaItem>> getProviderMovies(
    int providerId, {
    String region = 'IN',
    int page = 1,
  }) async {
    final data = await _get('/discover/movie', {
      'with_watch_providers': '$providerId',
      'watch_region': region,
      'sort_by': 'popularity.desc',
      'page': '$page',
    });
    return MediaFilter.clean((data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList());
  }

  /// "Recommended for you", from the language + tags chosen at onboarding.
  /// Returns an empty list until onboarding has actually set a language.
  static Future<List<MediaItem>> getForYou() async {
    final language = AppSettings.preferredLanguage;
    if (language == null) return const [];
    final tagIds = AppSettings.preferredTagIds;

    final params = <String, String>{
      'with_original_language': language,
      'sort_by': 'popularity.desc',
      'vote_count.gte': '20',
    };
    // Comma = OR in TMDB's query syntax: any of the chosen genres match.
    if (tagIds.isNotEmpty) params['with_genres'] = tagIds.join(',');

    final data = await _get('/discover/movie', params);
    return MediaFilter.clean((data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList());
  }

  static Future<List<MediaItem>> search(String query) async {
    final data = await _get('/search/multi', {'query': query});
    return MediaFilter.clean((data['results'] as List)
        .where((j) => ['movie', 'tv'].contains(j['media_type']))
        .map((j) => MediaItem.fromJson(j))
        .toList());
  }

  static Future<MediaDetails> getDetails(int id, String type) async {
    final data = await _get('/$type/$id', {
      'append_to_response': 'credits,external_ids,seasons',
    });
    return MediaDetails.fromJson(data, type);
  }

  static Future<List<Episode>> getEpisodes(int tvId, int season) async {
    final data = await _get('/tv/$tvId/season/$season');
    return (data['episodes'] as List)
        .map((e) => Episode.fromJson(e))
        .toList();
  }

  // CRITICAL: No language param — external_ids doesn't need it
  static Future<String?> getImdbId(int tmdbId, String type) async {
    try {
      final uri = Uri.parse('$_base/$type/$tmdbId/external_ids');
      final res = await _client
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final imdbId = data['imdb_id'];
        debugPrint('[InFlex] IMDB ID for $tmdbId: $imdbId');
        return imdbId;
      }
      return null;
    } catch (e) {
      debugPrint('[InFlex] getImdbId error: $e');
      return null;
    }
  }
}
