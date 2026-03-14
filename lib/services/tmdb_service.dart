import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../constants/app_constants.dart';
import '../models/media_model.dart';

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
    return (data['results'] as List)
        .map((j) => MediaItem.fromJson(j))
        .toList();
  }

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

  static Future<List<MediaItem>> getSouthDubbed() async {
    final data = await _get('/discover/movie', {
      'with_original_language': 'te,ta,ml,kn',
      'sort_by': 'popularity.desc',
    });
    return (data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList();
  }

  static Future<List<MediaItem>> getHindiDubbedHollywood() async {
    final data = await _get('/discover/movie', {
      'sort_by': 'popularity.desc',
      'with_original_language': 'en',
      'region': 'IN',
      'vote_count.gte': '500',
    });
    return (data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList();
  }

  static Future<List<MediaItem>> getHindiDubbedAnimated() async {
    final data = await _get('/discover/movie', {
      'with_genres': '16',
      'sort_by': 'popularity.desc',
      'vote_count.gte': '200',
    });
    return (data['results'] as List)
        .map((j) => MediaItem.fromJson(j, type: 'movie'))
        .toList();
  }

  static Future<List<MediaItem>> search(String query) async {
    final data = await _get('/search/multi', {'query': query});
    return (data['results'] as List)
        .where((j) => ['movie', 'tv'].contains(j['media_type']))
        .map((j) => MediaItem.fromJson(j))
        .toList();
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
