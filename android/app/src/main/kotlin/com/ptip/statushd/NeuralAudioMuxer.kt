package com.ptip.statushd

import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer

/** Muxes the encoded neural video with the original audio track. The source
 * remains untouched; the final file is written to a new path. */
object NeuralAudioMuxer {
    fun mux(videoPath: String, sourcePath: String, outputPath: String) {
        val video = MediaExtractor()
        val audio = MediaExtractor()
        video.setDataSource(videoPath)
        audio.setDataSource(sourcePath)
        val output = File(outputPath)
        output.parentFile?.mkdirs()
        if (output.exists()) output.delete()
        val muxer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        try {
            val videoTrack = findTrack(video, true)
            require(videoTrack >= 0) { "Neural video track is unavailable." }
            val outputVideo = muxer.addTrack(video.getTrackFormat(videoTrack))
            val audioTrack = findTrack(audio, false)
            val outputAudio = if (audioTrack >= 0) muxer.addTrack(audio.getTrackFormat(audioTrack)) else -1
            muxer.start()
            copyTrack(video, videoTrack, outputVideo, muxer)
            if (audioTrack >= 0) copyTrack(audio, audioTrack, outputAudio, muxer)
        } finally {
            try { muxer.stop() } catch (_: Exception) {}
            muxer.release()
            video.release()
            audio.release()
        }
        require(output.isFile && output.length() > 0) { "Muxed output is empty." }
    }

    private fun findTrack(extractor: MediaExtractor, video: Boolean): Int {
        for (index in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith(if (video) "video/" else "audio/")) return index
        }
        return -1
    }

    private fun copyTrack(extractor: MediaExtractor, track: Int, outputTrack: Int, muxer: MediaMuxer) {
        extractor.selectTrack(track)
        val buffer = ByteBuffer.allocate(1024 * 1024)
        val info = android.media.MediaCodec.BufferInfo()
        while (true) {
            buffer.clear()
            val size = extractor.readSampleData(buffer, 0)
            if (size < 0) break
            info.offset = 0
            info.size = size
            info.presentationTimeUs = extractor.sampleTime
            info.flags = extractor.sampleFlags
            muxer.writeSampleData(outputTrack, buffer, info)
            extractor.advance()
        }
    }
}
