package dev.pocketrun.pocketrun

import android.content.Context
import dev.pocketrun.pocketrun.extensions.NavRouteIntents
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

class MainActivity : FlutterActivity() {
    // One engine for the whole process. The project's code lives in this engine after the hot
    // restart, so it must survive the activity closing (Back on the project's home screen, or
    // Android recreating the activity after the camera or file picker).
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        return cache.get(ENGINE_ID) ?: FlutterEngine(context.applicationContext).also { cache.put(ENGINE_ID, it) }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Project native extensions: custom channels a project's own MainActivity provides.
        NavRouteIntents.register(this, flutterEngine)
    }

    private companion object {
        const val ENGINE_ID = "pocketrun"
    }
}
