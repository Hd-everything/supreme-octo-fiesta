package com.ptip.statushd

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.FileInputStream
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer

class MainActivity : FlutterActivity() {
    private val channelName = "com.ptip.statushd/media"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            if (call.method == "saveVideoToGallery") {
                val inputPath = call.argument<String>("inputPath")
                val displayName = call.argument<String>("displayName") ?: "StatusHD_${System.currentTimeMillis()}.mp4"
                if (inputPath.isNullOrBlank() || !File(inputPath).isFile) {
                    result.error("invalid_input", "The exported video could not be found.", null)
                    return@setMethodCallHandler
                }
                Thread {
                    try {
                        val uri = saveVideoToGallery(inputPath, displayName)
                        runOnUiThread { result.success(uri.toString()) }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("save_failed", error.message ?: "Could not save the video to Gallery.", null) }
                    }
                }.start()
                return@setMethodCallHandler
            }
            if (call.method != "trimVideo") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val inputPath = call.argument<String>("inputPath")
            val outputPath = call.argument<String>("outputPath")
            val startMs = call.argument<Number>("startMs")?.toLong()
            val endMs = call.argument<Number>("endMs")?.toLong()
            if (inputPath == null || outputPath == null || startMs == null || endMs == null || endMs <= startMs) {
                result.error("invalid_arguments", "Invalid video trim range.", null)
                return@setMethodCallHandler
            }
            Thread {
                try {
                    trimVideo(inputPath, outputPath, startMs * 1000, endMs * 1000)
                    runOnUiThread { result.success(outputPath) }
                } catch (error: Exception) {
                    File(outputPath).delete()
                    runOnUiThread { result.error("trim_failed", error.message ?: "Video trimming failed.", null) }
                }
            }.start()
        }
    }

    private fun saveVideoToGallery(inputPath: String, displayName: String): android.net.Uri {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw IllegalStateException("Saving directly to Gallery requires Android 10 or newer. Use Share to save this export instead.")
        }
        val safeName = displayName
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
            .let { if (it.endsWith(".mp4", ignoreCase = true)) it else "$it.mp4" }
        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, safeName)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Status HD")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("Android could not create a Gallery entry.")
        try {
            resolver.openOutputStream(uri, "w")?.use { output ->
                FileInputStream(inputPath).use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("Android could not open the Gallery output.")
            val published = ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }
            resolver.update(uri, published, null, null)
            return uri
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    private fun trimVideo(inputPath: String, outputPath: String, startUs: Long, endUs: Long) {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            extractor.setDataSource(inputPath)
            val formats = mutableListOf<MediaFormat>()
            val sourceTracks = mutableListOf<Int>()
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/") || mime.startsWith("audio/")) {
                    sourceTracks.add(i)
                    formats.add(format)
                }
            }
            if (sourceTracks.none { (extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME) ?: "").startsWith("video/") }) {
                throw IllegalArgumentException("No video track was found.")
            }
            File(outputPath).parentFile?.mkdirs()
            File(outputPath).delete()
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val trackMap = mutableMapOf<Int, Int>()
            sourceTracks.forEachIndexed { index, sourceTrack ->
                extractor.selectTrack(sourceTrack)
                trackMap[sourceTrack] = muxer.addTrack(formats[index])
            }
            muxer.start()
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val maxSampleSize = formats.mapNotNull { format ->
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else null
            }.maxOrNull() ?: 0
            val buffer = ByteBuffer.allocate(maxOf(4 * 1024 * 1024, maxSampleSize))
            val info = MediaCodec.BufferInfo()
            var copied = 0
            while (true) {
                val track = extractor.sampleTrackIndex
                if (track < 0) break
                val time = extractor.sampleTime
                if (time < 0 || time >= endUs) break
                if (time >= startUs && trackMap.containsKey(track)) {
                    buffer.clear()
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) break
                    info.offset = 0
                    info.size = size
                    info.presentationTimeUs = time - startUs
                    info.flags = extractor.sampleFlags
                    muxer.writeSampleData(trackMap[track]!!, buffer, info)
                    copied++
                }
                if (!extractor.advance()) break
            }
            if (copied == 0) throw IllegalArgumentException("No samples in the selected range. Try a nearby start time.")
            muxer.stop()
        } finally {
            try { muxer?.release() } catch (_: Exception) {}
            extractor.release()
        }
    }
}
