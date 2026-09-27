import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants/app_constants.dart';
import '../models/media_model.dart';
import '../services/tmdb_service.dart';
import '../screens/provider_screen.dart';

const Color _gold = Color(0xFFFFCC00);

/// Brand colour + short badge text per channel. No trademarked logo assets
/// are bundled - the badge is plain styled text, the same way the rest of
/// the app avoids shipping third-party artwork.
const Map<String, (Color, String)> _channelBrand = {
  'Netflix': (Color(0xFFE50914), 'NETFLIX'),
  'Prime Video': (Color(0xFF00A8E1), 'prime video'),
  'Disney+': (Color(0xFF113CCF), 'Disney+'),
  'Apple TV+': (Color(0xFFA2AAAD), 'tv+'),
};

class ChannelRow extends StatelessWidget {
  /// TMDB provider id -> its movies (TmdbProvider.channels). Rows with no
  /// movies yet (still loading, or the lookup failed) are skipped.
  final Map<int, List<MediaItem>> channels;

  const ChannelRow({super.key, required this.channels});

  @override
  Widget build(BuildContext context) {
    final entries = TmdbService.providerChannels
        .where((c) => (channels[c.$2]?.isNotEmpty ?? false))
        .take(4)
        .toList();
    if (entries.isEmpty) return const SizedBox.shrink();

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
                  const Text('Popular',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w800)),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(left: 11, top: 2),
                child: Text('MOVIE CHANNELS',
                    style: TextStyle(
                        color: Colors.white30,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6)),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.85,
            ),
            itemCount: entries.length,
            itemBuilder: (_, i) {
              final (name, id) = entries[i];
              return _ChannelCard(
                name: name,
                posters: channels[id]!
                    .map((m) => m.posterPath)
                    .whereType<String>()
                    .take(4)
                    .toList(),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        ProviderScreen(providerId: id, providerName: name),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ChannelCard extends StatelessWidget {
  final String name;
  final List<String> posters;
  final VoidCallback onTap;

  const _ChannelCard({
    required this.name,
    required this.posters,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final brand = _channelBrand[name] ?? (_gold, name.toUpperCase());
    final (color, badge) = brand;

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: const Color(0xFF111118)),
            // Poster collage, faded so the badge stays readable.
            if (posters.isNotEmpty)
              Opacity(
                opacity: 0.5,
                child: Row(
                  children: [
                    for (final p in posters)
                      Expanded(
                        child: CachedNetworkImage(
                          imageUrl: AppConstants.posterSmall(p),
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => const SizedBox(),
                        ),
                      ),
                  ],
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Colors.black.withValues(alpha: 0.85),
                    Colors.black.withValues(alpha: 0.15),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 10,
              top: 10,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.4),
                ),
              ),
            ),
            Positioned(
              left: 11,
              bottom: 8,
              right: 8,
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(blurRadius: 4, color: Colors.black)]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
