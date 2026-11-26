package com.passbook.passbook

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 主密码的加密存放处（Dart 侧通道 passbook/secure 的落地实现）。
 *
 * 这里只存一个值：被指纹解锁托管的那份主密码。
 * 加密用的 AES 密钥生成在 AndroidKeyStore 里，**不可导出**；密文落在
 * SharedPreferences，但要解开必须有那把留在 KeyStore 里的密钥。
 * 设备被 root 之后仍可能被取出，但那时已经不是「随手读一个文件」的难度了。
 *
 * 为什么不用第三方存储包：它们的 Windows 实现要 ATL、还要在 CMake 里现场
 * 拉 nuget 包，而本机没有 ATL 组件；桌面端本来也不打算提供这个功能。
 * 自己写这一份只依赖系统 KeyStore，两端构建都不受影响。
 */
class SecureStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun write(key: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val body = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        // IV 每次加密都是新的，跟密文一起存，格式 iv:body（都是 base64）。
        prefs.edit().putString(key, encode(cipher.iv) + ":" + encode(body)).apply()
    }

    fun read(key: String): String? {
        val packed = prefs.getString(key, null) ?: return null
        val parts = packed.split(":")
        if (parts.size != 2) return null
        val cipher = Cipher.getInstance(TRANSFORMATION)
        val spec = GCMParameterSpec(TAG_BITS, Base64.decode(parts[0], Base64.NO_WRAP))
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), spec)
        val plain = cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP))
        return String(plain, Charsets.UTF_8)
    }

    fun delete(key: String) {
        prefs.edit().remove(key).apply()
    }

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (store.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                // 不要求每次解密都做生物验证：那一步由 local_auth 负责，
                // 这里再要一次会让用户为同一次解锁按两遍指纹。
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey()
    }

    private fun encode(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.NO_WRAP)

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "passbook.biometric"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val PREFS = "passbook_secure"
        const val TAG_BITS = 128
    }
}
