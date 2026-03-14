import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import '../models/media_model.dart';

class WatchlistProvider extends ChangeNotifier {
  final _box = Hive.box('watchlist');

  List<MediaItem> get items {
    return _box.values
        .map((v) => MediaItem.fromJson(jsonDecode(v)))
        .toList()
        .cast<MediaItem>();
  }

  bool isInWatchlist(int id) => _box.containsKey(id.toString());

  void toggle(MediaItem item) {
    final key = item.id.toString();
    if (_box.containsKey(key)) {
      _box.delete(key);
    } else {
      _box.put(key, jsonEncode(item.toJson()));
    }
    notifyListeners();
  }
}
