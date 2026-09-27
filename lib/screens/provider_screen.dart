import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants/app_constants.dart';
import '../models/media_model.dart';
import '../services/tmdb_service.dart';
import 'detail_screen.dart';

const Color _gold = Color(0xFFFFCC00);

/// Full-screen grid for one watch-provider channel (Netflix, Prime Video,
/// ...), opened by tapping a channel card on the home screen.
class ProviderScreen extends StatefulWidget {
  final int providerId;
  final String providerName;

  const ProviderScreen({
    super.key,
    required this.providerId,
    required this.providerName,
  });

  @override
  State<ProviderScreen> createState() => _ProviderScreenState();
}

class _ProviderScreenState extends State<ProviderScreen> {
  final List<MediaItem> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _page = 1;
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
    _scrollCtrl.addListener(() {
      if (_hasMore &&
          !_loadingMore &&
          _scrollCtrl.position.pixels >
              _scrollCtrl.position.maxScrollExtent - 400) {
        _load();
      }
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      if (_page == 1) _loading = true;
      _loadingMore = true;
    });
    try {
      final page =
          await TmdbService.getProviderMovies(widget.providerId, page: _page);
      if (!mounted) return;
      setState(() {
        _items.addAll(page);
        _hasMore = page.isNotEmpty;
        _page++;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (_items.isEmpty) _error = 'Could not load $e';
      });
    }
  }

  void _openDetail(MediaItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailScreen(item: item)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050508),
      appBar: AppBar(
        backgroundColor: const Color(0xFF050508),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(widget.providerName,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: _gold, strokeWidth: 2))
          : _error != null
              ? Center(
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.white38)))
              : GridView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.58,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 14,
                  ),
                  itemCount: _items.length,
                  itemBuilder: (_, i) {
                    final item = _items[i];
                    return GestureDetector(
                      onTap: () => _openDetail(item),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: item.posterPath != null
                                  ? CachedNetworkImage(
                                      imageUrl:
                                          AppConstants.poster(item.posterPath),
                                      fit: BoxFit.cover,
                                      width: double.infinity,
                                      errorWidget: (_, __, ___) => Container(
                                        color: const Color(0xFF111118),
                                        child: const Icon(Icons.movie,
                                            color: Colors.white24),
                                      ),
                                    )
                                  : Container(
                                      color: const Color(0xFF111118),
                                      child: const Icon(Icons.movie,
                                          color: Colors.white24),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white)),
                          Text('${item.year}',
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.white38)),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
