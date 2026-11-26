package com.passbook.passbook

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 自动更新的 Android 侧：把下载好的 APK 交给系统安装器。
 *
 * 应用不能自替换，也**不能绕过**「安装未知应用」那道用户闸：
 * 没开权限时把用户送到那个开关前，然后如实返回 false（Dart 侧会报出来），
 * 不假装已开始安装。
 *
 * 基类必须是 FlutterFragmentActivity（不是 FlutterActivity）：
 * 生物识别的系统弹窗走 androidx.biometric，它要一个 FragmentActivity。
 * 用 FlutterActivity 时指纹对话框会直接抛「no_fragment_activity」。
 */
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "passbook/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "缺少 path 参数", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(openInstaller(path))
                        } catch (e: Exception) {
                            result.error("install_failed", e.message ?: e.toString(), null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // 主密码的加密存放（指纹解锁用）。桌面端没有这条通道，Dart 侧会如实降级。
        val secure = SecureStore(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "passbook/secure")
            .setMethodCallHandler { call, result ->
                val key = call.argument<String>("key")
                try {
                    when (call.method) {
                        "available" -> result.success(true)
                        "read" -> {
                            if (key.isNullOrEmpty()) {
                                result.error("bad_args", "缺少 key 参数", null)
                                return@setMethodCallHandler
                            }
                            result.success(secure.read(key))
                        }
                        "write" -> {
                            val value = call.argument<String>("value")
                            if (key.isNullOrEmpty() || value == null) {
                                result.error("bad_args", "缺少 key 或 value 参数", null)
                                return@setMethodCallHandler
                            }
                            secure.write(key, value)
                            result.success(null)
                        }
                        "delete" -> {
                            if (key.isNullOrEmpty()) {
                                result.error("bad_args", "缺少 key 参数", null)
                                return@setMethodCallHandler
                            }
                            secure.delete(key)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("secure_failed", e.message ?: e.toString(), null)
                }
            }
    }

    private fun openInstaller(path: String): Boolean {
        val file = File(path)
        if (!file.exists()) {
            throw IllegalStateException("更新包不存在：$path")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            // 把用户直接送到开关前——比一句「请去设置里开权限」有用得多。
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                )
            )
            return false
        }
        val uri = FileProvider.getUriForFile(this, "${packageName}.updater", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        return true
    }
}
