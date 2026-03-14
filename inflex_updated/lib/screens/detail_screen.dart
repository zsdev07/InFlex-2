import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../models/media_model.dart';
import '../services/tmdb_service.dart';
import '../constants/app_constants.dart';
import '../providers/watchlist_provider.dart';
import '../widgets/stream_bottom_sheet.dart';

class DetailScreen extends StatefulWidget {
  final MediaItem item;
  const DetailScreen({super.key, required this.item});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  MediaDetails? _details;
  int _selectedSeason = 1;
  List<Episode> _episodes = [];
  bool _episodesLoading = false;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    try {
      final d = await TmdbService.getDetails(widget.item.id, widget.item.mediaType);
      setState(() { _details = d; });
      if (widget.item.mediaType == 'tv') _loadEpisodes(1);
    } catch (e) {
      // details failed to load, show what we have
    }
  }

  Future<void> _loadEpisodes(int season) async {
    setState(() { _selectedSeason = season; _episodesLoading = true; });
    try {
      final eps = await TmdbService.getEpisodes(widget.item.id, season);
      setState(() { _episodes = eps; _episodesLoading = false; });
    } catch (_) {
      setState(() => _episodesLoading = false);
    }
  }

  void _openStreams({int? season, int? episode}) {
    final imdbId = _details?.imdbId;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StreamBottomSheet(
        item: widget.item,
        imdbId: imdbId,
        season: season,
        episode: episode,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final d = _details;
    final wl = context.watch<WatchlistProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFF050508),
      body: CustomScrollView(
        slivers: [
          // ── BACKDROP APPBAR ───────────────────────────────────
          SliverAppBar(
            expandedHeight: 260,
            pinned: true,
            backgroundColor: const Color(0xFF050508),
            leading: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(Icons.arrow_back, size: 20),
              ),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              IconButton(
                icon: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    wl.isInWatchlist(item.id)
                        ? Icons.bookmark
                        : Icons.bookmark_border,
                    color: wl.isInWatchlist(item.id)
                        ? const Color(0xFFFFCC00)
                        : Colors.white,
                    size: 20,
                  ),
                ),
                onPressed: () => wl.toggle(item),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (item.backdropPath != null)
                    CachedNetworkImage(
                      imageUrl: AppConstants.backdrop(item.backdropPath),
                      fit: BoxFit.cover,
                    )
                  else
                    Container(color: const Color(0xFF0E0E16)),
                  // Gradient overlay
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xFF050508)],
                        stops: [0.4, 1.0],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── CONTENT ───────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Poster + Info row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Poster
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          imageUrl: AppConstants.poster(item.posterPath),
                          width: 110,
                          height: 165,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => Container(
                            width: 110,
                            height: 165,
                            color: const Color(0xFF111118),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),

                      // Info
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                height: 1.15,
                              ),
                            ),
                            const SizedBox(height: 8),
                            // Meta row
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                _MetaBadge('⭐ ${item.ratingStr}',
                                    color: const Color(0xFFFFCC00)),
                                if (item.year > 0)
                                  _MetaBadge('${item.year}'),
                                if (d?.runtime != null)
                                  _MetaBadge('${d!.runtime}m'),
                                if (d?.numberOfSeasons != null)
                                  _MetaBadge(
                                      '${d!.numberOfSeasons} Seasons'),
                              ],
                            ),
                            const SizedBox(height: 10),
                            // Genres
                            if (d != null)
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: d.genres
                                    .take(3)
                                    .map((g) => _GenreChip(g.name))
                                    .toList(),
                              ),
                            const SizedBox(height: 14),
                            // PLAY BUTTON
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFFFCC00),
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  elevation: 8,
                                  shadowColor: const Color(0xFFFFCC00)
                                      .withValues(alpha: 0.4),
                                ),
                                icon: const Icon(Icons.play_arrow_rounded,
                                    size: 22),
                                label: const Text(
                                  'Stream Now',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 15,
                                  ),
                                ),
                                onPressed: () => _openStreams(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // Overview
                  if (item.overview != null && item.overview!.isNotEmpty) ...[
                    const Text('Overview',
                        style: TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1)),
                    const SizedBox(height: 6),
                    Text(
                      item.overview!,
                      style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 13,
                          height: 1.6),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // ── TV: Seasons + Episodes ─────────────────────
                  if (item.mediaType == 'tv' && d != null && d.seasons.isNotEmpty) ...[
                    const Text('EPISODES',
                        style: TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2)),
                    const SizedBox(height: 10),

                    // Season selector
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: d.seasons.map((s) {
                          final active = _selectedSeason == s.seasonNumber;
                          return GestureDetector(
                            onTap: () => _loadEpisodes(s.seasonNumber),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 6),
                              decoration: BoxDecoration(
                                color: active
                                    ? const Color(0xFFFFCC00).withValues(alpha: 0.15)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: active
                                      ? const Color(0xFFFFCC00)
                                      : Colors.white.withValues(alpha: 0.12),
                                ),
                              ),
                              child: Text(
                                'S${s.seasonNumber}',
                                style: TextStyle(
                                  color: active
                                      ? const Color(0xFFFFCC00)
                                      : Colors.white54,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Episodes list
                    if (_episodesLoading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(
                            child: CircularProgressIndicator(
                                color: Color(0xFFFFCC00), strokeWidth: 2)),
                      )
                    else
                      ...(_episodes.map((ep) => _EpisodeTile(
                            ep: ep,
                            onPlay: () => _openStreams(
                                season: _selectedSeason,
                                episode: ep.episodeNumber),
                          ))),
                    const SizedBox(height: 20),
                  ],

                  // ── CAST ──────────────────────────────────────
                  if (d != null && d.cast.isNotEmpty) ...[
                    const Text('CAST',
                        style: TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2)),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: d.cast.map((c) => _CastCard(c)).toList(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaBadge extends StatelessWidget {
  final String text;
  final Color? color;
  const _MetaBadge(this.text, {this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: (color ?? Colors.white).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color ?? Colors.white60,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _GenreChip extends StatelessWidget {
  final String name;
  const _GenreChip(this.name);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFFCC00).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFFFCC00).withValues(alpha: 0.3)),
      ),
      child: Text(
        name,
        style: const TextStyle(
          color: Color(0xFFFFCC00),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  final Episode ep;
  final VoidCallback onPlay;
  const _EpisodeTile({required this.ep, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0E0E16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFFFFCC00).withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(
                  color: const Color(0xFFFFCC00).withValues(alpha: 0.3)),
            ),
            child: Center(
              child: Text(
                '${ep.episodeNumber}',
                style: const TextStyle(
                  color: Color(0xFFFFCC00),
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ep.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
                if (ep.overview != null && ep.overview!.isNotEmpty)
                  Text(ep.overview!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11)),
              ],
            ),
          ),
          IconButton(
            onPressed: onPlay,
            icon: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFFFFCC00).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.play_arrow_rounded,
                  color: Color(0xFFFFCC00), size: 18),
            ),
          ),
        ],
      ),
    );
  }
}

class _CastCard extends StatelessWidget {
  final CastMember cast;
  const _CastCard(this.cast);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 12),
      width: 64,
      child: Column(
        children: [
          ClipOval(
            child: cast.profilePath != null
                ? CachedNetworkImage(
                    imageUrl:
                        'https://image.tmdb.org/t/p/w185${cast.profilePath}',
                    width: 52,
                    height: 52,
                    fit: BoxFit.cover,
                  )
                : Container(
                    width: 52,
                    height: 52,
                    color: const Color(0xFF111118),
                    child: const Icon(Icons.person, color: Colors.white24),
                  ),
          ),
          const SizedBox(height: 5),
          Text(
            cast.name,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
