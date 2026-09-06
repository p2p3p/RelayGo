package com.relaygo.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "relaygo/keep_alive"
        private const val TAG = "RelayGo_Native"
    }

    /// 写入诊断日志（纯 logcat，零磁盘 IO，不阻塞首帧）
    private fun diagLog(msg: String) {
        Log.i(TAG, "${System.currentTimeMillis()} $msg")
    }

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(newBase)
        diagLog("=== attachBaseContext ===")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        diagLog("=== onCreate start ===")
        super.onCreate(savedInstanceState)
        diagLog("=== onCreate super done ===")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        diagLog("=== configureFlutterEngine start ===")
        try {
            super.configureFlutterEngine(flutterEngine)
            diagLog("=== configureFlutterEngine super done ===")

            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "startKeepAlive" -> {
                            KeepAliveService.start(this)
                            result.success(true)
                        }
                        "stopKeepAlive" -> {
                            KeepAliveService.stop(this)
                            result.success(true)
                        }
                        "isIgnoringBatteryOptimizations" -> {
                            result.success(isIgnoringBatteryOptimizations())
                        }
                        "requestIgnoreBatteryOptimizations" -> {
                            requestIgnoreBatteryOptimizations()
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                }
            // 诊断通道：Dart 侧通过此通道报告执行进度
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "relaygo/diag")
                .setMethodCallHandler { call, result ->
                    if (call.method == "diag") {
                        val msg = call.argument<String>("msg") ?: "unknown"
                        diagLog(">>> DART: $msg")
                        result.success(true)
                    } else {
                        result.notImplemented()
                    }
                }
            diagLog("=== configureFlutterEngine done ===")
        } catch (e: Exception) {
            diagLog("=== configureFlutterEngine ERROR: ${e.javaClass.name}: ${e.message}")
            diagLog(Log.getStackTraceString(e))
        }
    }

    override fun onPostCreate(savedInstanceState: Bundle?) {
        diagLog("=== onPostCreate start ===")
        super.onPostCreate(savedInstanceState)
        diagLog("=== onPostCreate done ===")
    }

    override fun onStart() {
        diagLog("=== onStart start ===")
        super.onStart()
        diagLog("=== onStart done ===")
    }

    override fun onResume() {
        diagLog("=== onResume start ===")
        super.onResume()
        diagLog("=== onResume done ===")
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        diagLog("=== onWindowFocusChanged hasFocus=$hasFocus ===")
    }

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        diagLog("=== onFlutterUiDisplayed === (Flutter UI 首帧渲染成功!)")
    }

    override fun onFlutterUiNoLongerDisplayed() {
        super.onFlutterUiNoLongerDisplayed()
        diagLog("=== onFlutterUiNoLongerDisplayed ===")
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (!pm.isIgnoringBatteryOptimizations(packageName)) {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(intent)
        }
    }
}
