import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/app_constants.dart';
import '../models/media_model.dart';

class TmdbService {
  static final _client = http.Client();
  static const _base = AppConstants.tmdbBase;
  static const _key = AppConstants.tmdbKey;

  static Future<Map<String, dynamic>> _get(String path,
      [Map<String, String>? params]) async {
    final uri = Uri.parse('$_base$path').replace(queryParameters: {
      'api_key': _key,
      'language': 'en-IN',
      ...?params,
    });
    final res = await _client.get(uri);
    if (res.statusCode == 200) return jsonDecode(res.body);
    throw Exception('TMDB error ${res.statusCode}: $path');
  }

  // ── Trending ──────────────────────────────────────────────────────────────
  static Future<List<MediaItem>> getTrending({String time = 'week'}) async {
    final data = await _get('/trending/all/$time');
    return (data['results'] as List)
        .map((j) => MediaItem.fromJson(j))
        .toList();
  }

  // ── Hindi Movies ──────────────────────────────────────────────────────────
  static Future<List<MediaItem>> getHindiMovies({int page = 1}) async {
    final data = await _get('/discover/movie', {
      'with_original_language': 'hi',
      'sort_by': 'popularity.desc',
      'region': 'IN',
      'page': '$page',
    });
    return (data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList();
  }

  // ── Hindi Shows ───────────────────────────────────────────────────────────
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

  // ── New Bollywood ─────────────────────────────────────────────────────────
  static Future<List<MediaItem>> getNewBollywood() async {
    final data = await _get('/discover/movie', {
      'with_original_language': 'hi',
      'sort_by': 'release_date.desc',
      'region': 'IN',
      'primary_release_year': '2024',
    });
    return (data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList();
  }

  // ── South Hindi Dubbed ────────────────────────────────────────────────────
  static Future<List<MediaItem>> getSouthDubbed() async {
    final data = await _get('/discover/movie', {
      'with_original_language': 'te|ta|ml|kn',
      'sort_by': 'popularity.desc',
      'with_release_type': '3|2',
      'region': 'IN',
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
