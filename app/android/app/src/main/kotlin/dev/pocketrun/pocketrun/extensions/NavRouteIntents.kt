package dev.pocketrun.pocketrun.extensions

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Port of NavRoute's MainActivity "navroute/intents" channel (navroute 1.4.0+10).
object NavRouteIntents {
    fun register(activity: Activity, flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "navroute/intents").setMethodCallHandler { call, result ->
            when (call.method) {
                // Opens [uri] in the first installed app from [packages]; returns that package, or null.
                "openInApp" -> {
                    val uri = Uri.parse(call.argument<String>("uri"))
                    val packages = call.argument<List<String>>("packages") ?: emptyList()
                    result.success(packages.firstOrNull { open(activity, uri, it) })
                }
                "installedApps" -> {
                    val packages = call.argument<List<String>>("packages") ?: emptyList()
                    result.success(packages.filter { isInstalled(activity, it) })
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isInstalled(activity: Activity, pkg: String): Boolean =
        activity.packageManager.getLaunchIntentForPackage(pkg) != null

    private fun open(activity: Activity, uri: Uri, pkg: String): Boolean {
        if (!isInstalled(activity, pkg)) return false
        return try {
            activity.startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage(pkg).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }
}
