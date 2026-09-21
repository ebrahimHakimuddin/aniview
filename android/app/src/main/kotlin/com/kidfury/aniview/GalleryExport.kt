package com.kidfury.aniview

import android.content.ContentValues
import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaMuxer
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.FileDescriptor
import java.nio.ByteBuffer
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Copies a downloaded episode (a local HLS playlist of MPEG-TS segments, maybe AES-128 encrypted) into
 * Movies/AniView as an MP4 so it shows up in the gallery. The segments are decrypted and joined into one file,
 * then remuxed into MP4 without re-encoding.
 */
// ponytail: MediaStore paths need Android 10+; older phones would need the storage permission flow
object GalleryExport {
    fun save(context: Context, dir: File, name: String) {
        if (Build.VERSION.SDK_INT < 29) throw IllegalStateException("Saving to the gallery needs Android 10 or newer")
        val joined = File(context.cacheDir, "gallery-${dir.name}.ts")
        try {
            join(dir, joined)
            val resolver = context.contentResolver
            val uri = resolver.insert(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                ContentValues().apply {
                    put(MediaStore.Video.Media.DISPLAY_NAME, "$name.mp4")
                    put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                    put(MediaStore.Video.Media.RELATIVE_PATH, "${Environment.DIRECTORY_MOVIES}/AniView")
                    put(MediaStore.Video.Media.IS_PENDING, 1)
                },
            ) ?: throw IllegalStateException("Couldn't create the gallery file")
            try {
                resolver.openFileDescriptor(uri, "rw")!!.use { remux(joined, it.fileDescriptor) }
                resolver.update(uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
        } finally {
            joined.delete()
        }
    }

    /** Writes the playlist's init map and segments into [out], decrypted, in order. */
    private fun join(dir: File, out: File) {
        val uri = Regex("URI=\"([^\"]+)\"")
        var key: ByteArray? = null
        var iv: ByteArray? = null
        var sequence = 0L
        out.outputStream().buffered().use { sink ->
            for (line in File(dir, "index.m3u8").readLines().map { it.trim() }) {
                when {
                    line.startsWith("#EXT-X-MEDIA-SEQUENCE:") -> sequence = line.substringAfter(':').toLong()
                    line.startsWith("#EXT-X-MAP:") -> sink.write(File(dir, uri.find(line)!!.groupValues[1]).readBytes())
                    line.startsWith("#EXT-X-KEY:") -> {
                        key = if ("METHOD=AES-128" in line) File(dir, uri.find(line)!!.groupValues[1]).readBytes() else null
                        iv = Regex("IV=0[xX]([0-9a-fA-F]+)").find(line)?.groupValues?.get(1)?.let { hex ->
                            hex.padStart(32, '0').takeLast(32).chunked(2).map { it.toInt(16).toByte() }.toByteArray()
                        }
                    }
                    line.isNotEmpty() && !line.startsWith("#") -> {
                        var bytes = File(dir, line).readBytes()
                        key?.let { k ->
                            // Without an explicit IV, HLS uses the segment's sequence number.
                            val segmentIv = iv ?: ByteBuffer.allocate(16).putLong(8, sequence).array()
                            bytes = Cipher.getInstance("AES/CBC/PKCS5Padding").run {
                                init(Cipher.DECRYPT_MODE, SecretKeySpec(k, "AES"), IvParameterSpec(segmentIv))
                                doFinal(bytes)
                            }
                        }
                        sink.write(bytes)
                        sequence++
                    }
                }
            }
        }
    }

    private fun remux(input: File, output: FileDescriptor) {
        val extractor = MediaExtractor().apply { setDataSource(input.path) }
        val muxer = MediaMuxer(output, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        try {
            // Audio and video only; TS files can carry ID3 metadata tracks that MP4 can't take.
            val tracks = (0 until extractor.trackCount).filter { i ->
                val mime = extractor.getTrackFormat(i).getString(android.media.MediaFormat.KEY_MIME) ?: ""
                mime.startsWith("video/") || mime.startsWith("audio/")
            }.associateWith { i ->
                extractor.selectTrack(i)
                muxer.addTrack(extractor.getTrackFormat(i))
            }
            muxer.start()
            val buffer = ByteBuffer.allocate(4 shl 20)
            val info = MediaCodec.BufferInfo()
            var start = -1L // TS timestamps rarely start at zero
            while (true) {
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                if (start < 0) start = extractor.sampleTime
                val keyFrame = extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0
                info.set(
                    0,
                    size,
                    maxOf(0L, extractor.sampleTime - start),
                    if (keyFrame) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0,
                )
                muxer.writeSampleData(tracks.getValue(extractor.sampleTrackIndex), buffer, info)
                extractor.advance()
            }
            muxer.stop()
        } finally {
            muxer.release()
            extractor.release()
        }
    }
}
