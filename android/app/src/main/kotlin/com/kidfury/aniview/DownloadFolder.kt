package com.kidfury.aniview

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.io.FileNotFoundException

/** Storage Access Framework bridge. Each episode is one directory under the chosen tree. */
object DownloadFolder {
    private fun root(context: Context, tree: String): DocumentFile =
        DocumentFile.fromTreeUri(context, Uri.parse(tree)) ?: throw FileNotFoundException("Download folder is unavailable")

    fun export(context: Context, tree: String, id: String, path: String) {
        val source = File(path)
        if (!source.isDirectory) throw FileNotFoundException("Download is incomplete")
        val parent = root(context, tree)
        val folder = parent.findFile(id) ?: parent.createDirectory(id)
            ?: throw FileNotFoundException("Cannot create episode folder")
        for (file in source.listFiles() ?: emptyArray()) {
            if (!file.isFile || file.name.endsWith(".part")) continue
            val target = folder.findFile(file.name) ?: folder.createFile(
                if (file.name.endsWith(".m3u8")) "application/vnd.apple.mpegurl" else "application/octet-stream",
                file.name,
            ) ?: throw FileNotFoundException("Cannot save ${file.name}")
            context.contentResolver.openOutputStream(target.uri, "wt")!!.use { output ->
                file.inputStream().use { it.copyTo(output) }
            }
        }
    }

    fun read(context: Context, tree: String, id: String, file: String): ByteArray {
        if (!Regex("^[A-Za-z0-9_.-]+$").matches(file)) throw FileNotFoundException("Invalid file")
        val target = root(context, tree).findFile(id)?.findFile(file)
            ?: throw FileNotFoundException("Downloaded file is missing")
        return context.contentResolver.openInputStream(target.uri)!!.use { it.readBytes() }
    }

    fun delete(context: Context, tree: String, id: String) {
        root(context, tree).findFile(id)?.delete()
    }
}
