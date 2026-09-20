import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/media_model.dart';
import '../services/release_parser.dart';
import '../services/tmdb_service.dart';
import '../services/stream_service.dart';
import '../services/supabase_cache_repo.dart';
import '../services/torrent_engine.dart' show StreamFileHint;
import '../screens/player_screen.dart';
import '../screens/torrent_loading_screen.dart';

/// ── StreamBottomSheet ─────────────────────────────────────────────────────
///
/// Fetches torrent streams via Torrentio (StreamService), then cross-checks
/// Supabase to see which ones are already cached on Telegram.
///
/// What each source card now tells you (the old cards all just said
/// "Torrentio"):
///   • the real release name
///   • resolution / source / codec / HDR / audio format
///   • AUDIO LANGUAGES detected from the release name (Hindi, English, Dual
///     Audio, Multi ...) - untagged releases are marked "original"
///   • size, seed health (colour coded) and the indexer
///
/// Filter by language and quality, and sort by best match / quality / seeds /
/// size. Cached streams stay pinned on top with the golden style.
///
/// On selection:
///   • Cached torrent  → PlayerScreen directly (stream URL from stream bot)
///   • Torrent         → TorrentLoadingScreen (P2P), told exactly WHICH file
///                       to play (fixes season packs playing the wrong episode)
///   • Embed sources   → PlayerScreen (WebView)

const String _streamBotHost = 'https://streambothost.onrender.com';
const Color _gold = Color(0xFFFFCC00);

enum _SortMode { best, quality, seeds, size }

const Map<_SortMode, String> _sortLabels = {
  _SortMode.best: 'Best match',
  _SortMode.quality: 'Highest quality',
  _SortMode.seeds: 'Most seeds',
  _SortMode.size: 'Smallest size',
};

