package com.ptip.statushd

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer

/** Incremental H.264 sink for processed neural frames. Audio is intentionally
 * handled by the later mux stage; this class never pretends silent output has
 * preserved the source soundtrack. */
class NeuralVideoEncoder(private val output: File, private val width: Int, private val height: Int, private val frameRate: Int = 30) : AutoCloseable {
    private val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    private val muxer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private var track = -1
    private var started = false
    private val info = MediaCodec.BufferInfo()

    init {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(MediaFormat.KEY_BIT_RATE, (width * height * frameRate * 0.08).toInt().coerceIn(900_000, 18_000_000))
            setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
    }

    fun encode(bitmap: Bitmap, presentationTimeUs: Long) {
        val index = codec.dequeueInputBuffer(10_000)
        require(index >= 0) { "Video encoder input is busy." }
        val input = codec.getInputBuffer(index) ?: error("Encoder input buffer unavailable.")
        input.clear()
        input.put(toNv12(bitmap, width, height))
        codec.queueInputBuffer(index, 0, input.position(), presentationTimeUs, 0)
        drain(false)
    }

    fun finish() {
        val index = codec.dequeueInputBuffer(10_000)
        if (index >= 0) codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        drain(true)
    }

    private fun drain(end: Boolean) {
        while (true) {
            when (val index = codec.dequeueOutputBuffer(info, if (end) 10_000 else 0)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> if (!end) return else continue
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { track = muxer.addTrack(codec.outputFormat); muxer.start(); started = true }
                else -> if (index >= 0) {
                    val data = codec.getOutputBuffer(index)
                    if (data != null && info.size > 0 && started) { data.position(info.offset); data.limit(info.offset + info.size); muxer.writeSampleData(track, data, info) }
                    codec.releaseOutputBuffer(index, false)
                    if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
                }
            }
        }
    }

    override fun close() { try { if (started) muxer.stop() } catch (_: Exception) {}; muxer.release(); codec.stop(); codec.release() }

    private fun toNv12(bitmap: Bitmap, targetWidth: Int, targetHeight: Int): ByteArray {
        val frame = Bitmap.createScaledBitmap(bitmap, targetWidth, targetHeight, true)
        val result = ByteArray(targetWidth * targetHeight * 3 / 2)
        var yIndex = 0; var uvIndex = targetWidth * targetHeight
        for (y in 0 until targetHeight) for (x in 0 until targetWidth) {
            val color = frame.getPixel(x, y); val r = color shr 16 and 255; val g = color shr 8 and 255; val b = color and 255
            result[yIndex++] = ((66 * r + 129 * g + 25 * b + 128 shr 8) + 16).coerceIn(0, 255).toByte()
            if (y % 2 == 0 && x % 2 == 0) { result[uvIndex++] = ((-38 * r - 74 * g + 112 * b + 128 shr 8) + 128).coerceIn(0, 255).toByte(); result[uvIndex++] = ((112 * r - 94 * g - 18 * b + 128 shr 8) + 128).coerceIn(0, 255).toByte() }
        }
        frame.recycle(); return result
    }
}
