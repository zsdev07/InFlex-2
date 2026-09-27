import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// ── PipService ────────────────────────────────────────────────────────────────
//
// Talks to the small native channel added in MainActivity.kt
// (android/app/src/main/kotlin/zx/offical/inflex/MainActivity.kt). Android
// itself owns Picture-in-Picture; this only:
//   * tells Android whether PiP should be offered right now, and whether the
//     video is actually playing (setState) - MainActivity uses that to
//     decide, in its own onUserLeaveHint(), whether to auto-enter PiP when
//     the person leaves the app (Home button / switching apps) while
//     something is playing;
//   * lets the player trigger PiP immediately from a button (enter);
//   * tells the player when PiP mode itself starts/stops (modeChanges), so
//     it can hide controls that make no sense in a thumbnail-sized window.
//
// PiP only exists on Android 8.0+ (API 26) and only makes sense there, so
// every call is a no-op (and every method returns quietly) on anything else
// - iOS, older Android, or a platform channel that doesn't exist for some
// other reason. Nothing here can crash the player if it fails.

class PipService {
  PipService._();

  static const MethodChannel _channel = MethodChannel('inflex/pip');

  static bool _handlerInstalled = false;
  static final StreamController<bool> _modeChanges =
      StreamController<bool>.broadcast();

  /// Fires with `true` when Android puts the activity into PiP, `false` when
  /// it leaves PiP (back to full screen, or the user closed the PiP window).
  static Stream<bool> get modeChanges => _modeChanges.stream;

  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onModeChanged') {
        _modeChanges.add(call.arguments == true);
      }
      return null;
    });
  }

  /// Whether this device/OS can show PiP at all. Cache the result yourself
  /// if you call this often - it's a channel round-trip.
  static Future<bool> isAvailable() async {
    _ensureHandler();
    try {
      final ok = await _channel.invokeMethod<bool>('isAvailable');
      return ok ?? false;
    } catch (e) {
      debugPrint('[PipService] isAvailable failed: $e');
      return false;
    }
  }

  /// Tells Android whether a video is open right now ([allowed]) and
  /// whether it's actively playing ([playing]). Call this whenever either
  /// changes - MainActivity only auto-enters PiP when both are true.
  static Future<void> setState({
    required bool allowed,
    required bool playing,
  }) async {
    _ensureHandler();
    try {
      await _channel.invokeMethod('setState', {
        'allowed': allowed,
        'playing': playing,
      });
    } catch (e) {
      debugPrint('[PipService] setState failed: $e');
    }
  }

  /// Enters PiP immediately (a manual "Picture in picture" button, say).
  /// Returns false if PiP isn't available or Android refused it - the
  /// caller should keep the normal player UI in that case, nothing else to
  /// do.
  static Future<bool> enter() async {
    _ensureHandler();
    try {
      final ok = await _channel.invokeMethod<bool>('enter');
      return ok ?? false;
    } catch (e) {
      debugPrint('[PipService] enter failed: $e');
      return false;
    }
  }
}
