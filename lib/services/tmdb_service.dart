import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/app_constants.dart';
import '../models/media_model.dart';

class TmdbService {
  static final _client = http.Client();
  static const _base = AppConstants.tmdbBase;

  // Use Bearer token instead of api_key param — more reliable + higher rate limits
  static const _headers = {
    'Authorization': 'Bearer ${AppConstants.tmdbReadToken}',
    'accept': 'application/json',
  };

  static Future<Map<String, dynamic>> _get(String path,
      [Map<String, String>? params]) async {
    final uri = Uri.parse('$_base$path').replace(queryParameters: {
      'language': 'hi-IN', // Hindi language for dubbed titles
      ...?params,
    });
    final res = await _client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 200) return jsonDecode(res.body);
    throw Exception('TMDB error ${res.statusCode}: $path');
  }

  // ── Trending in India ─────────────────────────────────────────────────────
  static Future<List<MediaItem>> getTrending({String time = 'week'}) async {
    final data = await _get('/trending/all/$time', {'region': 'IN'});
    return (data['results'] as List)
        .map((j) => MediaItem.fromJson(j))
        .toList();
  }

  // ── Hindi Original Movies ─────────────────────────────────────────────────
  static Future<List<MediaItem>> getHindiMovies({int page = 1}) async {
    final data = await _get('/discover/movie', {
      'with_original_language': 'hi',
      'sort_by': 'popularity.desc',
      'page': '$page',
    });
    return (data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList();
  }

  // ── Hindi Original Shows ──────────────────────────────────────────────────
  static Future<List<MediaItem>> getHindiShows({int page = 1}) async {
    final data = await _get('/discover/tv', {
      'with_original_language': 'hi',
      'sort_by': 'popularity.desc',
      'page': '$page',
    });
    return (data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'tv'))
        .toList();
  }

  // ── New Bollywood 2025 ────────────────────────────────────────────────────
  static Future<List<MediaItem>> getNewBollywood() async {
    final data = await _get('/discover/movie', {
      'with_original_language': 'hi',
      'sort_by': 'release_date.desc',
      'primary_release_year': '2025',
    });
    return (data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList();
  }

  // ── Hindi Dubbed Hollywood ────────────────────────────────────────────────
  // These are English/other movies that are popular in India with Hindi dub
  static Future<List<MediaItem>> getHindiDubbedHollywood() async {
    final data = await _get('/discover/movie', {
      'sort_by': 'popularity.desc',
      'with_original_language': 'en',
      'region': 'IN',
      'with_release_type': '3|2',
      'vote_count.gte': '500', // Only well-known movies
    });
    return (data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList();
  }

  // ── South Hindi Dubbed ────────────────────────────────────────────────────
  // Telugu, Tamil, Malayalam, Kannada — all dubbed in Hindi
  static Future<List<MediaItem>> getSouthDubbed() async {
    final data = await _get('/discover/movie', {
      'with_original_language': 'te,ta,ml,kn',
      'sort_by': 'popularity.desc',
    });
    return (data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList();
  }

  // ── Hindi Dubbed Animated (Kung Fu Panda etc) ─────────────────────────────
  static Future<List<MediaItem>> getHindiDubbedAnimated() async {
    final data = await _get('/discover/movie', {
      'with_genres': '16', // Animation genre ID
      'sort_by': 'popularity.desc',
      'vote_count.gte': '200',
    });
    return (data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList();
  }

  // ── Search ────────────────────────────────────────────────────────────────
  static Future<List<MediaItem>> search(String query) async {
    final data = await _get('/search/multi', {'query': query});
    return (data['results'] as List)
        .where((j) => ['movie', 'tv'].contains(j['media_type']))
        .map((j) => MediaItem.fromJson(j))
        .toList();
  }

  // ── Details ───────────────────────────────────────────────────────────────
  static Future<MediaDetails> getDetails(int id, String type) async {
    final data = await _get('/$type/$id', {
      'append_to_response': 'credits,external_ids,seasons',
    });
    return MediaDetails.fromJson(data, type);
  }

  // ── Season Episodes ───────────────────────────────────────────────────────
  static Future<List<Episode>> getEpisodes(int tvId, int season) async {
    final data = await _get('/tv/$tvId/season/$season');
    return (data['episodes'] as List)
        .map((e) => Episode.fromJson(e))
        .toList();
  }

  // ── IMDB ID ───────────────────────────────────────────────────────────────
  static Future<String?> getImdbId(int tmdbId, String type) async {
    try {
      final data = await _get('/$type/$tmdbId/external_ids');
      return data['imdb_id'];
    } catch (_) {
      return null;
    }
  }
}
