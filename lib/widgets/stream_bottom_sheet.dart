import 'package:flutter/material.dart';
import '../models/media_model.dart';
import '../services/tmdb_service.dart';
import '../services/torrentio_service.dart';
import '../screens/player_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _fetchStreams();
  }

  Future<void> _fetchStreams() async {
    try {
      // Get IMDB ID if not provided
      String? imdbId = widget.imdbId;
      if (imdbId == null || imdbId.isEmpty) {
        imdbId = await TmdbService.getImdbId(
            widget.item.id, widget.item.mediaType);
      }
      if (imdbId == null) {
        setState(() {
          _error = 'Could not find IMDB ID for this title.';
          _loading = false;
        });
        return;
      }

      final streams = await TorrentioService.getStreams(
        imdbId: imdbId,
        type: widget.item.mediaType,
        season: widget.season,
        episode: widget.episode,
      );

      final sorted = TorrentioService.sortByQuality(streams);
      setState(() {
        _streams = sorted;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load streams: $e';
        _loading = false;
      });
    }
  }

  void _playStream(TorrentStream stream) {
    Navigator.pop(context); // close sheet
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          streamUrl: stream.streamUrl,
          title: widget.item.title,
          subtitle: widget.episode != null
              ? 'S${widget.season}:E${widget.episode}'
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0E0E16),
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('SELECT SOURCE',
                        style: TextStyle(
                            color: Color(0xFFFFCC00),
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5)),
                    Text(
                      widget.item.title +
                          (widget.episode != null
                              ? ' • S${widget.season}E${widget.episode}'
                              : ''),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w800),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Content
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Column(
                children: [
                  CircularProgressIndicator(
                      color: Color(0xFFFFCC00), strokeWidth: 2),
                  SizedBox(height: 12),
                  Text('Fetching streams from Torrentio…',
                      style: TextStyle(color: Colors.white38, fontSize: 13)),
                ],
              ),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                children: [
                  const Icon(Icons.error_outline, color: Colors.redAccent, size: 36),
                  const SizedBox(height: 10),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 13)),
                ],
              ),
            )
          else if (_streams.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No streams found.\nThis title may not be available on Torrentio yet.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 13),
              ),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _streams.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final s = _streams[i];
                  return _StreamTile(
                    stream: s,
                    onTap: () => _playStream(s),
                  );
                },
              ),
            ),
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
    final qualColor = Color(TorrentioService.qualityColor(stream.quality));

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            // Magnet icon
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: qualColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.downloading_rounded, color: qualColor, size: 22),
            ),
            const SizedBox(width: 12),

            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stream.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                  if (stream.size != null)
                    Text('💾 ${stream.size}',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 10),

            // Quality badge
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: qualColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                stream.quality,
                style: TextStyle(
                    color: qualColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: Colors.white24, size: 20),
          ],
        ),
      ),
    );
  }
}
