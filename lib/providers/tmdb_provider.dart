import 'package:flutter/material.dart';
import '../models/media_model.dart';
import '../services/tmdb_service.dart';

class TmdbProvider extends ChangeNotifier {
  List<MediaItem> trending = [];
  List<MediaItem> hindiMovies = [];
  List<MediaItem> hindiShows = [];
  List<MediaItem> newBollywood = [];
  List<MediaItem> southDubbed = [];
  List<MediaItem> searchResults = [];

  bool loading = false;
  bool searchLoading = false;
  String? error;

  Future<void> loadHome() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        TmdbService.getTrending(),
        TmdbService.getHindiMovies(),
        TmdbService.getHindiShows(),
        TmdbService.getNewBollywood(),
        TmdbService.getSouthDubbed(),
      ]);
      trending = results[0];
      hindiMovies = results[1];
      hindiShows = results[2];
      newBollywood = results[3];
      southDubbed = results[4];
    } catch (e) {
      error = e.toString();
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
