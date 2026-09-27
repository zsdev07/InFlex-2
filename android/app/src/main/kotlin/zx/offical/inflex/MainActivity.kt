package zx.offical.inflex

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// ── MainActivity ─────────────────────────────────────────────────────────────
//
// Adds Picture-in-Picture on top of the default FlutterActivity. Talks to
// the Dart side over one method channel ("inflex/pip", see
// lib/services/pip_service.dart):
//
//   Dart -> native  "isAvailable"   is PiP supported on this device/OS?
//                   "setState"      { allowed, playing } - is a video open,
//                                   and is it actually playing right now?
//                   "enter"         enter PiP immediately (a button tap)
//   native -> Dart  "onModeChanged" PiP just started or ended
//
// PictureInPictureParams (and therefore any of this) only exists from
// Android 8.0 (API 26) - every SDK check below gates on that, and on an
// older device every method quietly does nothing / returns false, exactly
// like PipService already expects.
class MainActivity : FlutterActivity() {
    private val channelName = "inflex/pip"
    private var channel: MethodChannel? = null

    // What the Flutter side last told us via "setState". Read by
    // onUserLeaveHint() to decide whether leaving the app (Home button,
    // switching apps, the overview screen) should drop into PiP.
    private var pipAllowed = false
    private var isPlaying = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                "setState" -> {
                    pipAllowed = call.argument<Boolean>("allowed") ?: false
                    isPlaying = call.argument<Boolean>("playing") ?: false
                    result.success(null)
                }
                "enter" -> result.success(enterPip())
                else -> result.notImplemented()
            }
        }
    }

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(16, 9))
                .build()
            enterPictureInPictureMode(params)
        } catch (e: Exception) {
            // IllegalStateException etc. (e.g. called at a bad moment) -
            // just stay in the normal window, nothing else to do.
            false
        }
    }

    // Called by Android right before the app leaves the foreground (Home
    // button, recents, switching to another app) - the standard hook for
    // "auto-enter PiP if a video is playing".
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && pipAllowed && isPlaying) {
            enterPip()
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("onModeChanged", isInPictureInPictureMode)
    }
}
