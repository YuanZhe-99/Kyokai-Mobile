package com.yuanzhe.kyokai

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.BitmapFactory
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Images on the phone's clipboard, both ways: what a host copied goes on
 * as a PNG [ClipProvider] serves, and an image the person copied
 * here is read back as PNG for the core to offer to hosts.
 *
 * A clipboard image is a content URI, so the app reads it while in front
 * (Android lets only the app in front read the clipboard). Each is marked
 * by its URI and the time it was copied, so the same copy is read once.
 */
object Clip {
    const val AUTHORITY = "com.yuanzhe.kyokai.clip"

    private fun manager(ctx: Context) = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    /** The clipboard's image now: its mark and, unless the mark is [unless], its pixels as PNG. */
    fun image(ctx: Context, unless: String?): Map<String, Any?>? {
        val cm = manager(ctx)
        val clip = cm.primaryClip ?: return null
        val desc = clip.description
        if (clip.itemCount == 0 || !(0 until desc.mimeTypeCount).any { desc.getMimeType(it).startsWith("image/") }) return null
        val uri = clip.getItemAt(0).uri ?: return null
        val at = if (Build.VERSION.SDK_INT >= 26) desc.timestamp else 0L
        val mark = "$uri@$at"
        if (mark == unless) return mapOf("mark" to mark)
        val bytes = ctx.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return null
        val type = ctx.contentResolver.getType(uri) ?: ""
        val png = if (type == "image/png") bytes else {
            val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
            ByteArrayOutputStream().also { bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it); bmp.recycle() }.toByteArray()
        }
        return mapOf("mark" to mark, "png" to png)
    }

    /**
     * Puts [png] on the clipboard, written to the app's cache where its
     * [ClipProvider] serves it. Returns the mark [image] will read it back with.
     */
    fun setImage(ctx: Context, png: ByteArray): String {
        val dir = File(ctx.cacheDir, "clip").apply { mkdirs() }
        // A new name each time: apps that read the last one keep theirs.
        dir.listFiles()?.sortedBy { it.lastModified() }?.dropLast(4)?.forEach { it.delete() }
        val file = File(dir, "kyokai-${System.currentTimeMillis()}.png")
        file.writeBytes(png)
        val uri = android.net.Uri.parse("content://$AUTHORITY/${file.name}")
        val clip = ClipData.newUri(ctx.contentResolver, "Kyokai", uri)
        manager(ctx).setPrimaryClip(clip)
        val desc = manager(ctx).primaryClip?.description
        val at = if (Build.VERSION.SDK_INT >= 26) desc?.timestamp ?: 0L else 0L
        return "$uri@$at"
    }
}

/**
 * Serves the images the app put on the clipboard (cache/clip), read only,
 * to whichever app pastes them: what FileProvider does, without the
 * library.
 */
class ClipProvider : android.content.ContentProvider() {
    private fun fileOf(uri: android.net.Uri): File? {
        val name = uri.lastPathSegment ?: return null
        if (!name.matches(Regex("kyokai-[0-9]+\\.png"))) return null
        return File(File(context!!.cacheDir, "clip"), name).takeIf { it.isFile }
    }

    override fun onCreate() = true
    override fun getType(uri: android.net.Uri) = "image/png"
    override fun openFile(uri: android.net.Uri, mode: String): android.os.ParcelFileDescriptor? {
        if (mode != "r") throw SecurityException("read only")
        val f = fileOf(uri) ?: throw java.io.FileNotFoundException("$uri")
        return android.os.ParcelFileDescriptor.open(f, android.os.ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(
        uri: android.net.Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?,
    ): android.database.Cursor? {
        val f = fileOf(uri) ?: return null
        val cols = arrayOf(android.provider.OpenableColumns.DISPLAY_NAME, android.provider.OpenableColumns.SIZE)
        return android.database.MatrixCursor(cols).apply { addRow(arrayOf<Any>(f.name, f.length())) }
    }

    override fun insert(uri: android.net.Uri, values: android.content.ContentValues?) = null
    override fun delete(uri: android.net.Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: android.net.Uri, values: android.content.ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
}