const Set<String> _indianLanguageCodes = {
  'hi', 'ta', 'te', 'ml', 'kn', 'bn', 'mr', 'pa', 'gu', 'ur',
};

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
  // quality → CacheRow for all cached entries for this movie
  Map<String, CacheRow> _cachedMap = {};
  bool _loading = true;
  String? _error;
  String? _imdbId;

  // Filters / sorting
  String? _langFilter; // null = all
  String? _qualityFilter; // null = all
  _SortMode _sort = _SortMode.best;

  bool get _isTv => widget.item.mediaType == 'tv';

  String? get _originalName =>
      languageNameForCode(widget.item.originalLanguage);

  bool get _originalIsIndian => _indianLanguageCodes
      .contains((widget.item.originalLanguage ?? '').toLowerCase());

  @override
  void initState() {
    super.initState();
    _fetchStreams();
  }

  Future<void> _fetchStreams() async {
    setState(() {
      _loading = true;
      _error = null;
      _cachedMap = {};
    });

    try {
      // ── 1. Resolve IMDB ID ──────────────────────────────────────────────
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

      // ── 2. Fetch streams + Supabase cache in parallel ───────────────────
      final results = await Future.wait([
        StreamService.getAllStreams(
          tmdbId: widget.item.id,
          imdbId: imdbId,
          type: widget.item.mediaType,
          season: widget.season,
          episode: widget.episode,
          movieTitle: widget.item.title,
        ),
        _fetchAllCachedRows(imdbId),
      ]);

      final streams = results[0] as List<TorrentStream>;
      final cachedRows = results[1] as List<CacheRow>;

      // Build quality → CacheRow map (only fully cached rows with file_id)
      final Map<String, CacheRow> cachedMap = {};
      for (final row in cachedRows) {
        if (row.isCached) {
          cachedMap[row.quality.toLowerCase()] = row;
        }
      }

      setState(() {
        _streams = streams;
        _cachedMap = cachedMap;
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

  /// Fetch ALL cached rows for this imdb_id (any quality)
  Future<List<CacheRow>> _fetchAllCachedRows(String imdbId) async {
    try {
      return await SupabaseCacheRepo.findAllByImdbId(imdbId);
    } catch (e) {
      debugPrint('[InFlex] Cache lookup error: $e');
      return [];
    }
  }

  /// Check if a torrent stream has a matching cached row in Supabase
  CacheRow? _getCacheRow(TorrentStream stream) {
    final sq = stream.quality.toLowerCase();
    // Match by quality string (partial)
    for (final entry in _cachedMap.entries) {
      if (sq.contains(entry.key) || entry.key.contains(sq)) {
        return entry.value;
      }
    }
    // Match by infoHash as fallback
    for (final row in _cachedMap.values) {
      if (row.infoHash.isNotEmpty &&
          row.infoHash.toLowerCase() == stream.infoHash.toLowerCase()) {
        return row;
      }
    }
    return null;
  }

  // ── Language / quality helpers ────────────────────────────────────────────

  /// Audio languages of a stream. Untagged releases count as the movie's
  /// original language ("assumed"); the 🇮🇳 flag on an untagged release of a
  /// non-Indian movie means "some Indian-language dub".
  List<String> _audioLangs(TorrentStream s) {
    if (s.info.languages.isNotEmpty) return s.info.languages;
    if (s.info.indianFlag) {
      if (_originalIsIndian && _originalName != null) return [_originalName!];
      return const ['Indian language'];
    }
    final original = _originalName;
    return original != null ? [original] : const [];
  }

  /// True when the language shown was not stated in the release name.
  bool _langAssumed(TorrentStream s) =>
      s.info.languages.isEmpty && !s.info.indianFlag;

  /// Everything a person might filter by: languages + Dual / Multi Audio.
  List<String> _filterTags(TorrentStream s) {
    final tags = <String>[..._audioLangs(s)];
    if (s.info.dualAudio) tags.add('Dual Audio');
    if (s.info.multiAudio) tags.add('Multi Audio');
    return tags;
  }

  String _resolutionBucket(TorrentStream s) {
    final r = s.info.resolution;
    if (r != null) return r;
    final q = s.quality.toUpperCase();
    if (q.contains('4K') || q.contains('2160')) return '4K';
    if (q.contains('1080')) return '1080p';
    if (q.contains('720')) return '720p';
    if (q.contains('480')) return '480p';
    return 'Other';
  }

  int _qualityRank(TorrentStream s) {
    switch (_resolutionBucket(s)) {
      case '4K':
        return 4;
      case '1080p':
        return 3;
      case '720p':
        return 2;
      case '480p':
        return 1;
      default:
        return 0;
    }
  }

  int _healthRank(TorrentStream s) {
    switch (seedHealthFor(s.seeds)) {
      case SeedHealth.strong:
        return 3;
      case SeedHealth.good:
        return 2;
      case SeedHealth.weak:
        return 1;
      case SeedHealth.veryLow:
      case SeedHealth.unknown:
        return 0;
    }
  }

  List<TorrentStream> _applyFilters(List<TorrentStream> base) {
    final list = base.where((s) {
      if (_langFilter != null && !_filterTags(s).contains(_langFilter)) {
        return false;
      }
      if (_qualityFilter != null && _resolutionBucket(s) != _qualityFilter) {
        return false;
      }
      return true;
    }).toList();

    int bySeeds(TorrentStream a, TorrentStream b) =>
        (b.seeds ?? -1).compareTo(a.seeds ?? -1);

    switch (_sort) {
      case _SortMode.best:
        list.sort((a, b) {
          final h = _healthRank(b).compareTo(_healthRank(a));
          if (h != 0) return h;
          final q = _qualityRank(b).compareTo(_qualityRank(a));
          if (q != 0) return q;
          return bySeeds(a, b);
        });
        break;
      case _SortMode.quality:
        list.sort((a, b) {
          final q = _qualityRank(b).compareTo(_qualityRank(a));
          if (q != 0) return q;
          return bySeeds(a, b);
        });
        break;
      case _SortMode.seeds:
        list.sort(bySeeds);
        break;
      case _SortMode.size:
        list.sort((a, b) {
          final sa = a.sizeBytes ?? 1 << 60;
          final sb = b.sizeBytes ?? 1 << 60;
          return sa.compareTo(sb);
        });
        break;
    }
    return list;
  }

  // ── Selection ──────────────────────────────────────────────────────────────

  String _two(int n) => n.toString().padLeft(2, '0');

  /// "Show · S01E03" for episodes, plain title for movies.
  String get _playbackTitle {
    final s = widget.season;
    final e = widget.episode;
    if (_isTv && s != null && e != null) {
      return '${widget.item.title} · S${_two(s)}E${_two(e)}';
    }
    return widget.item.title;
  }

  Future<void> _onTapStream(TorrentStream stream, {CacheRow? cacheRow}) async {
    // A source with almost no seeders usually never loads (that was the
    // "52 seeds" failure) - say so before the user waits on it.
    final seeds = stream.seeds;
    if (cacheRow == null && !stream.isEmbed && seeds != null && seeds < 20) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF14141C),
          title: const Text('Very few seeders',
              style: TextStyle(color: Colors.white, fontSize: 16)),
          content: Text(
            'This source reports only $seeds seeders, so it may load '
            'slowly or not at all. Try it anyway?',
            style: const TextStyle(color: Colors.white60, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Choose another',
                  style: TextStyle(color: Colors.white54)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Try anyway',
                  style: TextStyle(color: _gold)),
            ),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    _selectStream(stream, cacheRow: cacheRow);
  }

  void _selectStream(TorrentStream stream, {CacheRow? cacheRow}) {
    Navigator.pop(context);

    // ── Cached: stream directly from Telegram via stream bot ────────────
    if (cacheRow != null && cacheRow.isCached) {
      final streamUrl = '$_streamBotHost/stream/doc/${cacheRow.fileId}';
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            streamUrl: streamUrl,
            title: widget.item.title,
            subtitle: '${stream.quality} · Cached',
            isEmbed: false,
          ),
        ),
      );
      return;
    }

    // ── Embed / WebView ──────────────────────────────────────────────────
    if (stream.isEmbed) {
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

    // ── Torrent → P2P local stream ───────────────────────────────────────────
    final magnet =
        stream.magnetLink ?? 'magnet:?xt=urn:btih:${stream.infoHash}';

    // Tell the engine WHICH file to play. Season packs hold every episode;
    // without this it just played the biggest file.
    final hint = StreamFileHint(
      fileIdx: stream.fileIdx,
      fileName: stream.fileName,
      season: _isTv ? widget.season : null,
      episode: _isTv ? widget.episode : null,
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TorrentLoadingScreen(
          magnetLink: magnet,
          movieTitle: _playbackTitle,
          quality: stream.quality,
          fileHint: hint,
        ),
      ),
    );
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final torrentCount =
        _streams.where((s) => !s.isEmbed && s.infoHash.isNotEmpty).length;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.94,
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('SELECT SOURCE',
                            style: TextStyle(
                                color: _gold,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.5)),
                        const SizedBox(height: 2),
                        Text(
                          _loading
                              ? 'Searching sources...'
                              : '$_playbackTitle  ·  $torrentCount torrent sources',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: Colors.white54, size: 20),
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
            CircularProgressIndicator(color: _gold, strokeWidth: 2.5),
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
              const Icon(Icons.error_outline,
                  color: Colors.redAccent, size: 36),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 20),
              TextButton(
                onPressed: _fetchStreams,
                child: const Text('Retry', style: TextStyle(color: _gold)),
              ),
            ],
          ),
        ),
      );
    }

    final baseTorrents = _streams
        .where((s) => !s.isEmbed && s.infoHash.isNotEmpty)
        .toList();
    final embedStreams = _streams.where((s) => s.isEmbed).toList();

    final filtered = _applyFilters(baseTorrents);
    final cachedStreams =
        filtered.where((s) => _getCacheRow(s) != null).toList();
    final p2pStreams = filtered.where((s) => _getCacheRow(s) == null).toList();

    return Column(
      children: [
        if (baseTorrents.isNotEmpty) _buildFilterBar(baseTorrents),
        Expanded(
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (baseTorrents.isNotEmpty && filtered.isEmpty)
                _NoMatch(onClear: () {
                  setState(() {
                    _langFilter = null;
                    _qualityFilter = null;
                  });
                }),

              // ── Cached section (golden, pinned top) ────────────────────
              if (cachedStreams.isNotEmpty) ...[
                const _SectionHeader(
                  icon: Icons.bolt_rounded,
                  label: 'CACHED ON TELEGRAM',
                  color: _gold,
                  subtitle: 'Ready · Instant Stream',
                ),
                ...cachedStreams.map((s) => _StreamTile(
                      stream: s,
                      cacheRow: _getCacheRow(s),
                      langTags: _tagsFor(s),
                      onTap: () =>
                          _onTapStream(s, cacheRow: _getCacheRow(s)),
                    )),
              ],

              // ── Peer-to-peer torrent sources ────────────────────────────
              if (p2pStreams.isNotEmpty) ...[
                const _SectionHeader(
                  icon: Icons.hub_rounded,
                  label: 'TORRENT SOURCES',
                  color: _gold,
                  subtitle: 'Streams peer-to-peer · tap to play',
                ),
                ...p2pStreams.map((s) => _StreamTile(
                      stream: s,
                      cacheRow: null,
                      langTags: _tagsFor(s),
                      onTap: () => _onTapStream(s),
                    )),
              ],

              // ── Embed fallbacks ───────────────────────────────────────────
              if (embedStreams.isNotEmpty) ...[
                const _SectionHeader(
                  icon: Icons.language_rounded,
                  label: 'EMBED SOURCES',
                  color: Colors.white54,
                  subtitle: 'Fallback · WebView player',
                ),
                ...embedStreams.map((s) => _StreamTile(
                      stream: s,
                      cacheRow: null,
                      langTags: const [],
                      onTap: () => _onTapStream(s),
                    )),
              ],

              if (baseTorrents.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Text(
                    'Languages are read from the release name. Seed counts '
                    'come from trackers and can be outdated.',
                    style: TextStyle(
                        color: Colors.white24, fontSize: 10, height: 1.4),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Language chips for one card (explicit ones first, then Dual / Multi / Subs).
  List<_LangTag> _tagsFor(TorrentStream s) {
    if (s.isEmbed) return const [];
    final assumed = _langAssumed(s);
    final tags = <_LangTag>[
      for (final l in _audioLangs(s)) _LangTag(l, assumed: assumed),
    ];
    if (s.info.dualAudio) tags.add(const _LangTag('Dual Audio', special: true));
    if (s.info.multiAudio) {
      tags.add(const _LangTag('Multi Audio', special: true));
    }
    if (s.info.hasSubs) tags.add(const _LangTag('Subs', muted: true));
    return tags;
  }

  Widget _buildFilterBar(List<TorrentStream> base) {
    // Language chips with counts, most common first.
    final counts = <String, int>{};
    for (final s in base) {
      for (final t in _filterTags(s).toSet()) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    final langs = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));

    // Resolution chips in a fixed order.
    const order = ['4K', '1080p', '720p', '480p', 'Other'];
    final present = base.map(_resolutionBucket).toSet();
    final qualities = order.where(present.contains).toList();

    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Column(
        children: [
          if (langs.length >= 2)
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _FilterChip(
                    label: 'All languages',
                    selected: _langFilter == null,
                    onTap: () => setState(() => _langFilter = null),
                  ),
                  for (final l in langs)
                    _FilterChip(
                      label: '$l (${counts[l]})',
                      selected: _langFilter == l,
                      onTap: () => setState(
                          () => _langFilter = _langFilter == l ? null : l),
                    ),
                ],
              ),
            ),
          if (langs.length >= 2) const SizedBox(height: 6),
          SizedBox(
            height: 34,
            child: Row(
              children: [
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(left: 12),
                    children: [
                      if (qualities.length >= 2) ...[
                        _FilterChip(
                          label: 'Any quality',
                          selected: _qualityFilter == null,
                          onTap: () => setState(() => _qualityFilter = null),
                        ),
                        for (final q in qualities)
                          _FilterChip(
                            label: q,
                            selected: _qualityFilter == q,
                            onTap: () => setState(() =>
                                _qualityFilter = _qualityFilter == q ? null : q),
                          ),
                      ],
                    ],
                  ),
                ),
                PopupMenuButton<_SortMode>(
                  tooltip: 'Sort',
                  color: const Color(0xFF1B1B26),
                  onSelected: (m) => setState(() => _sort = m),
                  itemBuilder: (_) => [
                    for (final m in _SortMode.values)
                      PopupMenuItem<_SortMode>(
                        value: m,
                        child: Row(
                          children: [
                            Icon(
                              _sort == m
                                  ? Icons.check_rounded
                                  : Icons.circle_outlined,
                              size: 16,
                              color: _sort == m ? _gold : Colors.white24,
                            ),
                            const SizedBox(width: 10),
                            Text(_sortLabels[m]!,
                                style: TextStyle(
                                    color: _sort == m
                                        ? _gold
                                        : Colors.white70,
                                    fontSize: 13)),
                          ],
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.sort_rounded,
                            color: Colors.white54, size: 18),
                        const SizedBox(width: 4),
                        Text(_sortLabels[_sort]!,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

// ── SUB WIDGETS ───────────────────────────────────────────────────────────────

class _LangTag {
  final String label;

  /// Not stated in the release name - assumed to be the movie's original audio.
  final bool assumed;

  /// Dual / Multi Audio styling.
  final bool special;

  /// Subtitles (not audio).
  final bool muted;

  const _LangTag(this.label,
      {this.assumed = false, this.special = false, this.muted = false});
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? _gold : Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(17),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.black : Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _NoMatch extends StatelessWidget {
  final VoidCallback onClear;
  const _NoMatch({required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
      child: Column(
        children: [
          const Icon(Icons.filter_alt_off_rounded,
              color: Colors.white24, size: 32),
          const SizedBox(height: 10),
          const Text('No sources match these filters',
              style: TextStyle(color: Colors.white54, fontSize: 13)),
          TextButton(
            onPressed: onClear,
            child: const Text('Clear filters', style: TextStyle(color: _gold)),
          ),
        ],
      ),
    );
  }
}

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
          Flexible(
            child: Text(subtitle,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: Colors.white24, fontSize: 10)),
          ),
        ],
      ),
    );
  }
}

class _StreamTile extends StatelessWidget {
  final TorrentStream stream;
  final CacheRow? cacheRow;
  final List<_LangTag> langTags;
  final VoidCallback onTap;

  const _StreamTile({
    required this.stream,
    required this.cacheRow,
    required this.langTags,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isCached = cacheRow != null;
    final qualColor =
        isCached ? 0xFFFFCC00 : StreamService.qualityColor(stream.quality);

    // Small grey technical chips: BluRay · HEVC · HDR · Atmos
    final tech = <String>[
      if (stream.info.source != null) stream.info.source!,
      if (stream.info.codec != null) stream.info.codec!,
      if (stream.info.hdr != null) stream.info.hdr!,
      if (stream.info.audio != null) stream.info.audio!,
    ];

    final showFile = stream.fileName != null &&
        stream.fileName!.trim().isNotEmpty &&
        stream.fileName!.trim() != stream.title.trim();

    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isCached
              ? _gold.withValues(alpha: 0.06)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isCached
                ? _gold.withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.06),
            width: isCached ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
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
                  // Release name + CACHED badge
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          stream.title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              height: 1.25),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isCached) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: _gold.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '⚡ CACHED',
                            style: TextStyle(
                                color: _gold,
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8),
                          ),
                        ),
                      ],
                    ],
                  ),

                  // Episode file inside a pack
                  if (showFile) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.movie_filter_rounded,
                            color: Colors.white30, size: 11),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            stream.fileName!.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ],

                  // Technical chips
                  if (tech.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 5,
                      runSpacing: 4,
                      children: [for (final t in tech) _TechChip(t)],
                    ),
                  ],

                  // Language chips
                  if (langTags.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 5,
                      runSpacing: 4,
                      children: [for (final t in langTags) _LangChip(t)],
                    ),
                  ],

                  const SizedBox(height: 6),
                  _buildMetaRow(isCached),
                ],
              ),
            ),

            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                Icons.play_circle_rounded,
                color: isCached ? _gold : Colors.white24,
                size: 22,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaRow(bool isCached) {
    if (isCached) {
      return Row(
        children: [
          const Text('Torrentio Cached',
              style: TextStyle(
                  color: Color(0xB3FFCC00),
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          if (cacheRow!.fileSizeBytes != null) ...[
            const Icon(Icons.storage_rounded,
                color: Colors.white30, size: 11),
            const SizedBox(width: 3),
            Text(
              _formatSize(cacheRow!.fileSizeBytes!),
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const SizedBox(width: 10),
          ],
          const Icon(Icons.play_circle_rounded, color: _gold, size: 11),
          const SizedBox(width: 3),
          const Text(
            'Instant Stream',
            style: TextStyle(
                color: _gold, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      );
    }

    final health = seedHealthFor(stream.seeds);
    final (Color healthColor, String healthLabel) = switch (health) {
      SeedHealth.strong => (const Color(0xFF22C55E), 'Strong'),
      SeedHealth.good => (const Color(0xFF84CC16), 'Good'),
      SeedHealth.weak => (const Color(0xFFFF9500), 'Weak'),
      SeedHealth.veryLow => (const Color(0xFFEF4444), 'Very low'),
      SeedHealth.unknown => (Colors.white30, 'Unknown'),
    };

    return Wrap(
      spacing: 10,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (stream.size != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.storage_rounded,
                  color: Colors.white30, size: 11),
              const SizedBox(width: 3),
              Text(stream.size!,
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 11)),
            ],
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration:
                  BoxDecoration(color: healthColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(
              stream.seeds != null
                  ? '${stream.seeds} seeds · $healthLabel'
                  : 'Seeds unknown',
              style: TextStyle(
                  color: healthColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
        if (stream.provider != null && stream.provider!.isNotEmpty)
          Text(stream.provider!,
              style: const TextStyle(color: Colors.white24, fontSize: 11))
        else if (stream.isEmbed)
          Text(stream.source,
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ],
    );
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
}

class _TechChip extends StatelessWidget {
  final String text;
  const _TechChip(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: const TextStyle(
              color: Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.w600)),
    );
  }
}

class _LangChip extends StatelessWidget {
  final _LangTag tag;
  const _LangChip(this.tag);

  @override
  Widget build(BuildContext context) {
    final Color color;
    if (tag.muted) {
      color = Colors.white38;
    } else if (tag.special) {
      color = const Color(0xFFA78BFA); // Dual / Multi audio
    } else if (tag.assumed) {
      color = Colors.white54; // not stated in the name
    } else {
      color = const Color(0xFF38BDF8); // stated audio language
    }
    final text = tag.assumed ? '${tag.label} · original' : tag.label;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }
}
