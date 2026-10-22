package com.snappdf.pro.io

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.snappdf.pro.OpError
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Encrypts small private blobs (saved signatures) with an AES-256-GCM key
 * held in the Android Keystore. The key never leaves secure hardware where
 * available, and the files are excluded from backups.
 *
 * File format: [version=1][12-byte IV][ciphertext + 16-byte tag].
 */
class SecureStore(context: Context) {
    private val dir = File(context.filesDir, "secure").apply { mkdirs() }

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun fileFor(name: String): File {
        if (!name.matches(Regex("[A-Za-z0-9_-]{1,64}"))) throw OpError.badArgs("Invalid item name.")
        return File(dir, "$name.bin")
    }

    fun write(name: String, data: ByteArray) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        val encrypted = cipher.doFinal(data)
        val target = fileFor(name)
        val tmp = File(dir, ".${target.name}.part")
        tmp.outputStream().use { out ->
            out.write(1)
            out.write(iv)
            out.write(encrypted)
        }
        if (!tmp.renameTo(target)) {
            tmp.delete()
            throw OpError(OpError.IO, "Could not save securely.")
        }
    }

    fun read(name: String): ByteArray? {
        val file = fileFor(name)
        if (!file.isFile) return null
        val bytes = file.readBytes()
        if (bytes.size < 1 + 12 + 16 || bytes[0].toInt() != 1) throw OpError(OpError.INVALID_FILE, "Stored item is damaged.")
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 1, 12))
        return try {
            cipher.doFinal(bytes, 13, bytes.size - 13)
        } catch (e: Exception) {
            throw OpError(OpError.INVALID_FILE, "Stored item could not be decrypted.", e)
        }
    }

    fun delete(name: String): Boolean = fileFor(name).delete()

    fun list(): List<String> = dir.listFiles { f -> f.name.endsWith(".bin") }
        ?.sortedBy { it.lastModified() }
        ?.map { it.name.removeSuffix(".bin") } ?: emptyList()

    companion object {
        private const val ALIAS = "snappdf_private_v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
