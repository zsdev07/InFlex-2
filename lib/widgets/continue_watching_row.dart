import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants/app_constants.dart';
import '../services/watch_history.dart';

const Color _gold = Color(0xFFFFCC00);

class ContinueWatchingRow extends StatelessWidget {
  final List<WatchHistoryEntry> items;
  final ValueChanged<WatchHistoryEntry> onTap;
  final ValueChanged<WatchHistoryEntry> onRemove;

  const ContinueWatchingRow({
    super.key,
    required this.items,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 3,
                    height: 16,
                    decoration: BoxDecoration(
                      color: _gold,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Continue Watching',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(left: 11, top: 2),
                child: Text(
                  'RESUME FROM YOUR WATCH HISTORY',
                  style: TextStyle(
                      color: Colors.white30,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 236,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            itemCount: items.length,
            itemBuilder: (_, i) {
              final entry = items[i];
              return _ContinueCard(
                entry: entry,
                onTap: () => onTap(entry),
                onRemove: () => onRemove(entry),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ContinueCard extends StatelessWidget {
  final WatchHistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _ContinueCard({
    required this.entry,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final poster = entry.posterPath ?? entry.backdropPath;
    final episodeLabel = (entry.mediaType == 'tv' &&
            entry.season != null &&
            entry.episode != null)
        ? 'S${entry.season}:E${entry.episode}'
        : null;

    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: SizedBox(
        width: 150,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: onTap,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 150,
                  height: 200,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      poster != null
                          ? CachedNetworkImage(
                              imageUrl: AppConstants.poster(poster),
                              fit: BoxFit.cover,
                              placeholder: (_, __) =>
                                  Container(color: const Color(0xFF111118)),
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

                      // Darken bottom so the title/progress read clearly.
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black87],
                            stops: [0.55, 1.0],
                          ),
                        ),
                      ),

                      // Play button.
                      const Center(
                        child: Icon(Icons.play_circle_fill_rounded,
                            color: Colors.white, size: 44),
                      ),

                      if (episodeLabel != null)
                        Positioned(
                          left: 8,
                          bottom: 20,
                          right: 8,
                          child: Text(episodeLabel,
                              style: const TextStyle(
                                  color: _gold,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800)),
                        ),

                      // Progress bar.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: ClipRRect(
                          child: LinearProgressIndicator(
                            value: entry.progress,
                            minHeight: 3,
                            backgroundColor: Colors.white24,
                            valueColor:
                                const AlwaysStoppedAnimation<Color>(_gold),
                          ),
                        ),
                      ),

                      // Remove.
                      Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: onRemove,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close_rounded,
                                color: Colors.white70, size: 15),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              entry.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
