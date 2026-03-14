import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/tmdb_provider.dart';
import '../models/media_model.dart';
import '../widgets/hero_banner.dart';
import '../widgets/media_row.dart';
import '../widgets/search_bar_widget.dart';
import 'detail_screen.dart';
import 'watchlist_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0; // 0=Home, 1=Movies, 2=Shows, 3=Watchlist
  bool _searching = false;
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _openDetail(MediaItem item) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => DetailScreen(item: item),
        transitionDuration: const Duration(milliseconds: 350),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.04),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TmdbProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFF050508),
      body: SafeArea(
        child: Column(
          children: [
            // ── TOP BAR ──────────────────────────────────────────
            _buildTopBar(provider),

            // ── CONTENT ──────────────────────────────────────────
            Expanded(
              child: _searching
                  ? _buildSearchResults(provider)
                  : _buildMainContent(provider),
            ),

            // ── BOTTOM NAV ────────────────────────────────────────
            _buildBottomNav(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(TmdbProvider provider) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF050508), Color(0x00050508)],
        ),
      ),
      child: Row(
        children: [
          // Logo
          if (!_searching) ...[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFFCC00), Color(0xFFFFD740)],
                ),
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFFCC00).withValues(alpha: 0.3),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: const Center(
                child: Text('IF',
                    style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w900,
                        fontSize: 15)),
              ),
            ),
            const SizedBox(width: 10),
            RichText(
              text: const TextSpan(children: [
                TextSpan(
                    text: 'In',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5)),
                TextSpan(
                    text: 'Flex',
                    style: TextStyle(
                        color: Color(0xFFFFCC00),
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5)),
              ]),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.search, color: Colors.white70),
              onPressed: () => setState(() => _searching = true),
            ),
          ] else ...[
            Expanded(
              child: SearchBarWidget(
                controller: _searchCtrl,
                onChanged: (q) => provider.search(q),
                onClose: () {
                  setState(() => _searching = false);
                  _searchCtrl.clear();
                  provider.clearSearch();
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSearchResults(TmdbProvider provider) {
    if (provider.searchLoading) {
      return const Center(
        child: CircularProgressIndicator(
          color: Color(0xFFFFCC00),
          strokeWidth: 2,
        ),
      );
    }
    if (_searchCtrl.text.isEmpty) {
      return const Center(
        child: Text('Search for movies, shows…',
            style: TextStyle(color: Colors.white38)),
      );
    }
    if (provider.searchResults.isEmpty) {
      return const Center(
        child: Text('No results found',
            style: TextStyle(color: Colors.white38)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.58,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: provider.searchResults.length,
      itemBuilder: (_, i) {
        final item = provider.searchResults[i];
        return _SearchCard(item: item, onTap: () => _openDetail(item));
      },
    );
  }

  Widget _buildMainContent(TmdbProvider provider) {
    if (provider.loading) {
      return const Center(
        child: CircularProgressIndicator(
          color: Color(0xFFFFCC00),
          strokeWidth: 2,
        ),
      );
    }

    if (_tab == 3) return const WatchlistScreen();

    final rows = _getRows(provider);

    return RefreshIndicator(
      color: const Color(0xFFFFCC00),
      backgroundColor: const Color(0xFF0E0E16),
      onRefresh: () => provider.loadHome(),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          // Hero banner
          if (_tab == 0 && provider.trending.isNotEmpty)
            HeroBanner(
              items: provider.trending.take(5).toList(),
              onTap: _openDetail,
            ),

          // Tab chips
          _buildTabChips(),

          // Content rows
          ...rows.map((row) => MediaRow(
                title: row.$1,
                items: row.$2,
                onTap: _openDetail,
                accent: row.$3,
              )),
        ],
      ),
    );
  }

  List<(String, List<MediaItem>, Color)> _getRows(TmdbProvider p) {
    switch (_tab) {
      case 0:
        return [
          ('🔥 Trending in India', p.trending, const Color(0xFFFFCC00)),
          ('🎬 Hindi Movies', p.hindiMovies, const Color(0xFFf59e0b)),
          ('📺 Hindi Web Series', p.hindiShows, const Color(0xFF3b82f6)),
          ('🆕 New Bollywood 2025', p.newBollywood, const Color(0xFF22c55e)),
          ('🎭 South Dubbed', p.southDubbed, const Color(0xFFe11d48)),
          ('🌍 Hollywood Hindi Dubbed', p.hindiDubbedHollywood, const Color(0xFF8b5cf6)),
          ('🎨 Animated Hindi Dubbed', p.hindiDubbedAnimated, const Color(0xFFec4899)),
        ];
      case 1:
        return [
          ('🎬 Hindi Movies', p.hindiMovies, const Color(0xFFFFCC00)),
          ('🆕 New Bollywood 2025', p.newBollywood, const Color(0xFF22c55e)),
          ('🎭 South Dubbed', p.southDubbed, const Color(0xFFe11d48)),
          ('🌍 Hollywood Hindi Dubbed', p.hindiDubbedHollywood, const Color(0xFF8b5cf6)),
          ('🎨 Animated Hindi Dubbed', p.hindiDubbedAnimated, const Color(0xFFec4899)),
        ];
      case 2:
        return [
          ('📺 Hindi Web Series', p.hindiShows, const Color(0xFFFFCC00)),
        ];
      default:
        return [];
    }
  }

  Widget _buildTabChips() {
    final tabs = ['Home', 'Movies', 'Shows'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: List.generate(3, (i) {
          final active = _tab == i;
          return GestureDetector(
            onTap: () => setState(() => _tab = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: active
                    ? const Color(0xFFFFCC00)
                    : const Color(0xFF111118),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: active
                      ? const Color(0xFFFFCC00)
                      : Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Text(
                tabs[i],
                style: TextStyle(
                  color: active ? Colors.black : Colors.white60,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildBottomNav() {
    final items = [
      (Icons.home_rounded, 'Home'),
      (Icons.movie_rounded, 'Movies'),
      (Icons.tv_rounded, 'Shows'),
      (Icons.bookmark_rounded, 'Watchlist'),
    ];
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0F),
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.05))),
      ),
      child: Row(
        children: List.generate(items.length, (i) {
          final active = _tab == i;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _tab = i),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      items[i].$1,
                      color: active
                          ? const Color(0xFFFFCC00)
                          : Colors.white30,
                      size: 22,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      items[i].$2,
                      style: TextStyle(
                        color: active
                            ? const Color(0xFFFFCC00)
                            : Colors.white30,
                        fontSize: 10,
                        fontWeight:
                            active ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _SearchCard extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;
  const _SearchCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: item.posterPath != null
                  ? Image.network(
                      'https://image.tmdb.org/t/p/w342${item.posterPath}',
                      fit: BoxFit.cover,
                      width: double.infinity,
                    )
                  : Container(
                      color: const Color(0xFF111118),
                      child: const Icon(Icons.movie, color: Colors.white24),
                    ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          Text(
            '${item.year}',
            style: const TextStyle(fontSize: 10, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}
