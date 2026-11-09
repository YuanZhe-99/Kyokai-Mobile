package com.yuanzhe.kyokai

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The secrets store's key (doc/en-us/security.md): 32 random bytes kept
 * in the app's files, sealed with an AES-GCM key that never leaves the
 * Android Keystore — as Windows keeps it under DPAPI and macOS in the
 * Keychain. The core gets it as it starts.
 */
object MasterKey {
    private const val ALIAS = "kyokai-master"
    private const val FILE = "master.key"

    private fun wrapping(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    /** The key, base64; made on first use. Null when the Keystore cannot open it (secrets then stay in memory). */
    fun get(context: Context): String? = try {
        val file = File(context.noBackupFilesDir, FILE)
        val key = wrapping()
        val raw = if (file.exists()) {
            val sealed = file.readBytes()
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, sealed, 0, 12))
                doFinal(sealed, 12, sealed.size - 12)
            }
        } else {
            val fresh = ByteArray(32).also { SecureRandom().nextBytes(it) }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key) }
            val sealed = cipher.iv + cipher.doFinal(fresh)
            val tmp = File(context.noBackupFilesDir, "$FILE.tmp")
            tmp.writeBytes(sealed)
            if (!tmp.renameTo(file)) throw IllegalStateException("cannot save the secrets key")
            fresh
        }
        Base64.encodeToString(raw, Base64.NO_WRAP).also { raw.fill(0) }
    } catch (e: Exception) {
        null
    }
}
