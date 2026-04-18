import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/media_model.dart';
import '../services/tmdb_service.dart';
import '../services/stream_service.dart';
import '../screens/debrid_resolver_screen.dart';
import '../screens/player_screen.dart';

/// ── StreamBottomSheet ─────────────────────────────────────────────────────
///
/// Fetches torrent streams via Torrentio (StreamService), then shows a
/// selectable list. On selection:
///   • Debrid sources (infoHash present) → DebridResolverScreen
///   • Embed sources (isEmbed=true)      → PlayerScreen (WebView)
///
/// The old InFlexResolverService is fully removed here.

class StreamBottomSheet extends StatefulWidget {
  final MediaItem item;
  final String? imdbId;
  final int? season;
  final int? episode;

  const StreamBottomSheet({
    super.key,
    required this.item,
    this.imdbId,
    this.season,
    this.episode,
  });

  @override
  State<StreamBottomSheet> createState() => _StreamBottomSheetState();
}

class _StreamBottomSheetState extends State<StreamBottomSheet> {
  List<TorrentStream> _streams = [];
  bool _loading = true;
  String? _error;
  String? _imdbId;

  @override
  void initState() {
    super.initState();
    _fetchStreams();
  }

  Future<void> _fetchStreams() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Resolve IMDB ID
      String? imdbId = widget.imdbId;
      if (imdbId == null || imdbId.isEmpty) {
        imdbId = await TmdbService.getImdbId(
          widget.item.id,
          widget.item.mediaType,
        );
      }
      _imdbId = imdbId;
      debugPrint('[InFlex] IMDB: $imdbId | TMDB: ${widget.item.id}');

      if (imdbId == null || imdbId.isEmpty) {
        setState(() {
          _error = 'Could not find IMDB ID.\nTMDB ID: ${widget.item.id}';
          _loading = false;
        });
        return;
      }

      // Fetch streams — Torrentio + embed fallbacks (no old resolver)
      final streams = await StreamService.getAllStreams(
        tmdbId: widget.item.id,
        imdbId: imdbId,
        type: widget.item.mediaType,
        season: widget.season,
        episode: widget.episode,
      );

      setState(() {
        _streams = streams;
        _loading = false;
        if (streams.isEmpty) {
          _error =
              'No streams found for this title.\nIt may not be available yet.';
        }
      });
    } catch (e) {
      setState(() {
        _error = 'Error fetching streams: $e';
        _loading = false;
      });
    }
  }

  void _selectStream(TorrentStream stream) {
    Navigator.pop(context);

    if (stream.isEmbed) {
      // Embed / WebView player — no debrid involved
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            streamUrl: stream.streamUrl,
            title: widget.item.title,
            isEmbed: true,
          ),
        ),
      );
      return;
    }

    // Torrent source → Debrid flow
    // magnetLink is pre-built by StreamService
    final magnet = stream.magnetLink ??
        'magnet:?xt=urn:btih:${stream.infoHash}';

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DebridResolverScreen(
          imdbId: _imdbId ?? widget.item.id.toString(),
          magnetLink: magnet,
          movieTitle: widget.item.title,
          quality: stream.quality,
        ),
      ),
    );
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (_, controller) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0E0E16),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('SELECT SOURCE',
                            style: TextStyle(
                                color: Color(0xFFFFCC00),
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.5)),
                        SizedBox(height: 2),
                        Text('All sources via Torrentio',
                            style:
                                TextStyle(color: Colors.white38, fontSize: 12)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon:
                        const Icon(Icons.close, color: Colors.white54, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            // Body
            Expanded(child: _buildBody(controller)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ScrollController controller) {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
                color: Color(0xFFFFCC00), strokeWidth: 2.5),
            SizedBox(height: 12),
            Text('Fetching streams...',
                style: TextStyle(color: Colors.white38, fontSize: 13)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 36),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 20),
              TextButton(
                onPressed: _fetchStreams,
                child: const Text('Retry',
                    style: TextStyle(color: Color(0xFFFFCC00))),
              ),
            ],
          ),
        ),
      );
    }

    // Separate debrid and embed streams
    final debridStreams =
        _streams.where((s) => !s.isEmbed && s.infoHash.isNotEmpty).toList();
    final embedStreams = _streams.where((s) => s.isEmbed).toList();

    return ListView(
      controller: controller,
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (debridStreams.isNotEmpty) ...[
          _SectionHeader(
            icon: Icons.bolt_rounded,
            label: 'DEBRID SOURCES',
            color: const Color(0xFFFFCC00),
            subtitle: 'Cached on Telegram · Instant play',
          ),
          ...debridStreams.map((s) => _StreamTile(
                stream: s,
                onTap: () => _selectStream(s),
              )),
        ],
        if (embedStreams.isNotEmpty) ...[
          _SectionHeader(
            icon: Icons.language_rounded,
            label: 'EMBED SOURCES',
            color: Colors.white54,
            subtitle: 'Fallback · WebView player',
          ),
          ...embedStreams.map((s) => _StreamTile(
                stream: s,
                onTap: () => _selectStream(s),
              )),
        ],
      ],
    );
  }
}

// ── SUB WIDGETS ───────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final String subtitle;
  const _SectionHeader(
      {required this.icon,
      required this.label,
      required this.color,
      required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2)),
          const SizedBox(width: 8),
          Text(subtitle,
              style:
                  const TextStyle(color: Colors.white24, fontSize: 10)),
        ],
      ),
    );
  }
}

class _StreamTile extends StatelessWidget {
  final TorrentStream stream;
  final VoidCallback onTap;
  const _StreamTile({required this.stream, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final qualColor = StreamService.qualityColor(stream.quality);
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            // Quality badge
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Color(qualColor).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                stream.quality,
                style: TextStyle(
                    color: Color(qualColor),
                    fontSize: 11,
                    fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 12),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stream.title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (stream.size != null) ...[
                        const Icon(Icons.storage_rounded,
                            color: Colors.white30, size: 11),
                        const SizedBox(width: 3),
                        Text(stream.size!,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11)),
                        const SizedBox(width: 10),
                      ],
                      if (stream.seeds != null) ...[
                        const Icon(Icons.people_rounded,
                            color: Colors.white30, size: 11),
                        const SizedBox(width: 3),
                        Text('${stream.seeds} seeds',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            // Source tag
            Text(
              stream.isEmbed ? 'Embed' : 'Debrid',
              style: TextStyle(
                  color: stream.isEmbed
                      ? Colors.white24
                      : const Color(0xFFFFCC00).withValues(alpha: 0.8),
                  fontSize: 10,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.play_circle_outline_rounded,
                color: Colors.white24, size: 22),
          ],
        ),
      ),
    );
  }
}
