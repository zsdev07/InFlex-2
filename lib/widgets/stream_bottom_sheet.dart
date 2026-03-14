import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/media_model.dart';
import '../services/tmdb_service.dart';
import '../services/stream_service.dart';
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
      debugPrint('[InFlex] IMDB ID: $imdbId for TMDB: ${widget.item.id}');

      if (imdbId == null || imdbId.isEmpty) {
        setState(() {
          _error = 'Could not find IMDB ID.\nTMDB ID: ${widget.item.id}';
          _loading = false;
        });
        return;
      }

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
          _error = 'No streams found yet.\nTry again in a moment.';
        }
      });
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _loading = false;
      });
    }
  }

  void _playStream(TorrentStream stream) {
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          streamUrl: stream.streamUrl,
          title: widget.item.title,
          subtitle: widget.episode != null
              ? 'S${widget.season}:E${widget.episode}'
              : null,
          isEmbed: stream.isEmbed,
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
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 16),
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

          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Column(
                children: [
                  CircularProgressIndicator(
                      color: Color(0xFFFFCC00), strokeWidth: 2),
                  SizedBox(height: 12),
                  Text('Searching all sources…',
                      style: TextStyle(color: Colors.white38, fontSize: 13)),
                ],
              ),
            )
          else if (_streams.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                children: [
                  const Icon(Icons.search_off_rounded,
                      color: Colors.white24, size: 40),
                  const SizedBox(height: 12),
                  Text(
                    _error ?? 'No streams found.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white38, fontSize: 13),
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
                maxHeight: MediaQuery.of(context).size.height * 0.55,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _streams.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _StreamTile(
                  stream: _streams[i],
                  onTap: () => _playStream(_streams[i]),
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
    final qualColor = Color(StreamService.qualityColor(stream.quality));
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
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: qualColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                stream.isEmbed
                    ? Icons.play_circle_outline_rounded
                    : Icons.downloading_rounded,
                color: qualColor, size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stream.isEmbed ? stream.source : stream.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                  Row(
                    children: [
                      Text(
                        stream.isEmbed ? '▶ Direct  ' : '🧲 P2P  ',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11),
                      ),
                      if (stream.size != null)
                        Text('💾 ${stream.size}  ',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11)),
                      if (stream.seeds != null)
                        Text('👤 ${stream.seeds}',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: qualColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(stream.quality,
                  style: TextStyle(
                      color: qualColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, color: Colors.white24, size: 20),
          ],
        ),
      ),
    );
  }
}
