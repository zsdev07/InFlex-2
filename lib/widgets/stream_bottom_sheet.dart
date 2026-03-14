import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/media_model.dart';
import '../services/tmdb_service.dart';
import '../services/inflex_resolver_service.dart';
import '../screens/resolver_screen.dart';

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
    setState(() { _loading = true; _error = null; });

    try {
      // Get IMDB ID
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
          _error = 'Could not find IMDB ID for this title.\nTMDB ID: ${widget.item.id}';
          _loading = false;
        });
        return;
      }

      // Get streams from InFlex Resolver (filtered Torrentio)
      final streams = await InFlexResolverService.getStreams(
        imdbId: imdbId,
        type: widget.item.mediaType,
        season: widget.season,
        episode: widget.episode,
      );

      setState(() {
        _streams = streams;
        _loading = false;
        if (streams.isEmpty) {
          _error = 'No streams found for this title.\nIt may not be available yet.';
        }
      });
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _loading = false;
      });
    }
  }

  void _selectStream(TorrentStream stream) {
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ResolverScreen(
          infoHash: stream.infoHash,
          fileIdx: stream.fileIdx ?? 0,
          movieTitle: widget.item.title,
          quality: stream.quality,
          imdbId: _imdbId ?? widget.item.id.toString(),
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
            width: 40, height: 4,
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
                    const Text('SELECT QUALITY',
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
                    if (_imdbId != null)
                      Text('IMDB: $_imdbId',
                          style: const TextStyle(
                              color: Colors.white24, fontSize: 10)),
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

          // InFlex resolver badge
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFCC00).withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: const Color(0xFFFFCC00).withValues(alpha: 0.15)),
            ),
            child: const Row(
              children: [
                Icon(Icons.rocket_launch_rounded,
                    color: Color(0xFFFFCC00), size: 16),
                SizedBox(width: 8),
                Text(
                  'Powered by InFlex Resolver — cached streams play instantly ⚡',
                  style: TextStyle(
                      color: Color(0xFFFFCC00),
                      fontSize: 11,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Content
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Column(
                children: [
                  CircularProgressIndicator(
                      color: Color(0xFFFFCC00), strokeWidth: 2),
                  SizedBox(height: 12),
                  Text('Finding best streams…',
                      style: TextStyle(color: Colors.white38, fontSize: 13)),
                ],
              ),
            )
          else if (_streams.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Column(
                children: [
                  const Icon(Icons.search_off_rounded,
                      color: Colors.white24, size: 40),
                  const SizedBox(height: 12),
                  Text(
                    _error ?? 'No streams found.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFCC00),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                    onPressed: _fetchStreams,
                  ),
                ],
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
                itemBuilder: (_, i) => _StreamTile(
                  stream: _streams[i],
                  onTap: () => _selectStream(_streams[i]),
                ),
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
    final is1080 = stream.quality.contains('1080');
    final qualColor = is1080
        ? const Color(0xFF3b82f6)
        : const Color(0xFF22c55e);

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
            // Icon
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: qualColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.play_circle_filled_rounded,
                  color: qualColor, size: 26),
            ),
            const SizedBox(width: 12),

            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stream.title.isNotEmpty ? stream.title : stream.quality,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                  Row(
                    children: [
                      const Text('🧲 Torrent  ',
                          style: TextStyle(
                              color: Colors.white38, fontSize: 11)),
                      if (stream.size != null)
                        Text('💾 ${stream.size}  ',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11)),
                      if ((stream.seeds ?? 0) > 0)
                        Text('👤 ${stream.seeds}',
                            style: TextStyle(
                                color: (stream.seeds ?? 0) > 10
                                    ? const Color(0xFF22c55e)
                                    : Colors.white38,
                                fontSize: 11,
                                fontWeight: FontWeight.w600)),
                    ],
                  ),
                ],
              ),
            ),

            // Quality badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: qualColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                stream.quality,
                style: TextStyle(
                    color: qualColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, color: Colors.white24, size: 20),
          ],
        ),
      ),
    );
  }
}
