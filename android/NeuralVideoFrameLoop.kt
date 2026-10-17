package com.ptip.statushd

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/** Incremental decoded-frame loop for neural processing. Frames are never
 * accumulated in memory: each decoded frame is transformed and handed to the
 * encoder sink before the next frame is requested. */
class NeuralVideoFrameLoop(
    private val engine: SuperResolutionEngine,
    private val cancelled: AtomicBoolean = AtomicBoolean(false),
) {
    data class Frame(val timestampUs: Long, val bitmap: Bitmap)

    fun process(
        inputPath: String,
        outputWidth: Int,
        outputHeight: Int,
        onFrame: (Frame) -> Unit,
        onProgress: (Long, Long) -> Unit,
    ) {
        require(File(inputPath).isFile) { "Source video is unavailable." }
        require(outputWidth > 0 && outputHeight > 0) { "Invalid neural output dimensions." }
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(inputPath)
            val durationUs = (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_DURATION)?.toLongOrNull() ?: 0L) * 1000L
            val frameRate = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)?.toDoubleOrNull()?.coerceIn(1.0, 120.0) ?: 30.0
            val stepUs = (1_000_000.0 / frameRate).toLong().coerceAtLeast(1L)
            var timestampUs = 0L
            while (timestampUs <= durationUs && !cancelled.get()) {
                val source = retriever.getFrameAtTime(timestampUs, MediaMetadataRetriever.OPTION_CLOSEST)
                if (source != null) {
                    val output = engine.upscaleFrame(source, outputWidth, outputHeight)
                    source.recycle()
                    onFrame(Frame(timestampUs, output))
                    output.recycle()
                }
                onProgress(timestampUs, durationUs)
                timestampUs += stepUs
            }
            if (cancelled.get()) throw InterruptedException("Neural processing cancelled.")
        } finally {
            retriever.release()
        }
    }

    fun cancel() { cancelled.set(true) }
}
