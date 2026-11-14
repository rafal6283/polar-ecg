package pl.fourvision.polar_ecg

import android.content.Intent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterFragmentActivity – wymagane przez Health Connect (okno zgód).
 * Akcje uruchomienia z kafelka szybkich ustawień („Sprawdź rytm”) przekazywane do Fluttera.
 */
class MainActivity : FlutterFragmentActivity() {
    private var channel: MethodChannel? = null
    private var pending: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pending = intent?.getStringExtra(EXTRA_ACTION)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "polar_ekg/launch").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "takeAction") {
                    result.success(pending)
                    pending = null
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val action = intent.getStringExtra(EXTRA_ACTION) ?: return
        channel?.invokeMethod("action", action)
    }

    companion object {
        const val EXTRA_ACTION = "polar_ekg_action"
    }
}
