package com.ptip.statushd

import android.media.MediaMetadataRetriever
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/** End-to-end orchestration for neural video output. */
class NeuralVideoProcessor(private val engine: SuperResolutionEngine) {
    fun process(inputPath: String, outputPath: String, outputWidth: Int, outputHeight: Int, onProgress: (Double) -> Unit = {}): File {
        val retriever = MediaMetadataRetriever()
        retriever.setDataSource(inputPath)
        val fps = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)?.toDoubleOrNull()?.toInt()?.coerceIn(1, 120) ?: 30
        retriever.release()
        val silent = File.createTempFile("statushd_neural_", ".mp4")
        val encoder = NeuralVideoEncoder(silent, outputWidth, outputHeight, fps)
        try {
            NeuralVideoFrameLoop(engine).process(inputPath, outputWidth, outputHeight, { frame ->
                encoder.encode(frame.bitmap, frame.timestampUs)
            }, { position, duration -> if (duration > 0) onProgress((position.toDouble() / duration).coerceIn(0.0, 1.0)) })
            encoder.finish()
        } finally { encoder.close() }
        NeuralAudioMuxer.mux(silent.absolutePath, inputPath, outputPath)
        silent.delete()
        return File(outputPath)
    }
}
