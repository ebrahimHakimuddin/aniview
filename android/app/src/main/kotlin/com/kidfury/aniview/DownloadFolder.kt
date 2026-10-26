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

    private fun folder(context: Context, tree: String, path: String, create: Boolean = false): DocumentFile {
        var current = root(context, tree)
        for (part in path.split('/')) {
            if (part.isBlank() || part == "." || part == ".." || '\\' in part) {
                throw FileNotFoundException("Invalid download folder")
            }
            current = current.findFile(part) ?: (if (create) current.createDirectory(part) else null)
                ?: throw FileNotFoundException("Download folder is unavailable")
            if (!current.isDirectory) throw FileNotFoundException("Download folder is not a directory")
        }
        return current
    }

    fun export(context: Context, tree: String, id: String, path: String) {
        val source = File(path)
        if (!source.isDirectory) throw FileNotFoundException("Download is incomplete")
        val folder = folder(context, tree, id, create = true)
        for (file in source.listFiles() ?: emptyArray()) {
            if (!file.isFile || file.name.endsWith(".part")) continue
            val target = folder.findFile(file.name) ?: folder.createFile(
                when {
                    file.name.endsWith(".mp4") -> "video/mp4"
                    file.name.endsWith(".m3u8") -> "application/vnd.apple.mpegurl"
                    else -> "application/octet-stream"
                },
                file.name,
            ) ?: throw FileNotFoundException("Cannot save ${file.name}")
            context.contentResolver.openOutputStream(target.uri, "wt")!!.use { output ->
                file.inputStream().use { it.copyTo(output) }
            }
        }
    }

    fun find(context: Context, tree: String, id: String, file: String): DocumentFile {
        if ('/' in file || file.startsWith('.')) throw FileNotFoundException("Invalid file")
        return folder(context, tree, id).findFile(file)
            ?: throw FileNotFoundException("Downloaded file is missing")
    }

    fun read(context: Context, tree: String, id: String, file: String): ByteArray =
        context.contentResolver.openInputStream(find(context, tree, id, file).uri)!!.use { it.readBytes() }

    fun delete(context: Context, tree: String, id: String) {
        folder(context, tree, id).delete()
    }
}
