import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// ── SubtitleHasher ────────────────────────────────────────────────────────────
//
// The OpenSubtitles "movie hash": a 16-hex-digit fingerprint of a video file
// = file size + the sum of every little-endian 64-bit word in the FIRST 64 KiB
// + the same for the LAST 64 KiB (all modulo 2^64). Two copies of the same
// release produce the same hash, so the subtitle addon can return the
// subtitle uploaded for THIS exact file instead of a guess by title -
// which is what fixes "subtitles are a few seconds off" on odd releases
// (pre-release rips, different cuts).
//
// We never have the whole file - it's still downloading - so we ask our own
// local stream server for just the two 64 KiB ranges. Asking for the tail also
// makes InTorrent pull that piece to the front of the download queue, so this
// works even when the player hasn't touched the end of the file yet.

class SubtitleHasher {
  SubtitleHasher._();

  static const int _chunk = 65536;

  /// Hash of the file served at [streamUrl] (a localhost InTorrent URL), or
  /// null if it can't be computed (file too small, size unknown, ranges not
  /// downloadable within [timeout], server error).
  static Future<String?> hashFromStream(
    String streamUrl,
    int? fileSize, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (fileSize == null || fileSize < _chunk * 2) return null;

    final client = http.Client();
    try {
      final head = await _readRange(client, streamUrl, 0, timeout);
      final tail = await _readRange(client, streamUrl, fileSize - _chunk, timeout);
      if (head == null || tail == null) return null;
      final hash = compute(fileSize, head, tail);
      debugPrint('[SubtitleHasher] $hash (size $fileSize)');
      return hash;
    } catch (e) {
      debugPrint('[SubtitleHasher] failed: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// Reads EXACTLY [_chunk] bytes starting at [start], or returns null. Streams
  /// the response and stops after 64 KiB, so a server that ignored the Range
  /// header can never make us pull the whole movie into memory.
  static Future<Uint8List?> _readRange(
    http.Client client,
    String url,
    int start,
    Duration timeout,
  ) async {
    final request = http.Request('GET', Uri.parse(url))
      ..headers['Range'] = 'bytes=$start-${start + _chunk - 1}';
    final response = await client.send(request).timeout(timeout);

    // 206 only: a plain 200 would be the start of the file, not the range
    // we asked for, and would silently give a wrong hash for the tail.
    if (response.statusCode != 206) return null;

    final out = BytesBuilder(copy: false);
    await for (final part in response.stream.timeout(timeout)) {
      out.add(part);
      if (out.length >= _chunk) break;
    }
    if (out.length < _chunk) return null;
    final bytes = out.takeBytes();
    return Uint8List.sublistView(bytes, 0, _chunk);
  }

  /// The hash itself. [head] / [tail] are the first / last 64 KiB.
  @visibleForTesting
  static String compute(int fileSize, Uint8List head, Uint8List tail) {
    var hash = fileSize;
    hash = _addWords(hash, head);
    hash = _addWords(hash, tail);
    // Format as two 32-bit halves: `toRadixString` on a negative 64-bit int
    // would print a minus sign.
    final hi = (hash >> 32) & 0xFFFFFFFF;
    final lo = hash & 0xFFFFFFFF;
    return hi.toRadixString(16).padLeft(8, '0') +
        lo.toRadixString(16).padLeft(8, '0');
  }

  /// Adds every little-endian 64-bit word of [data] to [acc] (64-bit wrap-around,
  /// which Dart's native int arithmetic does for us).
  static int _addWords(int acc, Uint8List data) {
    final view = ByteData.sublistView(data);
    for (var offset = 0; offset + 8 <= data.length; offset += 8) {
      acc += view.getUint64(offset, Endian.little);
    }
    return acc;
  }
}
