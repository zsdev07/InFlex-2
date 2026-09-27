import 'package:flutter/material.dart';
import '../models/media_model.dart';
import '../services/tmdb_service.dart';

class TmdbProvider extends ChangeNotifier {
  List<MediaItem> trending = [];
  List<MediaItem> hindiMovies = [];
  List<MediaItem> hindiShows = [];
  List<MediaItem> newBollywood = [];
  List<MediaItem> southDubbed = [];
  List<MediaItem> hindiDubbedHollywood = [];
  List<MediaItem> hindiDubbedAnimated = [];
  List<MediaItem> searchResults = [];

  /// "Recommended for you" (onboarding language + tags). Empty until
  /// onboarding has set a language - see TmdbService.getForYou.
  List<MediaItem> forYou = [];

  /// Watch-provider rows ("Popular · Movie Channels"), keyed by TMDB
  /// provider id (see TmdbService.providerChannels).
  Map<int, List<MediaItem>> channels = {};

  bool loading = false;
  bool searchLoading = false;
  String? error;

  Future<void> loadHome() async {
    loading = true;
    error = null;
    notifyListeners();

    // Load one by one so a single failure doesn't kill everything
    try { trending = await TmdbService.getTrending(); } 
    catch (e) { debugPrint('trending error: $e'); }

    try { hindiMovies = await TmdbService.getHindiMovies(); } 
    catch (e) { debugPrint('hindiMovies error: $e'); }

    try { hindiShows = await TmdbService.getHindiShows(); } 
    catch (e) { debugPrint('hindiShows error: $e'); }

    try { newBollywood = await TmdbService.getNewBollywood(); } 
    catch (e) { debugPrint('newBollywood error: $e'); }

    try { southDubbed = await TmdbService.getSouthDubbed(); } 
    catch (e) { debugPrint('southDubbed error: $e'); }

    try { hindiDubbedHollywood = await TmdbService.getHindiDubbedHollywood(); } 
    catch (e) { debugPrint('hollywood error: $e'); }

    try { hindiDubbedAnimated = await TmdbService.getHindiDubbedAnimated(); } 
    catch (e) { debugPrint('animated error: $e'); }

    try { forYou = await TmdbService.getForYou(); }
    catch (e) { debugPrint('forYou error: $e'); }

    // Channel rows in parallel - one slow/failing provider shouldn't hold
    // up the others.
    await Future.wait(TmdbService.providerChannels.map((c) async {
      final (_, id) = c;
      try {
        channels[id] = await TmdbService.getProviderMovies(id);
      } catch (e) {
        debugPrint('channel $id error: $e');
      }
    }));

    debugPrint('=== TMDB LOAD COMPLETE ===');
    debugPrint('trending: ${trending.length}');
    debugPrint('hindiMovies: ${hindiMovies.length}');
    debugPrint('hindiShows: ${hindiShows.length}');
    debugPrint('newBollywood: ${newBollywood.length}');
    debugPrint('southDubbed: ${southDubbed.length}');
    debugPrint('hollywood: ${hindiDubbedHollywood.length}');
    debugPrint('animated: ${hindiDubbedAnimated.length}');
    debugPrint('forYou: ${forYou.length}');
    debugPrint('channels: ${channels.map((k, v) => MapEntry(k, v.length))}');

    if (trending.isEmpty && hindiMovies.isEmpty) {
      error = 'Could not load content. Check internet connection.';
    }

    loading = false;
    notifyListeners();
  }

  Future<void> search(String query) async {
    if (query.trim().isEmpty) {
      searchResults = [];
      notifyListeners();
      return;
    }
    searchLoading = true;
    notifyListeners();
    try {
      searchResults = await TmdbService.search(query);
    } catch (e) {
      debugPrint('search error: $e');
      searchResults = [];
    }
    searchLoading = false;
    notifyListeners();
  }

  void clearSearch() {
    searchResults = [];
    notifyListeners();
  }
}
