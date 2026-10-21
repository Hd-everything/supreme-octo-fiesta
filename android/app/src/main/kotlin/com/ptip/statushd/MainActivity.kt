package com.ptip.statushd

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.effect.Brightness
import androidx.media3.effect.Contrast
import androidx.media3.effect.Crop
import androidx.media3.transformer.Effects
import androidx.media3.effect.HslAdjustment
import androidx.media3.effect.LanczosResample
import androidx.media3.effect.ConvolutionFunction1D
import androidx.media3.effect.SeparableConvolution
import androidx.media3.effect.Presentation
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.TextOverlay
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.TextureOverlay
import android.text.style.AbsoluteSizeSpan
import android.text.SpannableString
import android.text.style.ForegroundColorSpan
import android.graphics.Color
import android.graphics.BitmapFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Composition
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import android.content.ContentValues
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Environment
import android.provider.MediaStore
import java.io.FileInputStream
import java.io.ByteArrayOutputStream
import kotlin.math.abs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer

@UnstableApi
private class DetailSharpenEffect(private val amount: Float = 0.22f) : SeparableConvolution() {
    override fun getConvolution(presentationTimeUs: Long): ConvolutionFunction1D =
        object : ConvolutionFunction1D {
            override fun domainStart(): Float = -1f
            override fun domainEnd(): Float = 1f
            override fun value(samplePosition: Float): Float {
                val distance = abs(samplePosition)
                return when {
                    distance < 0.25f -> 1f + 2f * amount
                    distance > 0.75f -> -amount
                    else -> 0f
                }
            }
        }
}

@UnstableApi
class MainActivity : FlutterActivity() {
    private val channelName = "com.ptip.statushd/media"
    private var pendingVideoLibraryResult: MethodChannel.Result? = null
    private var pendingMediaLibraryResult: MethodChannel.Result? = null
    private val videoLibraryRequestCode = 7001
    private val mediaLibraryRequestCode = 7002
    private var activeTransformer: Transformer? = null
    private var superResolutionEngine: SuperResolutionEngine? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val mediaChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        mediaChannel.setMethodCallHandler { call, result ->
            if (call.method == "neuralSuperResolutionCapability") {
                Thread {
                    val capability = try {
                        (superResolutionEngine ?: synchronized(this) {
                            superResolutionEngine ?: SuperResolutionEngine(this).also { superResolutionEngine = it }
                        }).capability()
                    } catch (error: Exception) {
                        mapOf("ready" to false, "reason" to (error.message ?: "model_initialization_failed"))
                    }
                    runOnUiThread { result.success(capability) }
                }.start()
                return@setMethodCallHandler
            }
            if (call.method == "inspectVideo") {
                val path = call.argument<String>("inputPath")
                if (path.isNullOrBlank() || !File(path).isFile) {
                    result.error("invalid_video", "Choose a readable video file.", null)
                    return@setMethodCallHandler
                }
                try {
                    result.success(inspectVideo(path))
                } catch (error: Exception) {
                    result.error("metadata_failed", error.message ?: "Could not inspect this video.", null)
                }
                return@setMethodCallHandler
            }
            if (call.method == "videoThumbnail") {
                val path = call.argument<String>("path")
                val timeMs = call.argument<Long>("timeMs") ?: 1000L
                if (path.isNullOrBlank() || !File(path).isFile) { result.success(null); return@setMethodCallHandler }
                Thread {
                    val bytes = try {
                        val retriever = MediaMetadataRetriever()
                        try {
                            retriever.setDataSource(path)
                            val bitmap = retriever.getFrameAtTime(timeMs.coerceAtLeast(0) * 1000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                            bitmap?.let { frame ->
                                try { ByteArrayOutputStream().use { stream -> frame.compress(android.graphics.Bitmap.CompressFormat.JPEG, 76, stream); stream.toByteArray() } }
                                finally { frame.recycle() }
                            }
                        } finally { retriever.release() }
                    } catch (_: Exception) { null }
                    runOnUiThread { result.success(bytes) }
                }.start()
                return@setMethodCallHandler
            }
            if (call.method == "cancelProcessing") {
                val transformer = activeTransformer
                if (transformer == null) result.success(false)
                else {
                    transformer.cancel()
                    activeTransformer = null
                    result.success(true)
                }
                return@setMethodCallHandler
            }
            if (call.method == "processVideo") {
                val inputPath = call.argument<String>("inputPath")
                val outputPath = call.argument<String>("outputPath")
                val operation = call.argument<String>("operation")
                val reportProgress = call.argument<Boolean>("reportProgress") == true
                if (inputPath.isNullOrBlank() || outputPath.isNullOrBlank() || !File(inputPath).isFile || (operation != "enhance" && operation != "crop")) {
                    result.error("invalid_arguments", "Choose a valid source and output configuration.", null)
                    return@setMethodCallHandler
                }
                if (activeTransformer != null) {
                    result.error("processing_busy", "Another video is already processing.", null)
                    return@setMethodCallHandler
                }
                val source = try { inspectVideo(inputPath) } catch (error: Exception) {
                    result.error("metadata_failed", error.message ?: "Could not inspect this video.", null)
                    return@setMethodCallHandler
                }
                val outputWidth: Int
                val outputHeight: Int
                val effects = mutableListOf<androidx.media3.common.Effect>()
                if (operation == "enhance") {
                    outputWidth = call.argument<Number>("outputWidth")?.toInt() ?: 0
                    outputHeight = call.argument<Number>("outputHeight")?.toInt() ?: 0
                    val brightness = (call.argument<Number>("brightness")?.toFloat() ?: 0f).coerceIn(-0.25f, 0.25f)
                    val contrast = (call.argument<Number>("contrast")?.toFloat() ?: 0f).coerceIn(-0.3f, 0.3f)
                    val saturation = (call.argument<Number>("saturation")?.toFloat() ?: 0f).coerceIn(-20f, 30f)
                    val sharpness = (call.argument<Number>("sharpness")?.toFloat() ?: 0.22f).coerceIn(0f, 0.5f)
                    if (outputWidth < 2 || outputHeight < 2 || outputWidth > 4096 || outputHeight > 4096) {
                        result.error("unsupported_output", "This output size is not supported on this device.", null)
                        return@setMethodCallHandler
                    }
                    val cropRatio = call.argument<Number>("cropAspectRatio")?.toDouble() ?: 0.0
                    if (cropRatio > 0.0) {
                        val sourceWidth = source["width"] as Int
                        val sourceHeight = source["height"] as Int
                        val sourceRatio = sourceWidth.toDouble() / sourceHeight.toDouble()
                        val cropX = (call.argument<Number>("cropX")?.toFloat() ?: 0f).coerceIn(0f, 1f)
                        val cropY = (call.argument<Number>("cropY")?.toFloat() ?: 0f).coerceIn(0f, 1f)
                        val cropWidth = (call.argument<Number>("cropWidth")?.toFloat() ?: 1f).coerceIn(0.01f, 1f - cropX)
                        val cropHeight = (call.argument<Number>("cropHeight")?.toFloat() ?: 1f).coerceIn(0.01f, 1f - cropY)
                        if (kotlin.math.abs(sourceRatio - cropRatio) > 0.0001 || cropX > 0f || cropY > 0f || cropWidth < 0.9999f || cropHeight < 0.9999f) {
                            effects.add(Crop(cropX * 2f - 1f, (cropX + cropWidth) * 2f - 1f, 1f - (cropY + cropHeight) * 2f, 1f - cropY * 2f))
                        }
                    }
                    effects.addAll(listOf(Brightness(brightness), Contrast(contrast), HslAdjustment.Builder().adjustSaturation(saturation).build(), DetailSharpenEffect(sharpness), LanczosResample.scaleToFit(outputWidth, outputHeight), Presentation.createForWidthAndHeight(outputWidth, outputHeight, Presentation.LAYOUT_SCALE_TO_FIT)))
                    if (call.argument<Boolean>("watermark") != false) {
                        val label = SpannableString("Vyntra")
                        label.setSpan(ForegroundColorSpan(Color.WHITE), 0, label.length, android.text.Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                        effects.add(OverlayEffect(listOf(TextOverlay.createStaticTextOverlay(label))))
                    }
                } else {
                    val ratio = call.argument<Number>("cropAspectRatio")?.toDouble() ?: 0.0
                    val sourceWidth = source["width"] as Int
                    val sourceHeight = source["height"] as Int
                    val sourceRatio = sourceWidth.toDouble() / sourceHeight.toDouble()
                    val targetRatio = if (ratio > 0.0) ratio else sourceRatio
                    if (targetRatio <= 0.0) {
                        result.error("invalid_crop", "Choose a valid crop ratio.", null)
                        return@setMethodCallHandler
                    }
                    if (sourceRatio >= targetRatio) {
                        outputHeight = source["height"] as Int
                        outputWidth = (outputHeight * targetRatio).toInt().coerceAtLeast(2)
                    } else {
                        outputWidth = source["width"] as Int
                        outputHeight = (outputWidth / targetRatio).toInt().coerceAtLeast(2)
                    }
                    val cropX = (call.argument<Number>("cropX")?.toFloat() ?: 0f).coerceIn(0f, 1f)
                    val cropY = (call.argument<Number>("cropY")?.toFloat() ?: 0f).coerceIn(0f, 1f)
                    val cropWidth = (call.argument<Number>("cropWidth")?.toFloat() ?: 1f).coerceIn(0.01f, 1f - cropX)
                    val cropHeight = (call.argument<Number>("cropHeight")?.toFloat() ?: 1f).coerceIn(0.01f, 1f - cropY)
                    // Media3 Crop uses normalized device coordinates. This crops encoded
                    // frames before scaling and leaves the audio stream synchronized.
                    effects.add(Crop(cropX * 2f - 1f, (cropX + cropWidth) * 2f - 1f, 1f - (cropY + cropHeight) * 2f, 1f - cropY * 2f))
                    effects.add(Presentation.createForWidthAndHeight(outputWidth, outputHeight, Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP))
                }
                val outputFile = File(outputPath)
                outputFile.parentFile?.mkdirs()
                outputFile.delete()
                val startMs = call.argument<Number>("startMs")?.toLong()
                val endMs = call.argument<Number>("endMs")?.toLong()
                val durationMs = source["durationMs"] as Long
                val invalidTrim = when {
                    startMs == null && endMs == null -> false
                    startMs == null || endMs == null -> true
                    else -> startMs < 0 || endMs <= startMs || endMs > durationMs
                }
                if (invalidTrim) {
                    result.error("invalid_trim", "Choose a valid video trim range.", null)
                    return@setMethodCallHandler
                }
                val mediaItemBuilder = MediaItem.Builder().setUri(Uri.fromFile(File(inputPath)))
                if (startMs != null && endMs != null) {
                    mediaItemBuilder.setClippingConfiguration(MediaItem.ClippingConfiguration.Builder().setStartPositionMs(startMs).setEndPositionMs(endMs).build())
                }
                val item = EditedMediaItem.Builder(mediaItemBuilder.build()).setEffects(Effects(emptyList(), effects)).build()
                val progressHandler = Handler(Looper.getMainLooper())
                val progressHolder = ProgressHolder()
                lateinit var transformer: Transformer
                lateinit var progressPoll: Runnable
                progressPoll = object : Runnable {
                    override fun run() {
                        if (activeTransformer !== transformer) return
                        if (transformer.getProgress(progressHolder) == Transformer.PROGRESS_STATE_AVAILABLE) {
                            mediaChannel.invokeMethod("processingProgress", progressHolder.progress)
                        }
                        progressHandler.postDelayed(this, 500)
                    }
                }
                transformer = Transformer.Builder(this).setVideoMimeType(MimeTypes.VIDEO_H264).setAudioMimeType(MimeTypes.AUDIO_AAC).addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: androidx.media3.transformer.Composition, exportResult: ExportResult) {
                        progressHandler.removeCallbacks(progressPoll)
                        activeTransformer = null
                        if (reportProgress) mediaChannel.invokeMethod("processingProgress", 100)
                        if (outputFile.isFile && outputFile.length() > 0L) result.success(mapOf("path" to outputFile.absolutePath))
                        else { outputFile.delete(); result.error("output_missing", "Processing completed without a usable output file.", null) }
                    }
                    override fun onError(composition: androidx.media3.transformer.Composition, exportResult: ExportResult, exportException: ExportException) {
                        progressHandler.removeCallbacks(progressPoll)
                        activeTransformer = null
                        outputFile.delete()
                        result.error("processing_failed", exportException.message ?: "This device could not process the video.", null)
                    }
                }).build()
                activeTransformer = transformer
                try {
                    transformer.start(item, outputFile.absolutePath)
                    if (reportProgress) progressHandler.post(progressPoll)
                }
                catch (error: Exception) { activeTransformer = null; outputFile.delete(); result.error("processing_start_failed", error.message ?: "Could not start processing.", null) }
                return@setMethodCallHandler
            }
            if (call.method == "exportProject") {
                val outputPath = call.argument<String>("outputPath")
                val rawClips = call.argument<List<Map<String, Any>>>("clips")
                val reportProgress = call.argument<Boolean>("reportProgress") == true
                if (outputPath.isNullOrBlank() || rawClips.isNullOrEmpty() || rawClips.size > 24) {
                    result.error("invalid_project", "Choose a project with 1 to 24 video clips.", null)
                    return@setMethodCallHandler
                }
                if (activeTransformer != null) {
                    result.error("processing_busy", "Another video is already processing.", null)
                    return@setMethodCallHandler
                }
                val rawOverlays = call.argument<List<Map<String, Any>>>("overlays") ?: emptyList()
                val rawImageOverlays = call.argument<List<Map<String, Any>>>("imageOverlays") ?: emptyList()
                val outputRatio = call.argument<String>("aspectRatio") ?: "Original"
                val musicPath = call.argument<String>("musicPath")
                val musicVolume = (call.argument<Number>("musicVolume")?.toFloat() ?: 0.35f).coerceIn(0f, 1f)
                val musicOffsetMs = (call.argument<Number>("musicOffsetMs")?.toLong() ?: 0L).coerceAtLeast(0L)
                val editedItems = try {
                    val resultItems = mutableListOf<EditedMediaItem>()
                    if (rawImageOverlays.size > 8) throw IllegalArgumentException("A project can contain up to eight image overlays.")
                    val overlayBitmapCache = mutableMapOf<String, android.graphics.Bitmap>()
                    var timelineStartMs = 0L
                    rawClips.forEach { clip ->
                        val path = clip["path"]?.toString() ?: throw IllegalArgumentException("A project clip has no source path.")
                        if (!File(path).isFile) throw IllegalArgumentException("A project source file is no longer available: ${File(path).name}")
                        val startMs = (clip["startMs"] as? Number)?.toLong() ?: 0L
                        val endMs = (clip["endMs"] as? Number)?.toLong() ?: 0L
                        val durationMs = (inspectVideo(path)["durationMs"] as Number).toLong()
                        if (startMs < 0 || endMs <= startMs || endMs > durationMs) throw IllegalArgumentException("A project clip has an invalid trim range.")
                        val clipLengthMs = endMs - startMs
                        val boundaries = mutableSetOf(0L, clipLengthMs)
                        rawOverlays.forEach { overlay ->
                            val overlayStart = (overlay["startMs"] as? Number)?.toLong() ?: 0L
                            val overlayEnd = (overlay["endMs"] as? Number)?.toLong() ?: 0L
                            listOf(overlayStart, overlayEnd).forEach { boundary ->
                                val local = boundary - timelineStartMs
                                if (local > 0L && local < clipLengthMs) boundaries.add(local)
                            }
                        }
                        rawImageOverlays.forEach { overlay ->
                            val overlayStart = (overlay["startMs"] as? Number)?.toLong() ?: 0L
                            val overlayEnd = (overlay["endMs"] as? Number)?.toLong() ?: 0L
                            listOf(overlayStart, overlayEnd).forEach { boundary ->
                                val local = boundary - timelineStartMs
                                if (local > 0L && local < clipLengthMs) boundaries.add(local)
                            }
                        }
                        val orderedBoundaries = boundaries.sorted()
                        val rotation = ((clip["rotation"] as? Number)?.toInt() ?: 0).let { ((it % 360) + 360) % 360 }
                        val sourceVolume = (clip["volume"] as? Number)?.toFloat()?.coerceIn(0f, 1f) ?: 1f
                        val brightness = (clip["brightness"] as? Number)?.toFloat()?.coerceIn(-0.25f, 0.25f) ?: 0f
                        val contrast = (clip["contrast"] as? Number)?.toFloat()?.coerceIn(-0.3f, 0.3f) ?: 0f
                        val saturation = (clip["saturation"] as? Number)?.toFloat()?.coerceIn(-20f, 30f) ?: 0f
                        for (segmentIndex in 0 until orderedBoundaries.lastIndex) {
                            val localStartMs = orderedBoundaries[segmentIndex]
                            val localEndMs = orderedBoundaries[segmentIndex + 1]
                            val globalStartMs = timelineStartMs + localStartMs
                            val globalEndMs = timelineStartMs + localEndMs
                            val effects = mutableListOf<androidx.media3.common.Effect>()
                            if (rotation != 0) effects.add(ScaleAndRotateTransformation.Builder().setRotationDegrees(rotation.toFloat()).build())
                            when (outputRatio) {
                                "9:16" -> effects.add(Presentation.createForWidthAndHeight(1080, 1920, Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP))
                                "16:9" -> effects.add(Presentation.createForWidthAndHeight(1920, 1080, Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP))
                                "1:1" -> effects.add(Presentation.createForWidthAndHeight(1080, 1080, Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP))
                                "4:5" -> effects.add(Presentation.createForWidthAndHeight(1080, 1350, Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP))
                            }
                            if (brightness != 0f) effects.add(Brightness(brightness))
                            if (contrast != 0f) effects.add(Contrast(contrast))
                            if (saturation != 0f) effects.add(HslAdjustment.Builder().adjustSaturation(saturation).build())
                            val overlays = rawOverlays.filter { overlay ->
                                val overlayStart = (overlay["startMs"] as? Number)?.toLong() ?: 0L
                                val overlayEnd = (overlay["endMs"] as? Number)?.toLong() ?: 0L
                                overlayStart < globalEndMs && overlayEnd > globalStartMs
                            }.map { overlay ->
                                val text = SpannableString(overlay["text"]?.toString().orEmpty())
                                if (text.isNotEmpty()) {
                                    text.setSpan(ForegroundColorSpan((overlay["color"] as? Number)?.toInt() ?: Color.WHITE), 0, text.length, android.text.Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                                    text.setSpan(AbsoluteSizeSpan(((overlay["fontSize"] as? Number)?.toInt() ?: 34).coerceIn(16, 96)), 0, text.length, android.text.Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                                }
                                val x = (overlay["x"] as? Number)?.toFloat()?.coerceIn(-1f, 1f) ?: 0f
                                val y = (overlay["y"] as? Number)?.toFloat()?.coerceIn(-1f, 1f) ?: 0.55f
                                TextOverlay.createStaticTextOverlay(text, StaticOverlaySettings.Builder()
                                    .setBackgroundFrameAnchor(x, 1f - y * 2f)
                                    .setOverlayFrameAnchor(0f, 0f)
                                    .build())
                            }
                            if (overlays.isNotEmpty()) effects.add(OverlayEffect(overlays))
                            val activeImages = rawImageOverlays.filter { overlay ->
                                val overlayStart = (overlay["startMs"] as? Number)?.toLong() ?: 0L
                                val overlayEnd = (overlay["endMs"] as? Number)?.toLong() ?: 0L
                                overlayStart < globalEndMs && overlayEnd > globalStartMs
                            }.mapNotNull { overlay ->
                                val imagePath = overlay["path"]?.toString() ?: return@mapNotNull null
                                if (!File(imagePath).isFile) throw IllegalArgumentException("A project image overlay is no longer available.")
                                val bitmap = overlayBitmapCache.getOrPut(imagePath) {
                                    val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                                    BitmapFactory.decodeFile(imagePath, options)
                                    var sampleSize = 1
                                    while (options.outWidth / sampleSize > 1280 || options.outHeight / sampleSize > 1280) sampleSize *= 2
                                    BitmapFactory.decodeFile(imagePath, BitmapFactory.Options().apply { inSampleSize = sampleSize })
                                        ?: throw IllegalArgumentException("Could not decode a project image overlay.")
                                }
                                val scale = ((overlay["scale"] as? Number)?.toFloat() ?: 0.28f).coerceIn(0.05f, 1f)
                                val x = ((overlay["x"] as? Number)?.toFloat() ?: 0.65f).coerceIn(0f, 1f) * 2f - 1f
                                val y = 1f - ((overlay["y"] as? Number)?.toFloat() ?: 0.55f).coerceIn(0f, 1f) * 2f
                                BitmapOverlay.createStaticBitmapOverlay(bitmap, StaticOverlaySettings.Builder()
                                    .setBackgroundFrameAnchor(x, y)
                                    .setOverlayFrameAnchor(0f, 0f)
                                    .setScale(scale, scale)
                                    .build())
                            }
                            if (activeImages.isNotEmpty()) effects.add(OverlayEffect(activeImages))
                            val mediaItem = MediaItem.Builder()
                                .setUri(Uri.fromFile(File(path)))
                                .setClippingConfiguration(MediaItem.ClippingConfiguration.Builder()
                                    .setStartPositionMs(startMs + localStartMs)
                                    .setEndPositionMs(startMs + localEndMs)
                                    .build())
                                .build()
                            val processors = if (sourceVolume == 1f) emptyList() else channelGainProcessors(sourceVolume)
                            resultItems.add(EditedMediaItem.Builder(mediaItem).setRemoveAudio(sourceVolume == 0f).setEffects(Effects(processors, effects)).build())
                        }
                        timelineStartMs += clipLengthMs
                    }
                    if (musicPath != null && musicPath.isNotBlank() && !File(musicPath).isFile) throw IllegalArgumentException("The selected music file is no longer available.")
                    resultItems
                } catch (error: Exception) {
                    result.error("invalid_project_clip", error.message ?: "Could not read a project clip.", null)
                    return@setMethodCallHandler
                }
                val outputFile = File(outputPath)
                outputFile.parentFile?.mkdirs()
                outputFile.delete()
                val videoSequence = EditedMediaItemSequence(editedItems)
                val composition = if (musicPath.isNullOrBlank()) {
                    Composition.Builder(videoSequence).build()
                } else {
                    val audioItem = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(musicPath))))
                        .setEffects(Effects(channelGainProcessors(musicVolume), emptyList()))
                        .build()
                    val audioSequenceBuilder = EditedMediaItemSequence.Builder(emptyList<EditedMediaItem>())
                    if (musicOffsetMs > 0L) audioSequenceBuilder.addGap(musicOffsetMs * 1000L)
                    audioSequenceBuilder.addItem(audioItem).setIsLooping(true)
                    Composition.Builder(videoSequence, audioSequenceBuilder.build()).build()
                }
                val progressHandler = Handler(Looper.getMainLooper())
                val progressHolder = ProgressHolder()
                lateinit var transformer: Transformer
                lateinit var progressPoll: Runnable
                progressPoll = object : Runnable {
                    override fun run() {
                        if (activeTransformer !== transformer) return
                        if (transformer.getProgress(progressHolder) == Transformer.PROGRESS_STATE_AVAILABLE) {
                            mediaChannel.invokeMethod("processingProgress", progressHolder.progress)
                        }
                        progressHandler.postDelayed(this, 500)
                    }
                }
                transformer = Transformer.Builder(this)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                            progressHandler.removeCallbacks(progressPoll)
                            activeTransformer = null
                            if (reportProgress) mediaChannel.invokeMethod("processingProgress", 100)
                            if (outputFile.isFile && outputFile.length() > 0L) result.success(mapOf("path" to outputFile.absolutePath))
                            else { outputFile.delete(); result.error("output_missing", "Project export completed without a usable file.", null) }
                        }
                        override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                            progressHandler.removeCallbacks(progressPoll)
                            activeTransformer = null
                            outputFile.delete()
                            result.error("project_export_failed", exportException.message ?: "This device could not export the project.", null)
                        }
                    }).build()
                activeTransformer = transformer
                try {
                    transformer.start(composition, outputFile.absolutePath)
                    if (reportProgress) progressHandler.post(progressPoll)
                } catch (error: Exception) {
                    activeTransformer = null
                    outputFile.delete()
                    result.error("project_export_start_failed", error.message ?: "Could not start project export.", null)
                }
                return@setMethodCallHandler
            }
            if (call.method == "processNeuralVideo") {
                val inputPath = call.argument<String>("inputPath")
                val outputPath = call.argument<String>("outputPath")
                val width = call.argument<Int>("outputWidth") ?: 0
                val height = call.argument<Int>("outputHeight") ?: 0
                val reportProgress = call.argument<Boolean>("reportProgress") == true
                if (inputPath.isNullOrBlank() || outputPath.isNullOrBlank() || !File(inputPath).isFile || width < 2 || height < 2) {
                    result.error("invalid_neural_arguments", "Choose a valid source and neural output size.", null)
                    return@setMethodCallHandler
                }
                Thread {
                    try {
                        val engine = superResolutionEngine ?: SuperResolutionEngine(this).also { superResolutionEngine = it }
                        val output = NeuralVideoProcessor(engine).process(inputPath, outputPath, width, height) { progress ->
                            if (reportProgress) runOnUiThread {
                                MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).invokeMethod("processingProgress", (progress * 100).toInt())
                            }
                        }
                        runOnUiThread { result.success(mapOf("path" to output.absolutePath, "neural" to true, "scale" to 3)) }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("neural_processing_failed", error.message ?: "Neural processing failed.", null) }
                    }
                }.start()
                return@setMethodCallHandler
            }
            if (call.method == "getVideoDimensions") {
                val path = call.argument<String>("path")
                if (path.isNullOrBlank() || !File(path).isFile) {
                    result.error("invalid_video", "Choose a readable video file.", null)
                    return@setMethodCallHandler
                }
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(path)
                    var width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                    var height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                    val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                    if (rotation == 90 || rotation == 270) {
                        val swap = width
                        width = height
                        height = swap
                    }
                    if (width < 2 || height < 2) {
                        result.error("invalid_dimensions", "Could not detect this video's dimensions.", null)
                    } else {
                        result.success(mapOf("width" to width, "height" to height))
                    }
                } catch (error: Exception) {
                    result.error("metadata_failed", error.message ?: "Could not read video dimensions.", null)
                } finally {
                    retriever.release()
                }
                return@setMethodCallHandler
            }
            if (call.method == "listDeviceVideos") {
                val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    android.Manifest.permission.READ_MEDIA_VIDEO
                } else {
                    android.Manifest.permission.READ_EXTERNAL_STORAGE
                }
                if (checkSelfPermission(permission) == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    try {
                        result.success(queryDeviceVideos())
                    } catch (error: Exception) {
                        result.error("media_query_failed", error.message ?: "Could not scan device videos.", null)
                    }
                } else if (pendingVideoLibraryResult != null) {
                    result.error("permission_pending", "Video library permission is already being requested.", null)
                } else {
                    pendingVideoLibraryResult = result
                    requestPermissions(arrayOf(permission), videoLibraryRequestCode)
                }
                return@setMethodCallHandler
            }
            if (call.method == "listDeviceMedia") {
                val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    arrayOf(android.Manifest.permission.READ_MEDIA_IMAGES, android.Manifest.permission.READ_MEDIA_VIDEO)
                } else {
                    arrayOf(android.Manifest.permission.READ_EXTERNAL_STORAGE)
                }
                val granted = permissions.all { checkSelfPermission(it) == android.content.pm.PackageManager.PERMISSION_GRANTED }
                if (granted) {
                    try {
                        result.success(queryDeviceMedia())
                    } catch (error: Exception) {
                        result.error("media_query_failed", error.message ?: "Could not scan device media.", null)
                    }
                } else if (pendingMediaLibraryResult != null) {
                    result.error("permission_pending", "Media library permission is already being requested.", null)
                } else {
                    pendingMediaLibraryResult = result
                    requestPermissions(permissions, mediaLibraryRequestCode)
                }
                return@setMethodCallHandler
            }
            if (call.method == "saveVideoToGallery") {
                val inputPath = call.argument<String>("inputPath")
                val displayName = call.argument<String>("displayName") ?: "Vyntra_${System.currentTimeMillis()}.mp4"
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
            if (call.method == "copyAudioToProject") {
                val inputPath = call.argument<String>("inputPath")
                val projectId = call.argument<String>("projectId")
                if (inputPath.isNullOrBlank() || projectId.isNullOrBlank() || !projectId.matches(Regex("[A-Za-z0-9_-]{1,80}")) || !File(inputPath).isFile) {
                    result.error("invalid_audio", "Choose a readable audio file for this project.", null)
                    return@setMethodCallHandler
                }
                Thread {
                    try {
                        val source = File(inputPath)
                        val safeName = source.name.replace(Regex("[^A-Za-z0-9._-]"), "_")
                        val directory = File(filesDir, "projects/$projectId/audio").apply { mkdirs() }
                        val destination = File(directory, "${System.currentTimeMillis()}_$safeName")
                        source.copyTo(destination, overwrite = true)
                        runOnUiThread { result.success(destination.absolutePath) }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("audio_copy_failed", error.message ?: "Could not store project audio.", null) }
                    }
                }.start()
                return@setMethodCallHandler
            }
            if (call.method == "copyImageToProject") {
                val inputPath = call.argument<String>("inputPath")
                val projectId = call.argument<String>("projectId")
                if (inputPath.isNullOrBlank() || projectId.isNullOrBlank() || !projectId.matches(Regex("[A-Za-z0-9_-]{1,80}")) || !File(inputPath).isFile || File(inputPath).length() > 25L * 1024 * 1024) {
                    result.error("invalid_image", "Choose a readable image smaller than 25 MB.", null)
                    return@setMethodCallHandler
                }
                Thread {
                    try {
                        val source = File(inputPath)
                        val safeName = source.name.replace(Regex("[^A-Za-z0-9._-]"), "_")
                        val directory = File(filesDir, "projects/$projectId/images").apply { mkdirs() }
                        val destination = File(directory, "${System.currentTimeMillis()}_$safeName")
                        source.copyTo(destination, overwrite = true)
                        runOnUiThread { result.success(destination.absolutePath) }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("image_copy_failed", error.message ?: "Could not store project image.", null) }
                    }
                }.start()
                return@setMethodCallHandler
            }
            if (call.method == "enhanceVideo") {
                val inputPath = call.argument<String>("inputPath")
                val outputPath = call.argument<String>("outputPath")
                val outputWidth = call.argument<Number>("outputWidth")?.toInt()
                val outputHeight = call.argument<Number>("outputHeight")?.toInt()
                val brightness = (call.argument<Number>("brightness")?.toFloat() ?: 0.06f).coerceIn(-0.25f, 0.25f)
                val contrast = (call.argument<Number>("contrast")?.toFloat() ?: 0.12f).coerceIn(-0.3f, 0.3f)
                val saturation = (call.argument<Number>("saturation")?.toFloat() ?: 8f).coerceIn(-20f, 30f)
                if (inputPath.isNullOrBlank() || !File(inputPath).isFile ||
                    outputPath.isNullOrBlank() || outputWidth == null || outputHeight == null ||
                    outputWidth < 2 || outputHeight < 2) {
                    result.error("invalid_arguments", "Choose a valid source video and output size.", null)
                    return@setMethodCallHandler
                }
                val outputFile = File(outputPath)
                outputFile.parentFile?.mkdirs()
                outputFile.delete()
                val effects = listOf(
                    Brightness(brightness),
                    Contrast(contrast),
                    HslAdjustment.Builder().adjustSaturation(saturation).adjustLightness(2f).build(),
                    DetailSharpenEffect(0.22f),
                    LanczosResample.scaleToFit(outputWidth, outputHeight),
                    Presentation.createForWidthAndHeight(
                        outputWidth,
                        outputHeight,
                        Presentation.LAYOUT_SCALE_TO_FIT
                    )
                )
                val editedItem = EditedMediaItem.Builder(
                    MediaItem.fromUri(Uri.fromFile(File(inputPath)))
                ).setEffects(Effects(emptyList(), effects)).build()
                val transformer = Transformer.Builder(this)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: androidx.media3.transformer.Composition, exportResult: ExportResult) {
                            if (outputFile.isFile && outputFile.length() > 0L) {
                                result.success(outputFile.absolutePath)
                            } else {
                                outputFile.delete()
                                result.error("enhance_empty", "The video processor completed without producing a valid file.", null)
                            }
                        }

                        override fun onError(
                            composition: androidx.media3.transformer.Composition,
                            exportResult: ExportResult,
                            exportException: ExportException
                        ) {
                            outputFile.delete()
                            result.error("enhance_failed", exportException.message ?: "Video enhancement failed on this device.", null)
                        }
                    })
                    .build()
                try {
                    transformer.start(editedItem, outputFile.absolutePath)
                } catch (error: Exception) {
                    outputFile.delete()
                    result.error("enhance_start_failed", error.message ?: "Could not start video processing.", null)
                }
                return@setMethodCallHandler
            }
            if (call.method == "cropVideo") {
                val inputPath = call.argument<String>("inputPath")
                val outputPath = call.argument<String>("outputPath")
                val outputWidth = call.argument<Number>("outputWidth")?.toInt()
                val outputHeight = call.argument<Number>("outputHeight")?.toInt()
                if (inputPath.isNullOrBlank() || !File(inputPath).isFile ||
                    outputPath.isNullOrBlank() || outputWidth == null || outputHeight == null ||
                    outputWidth < 2 || outputHeight < 2) {
                    result.error("invalid_arguments", "Choose a valid source video and crop size.", null)
                    return@setMethodCallHandler
                }
                val outputFile = File(outputPath)
                outputFile.parentFile?.mkdirs()
                outputFile.delete()
                val cropEffect = Presentation.createForWidthAndHeight(
                    outputWidth,
                    outputHeight,
                    Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP
                )
                val editedItem = EditedMediaItem.Builder(
                    MediaItem.fromUri(Uri.fromFile(File(inputPath)))
                ).setEffects(Effects(emptyList(), listOf(cropEffect))).build()
                val transformer = Transformer.Builder(this)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: androidx.media3.transformer.Composition, exportResult: ExportResult) {
                            if (outputFile.isFile && outputFile.length() > 0L) {
                                result.success(outputFile.absolutePath)
                            } else {
                                outputFile.delete()
                                result.error("crop_empty", "Cropping completed without a valid output file.", null)
                            }
                        }

                        override fun onError(
                            composition: androidx.media3.transformer.Composition,
                            exportResult: ExportResult,
                            exportException: ExportException
                        ) {
                            outputFile.delete()
                            result.error("crop_failed", exportException.message ?: "Video cropping failed on this device.", null)
                        }
                    })
                    .build()
                try {
                    transformer.start(editedItem, outputFile.absolutePath)
                } catch (error: Exception) {
                    outputFile.delete()
                    result.error("crop_start_failed", error.message ?: "Could not start video cropping.", null)
                }
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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == mediaLibraryRequestCode) {
            val callback = pendingMediaLibraryResult ?: return
            pendingMediaLibraryResult = null
            if (grantResults.isNotEmpty() && grantResults.all { it == android.content.pm.PackageManager.PERMISSION_GRANTED }) {
                try { callback.success(queryDeviceMedia()) }
                catch (error: Exception) { callback.error("media_query_failed", error.message ?: "Could not scan device media.", null) }
            } else { callback.error("permission_denied", "Allow Photos and videos access in Android settings, then try again.", null) }
            return
        }
        if (requestCode != videoLibraryRequestCode) return
        val callback = pendingVideoLibraryResult ?: return
        pendingVideoLibraryResult = null
        if (grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            try { callback.success(queryDeviceVideos()) }
            catch (error: Exception) { callback.error("media_query_failed", error.message ?: "Could not scan device videos.", null) }
        } else { callback.error("permission_denied", "Allow video access in Android settings, then try again.", null) }
    }

    private fun queryDeviceVideos(): List<Map<String, Any>> {
        val videos = mutableListOf<Map<String, Any>>()
        val projection = arrayOf(MediaStore.Video.Media.DATA, MediaStore.Video.Media.DISPLAY_NAME, MediaStore.Video.Media.SIZE, MediaStore.Video.Media.DURATION, MediaStore.Video.Media.DATE_MODIFIED)
        contentResolver.query(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, projection, null, null, "date_modified DESC")?.use { cursor ->
            val pathColumn = cursor.getColumnIndex(MediaStore.Video.Media.DATA)
            val nameColumn = cursor.getColumnIndex(MediaStore.Video.Media.DISPLAY_NAME)
            val sizeColumn = cursor.getColumnIndex(MediaStore.Video.Media.SIZE)
            val durationColumn = cursor.getColumnIndex(MediaStore.Video.Media.DURATION)
            val modifiedColumn = cursor.getColumnIndex(MediaStore.Video.Media.DATE_MODIFIED)
            while (cursor.moveToNext()) {
                val path = if (pathColumn >= 0 && !cursor.isNull(pathColumn)) cursor.getString(pathColumn) else null
                val name = if (nameColumn >= 0 && !cursor.isNull(nameColumn)) cursor.getString(nameColumn) else "Video"
                if (path.isNullOrBlank() || !File(path).isFile) continue
                videos.add(mapOf("path" to path, "name" to name, "size" to if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) cursor.getLong(sizeColumn) else 0L, "duration" to if (durationColumn >= 0 && !cursor.isNull(durationColumn)) cursor.getLong(durationColumn) else 0L, "modified" to if (modifiedColumn >= 0 && !cursor.isNull(modifiedColumn)) cursor.getLong(modifiedColumn) else 0L))
            }
        }
        return videos
    }

    override fun onDestroy() {
        superResolutionEngine?.close()
        superResolutionEngine = null
        super.onDestroy()
    }

    private fun inspectVideo(path: String): Map<String, Any> {
        val file = File(path)
        if (!file.isFile) throw IllegalArgumentException("The source video is no longer available.")
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            var width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            var height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            if (rotation == 90 || rotation == 270) {
                val swap = width
                width = height
                height = swap
            }
            if (width < 2 || height < 2) throw IllegalArgumentException("Could not read the video dimensions.")
            return mapOf(
                "width" to width,
                "height" to height,
                "durationMs" to (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L),
                "fileSize" to file.length(),
                "rotation" to rotation
            )
        } finally {
            retriever.release()
        }
    }

    private fun channelGainProcessors(gain: Float): List<AudioProcessor> {
        val processor = ChannelMixingAudioProcessor()
        for (channelCount in 1..8) {
            val matrix = ChannelMixingMatrix.createForConstantPower(channelCount, channelCount).scaleBy(gain.coerceIn(0f, 1f))
            processor.putChannelMixingMatrix(matrix)
        }
        return listOf(processor)
    }

    private fun queryDeviceMedia(): List<Map<String, Any>> {
        val media = mutableListOf<Map<String, Any>>()
        fun query(uri: Uri, isVideo: Boolean) {
            val projection = if (isVideo) {
                arrayOf(MediaStore.Video.Media.DATA, MediaStore.Video.Media.DISPLAY_NAME, MediaStore.Video.Media.SIZE, MediaStore.Video.Media.DURATION, MediaStore.Video.Media.DATE_MODIFIED)
            } else {
                arrayOf(MediaStore.Images.Media.DATA, MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.SIZE, MediaStore.Images.Media.DATE_MODIFIED)
            }
            contentResolver.query(uri, projection, null, null, "date_modified DESC")?.use { cursor ->
                val pathColumn = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                val nameColumn = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                val sizeColumn = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)
                val durationColumn = if (isVideo) cursor.getColumnIndex(MediaStore.Video.Media.DURATION) else -1
                val modifiedColumn = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_MODIFIED)
                while (cursor.moveToNext()) {
                    val path = if (pathColumn >= 0 && !cursor.isNull(pathColumn)) cursor.getString(pathColumn) else null
                    if (path.isNullOrBlank() || !File(path).isFile) continue
                    media.add(mapOf(
                        "path" to path,
                        "name" to if (nameColumn >= 0 && !cursor.isNull(nameColumn)) cursor.getString(nameColumn) else if (isVideo) "Video" else "Photo",
                        "size" to if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) cursor.getLong(sizeColumn) else 0L,
                        "duration" to if (durationColumn >= 0 && !cursor.isNull(durationColumn)) cursor.getLong(durationColumn) else 0L,
                        "modified" to if (modifiedColumn >= 0 && !cursor.isNull(modifiedColumn)) cursor.getLong(modifiedColumn) else 0L,
                        "type" to if (isVideo) "video" else "image"
                    ))
                }
            }
        }
        query(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true)
        query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, false)
        return media.sortedByDescending { (it["modified"] as? Long) ?: 0L }
    }
    private fun saveVideoToGallery(inputPath: String, displayName: String): android.net.Uri {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw IllegalStateException("Saving directly to Gallery requires Android 10 or newer. Use Share to save this export instead.")
        }
        val isPhoto = inputPath.substringAfterLast('.', "").lowercase() in setOf("jpg", "jpeg", "png", "webp")
        val extension = inputPath.substringAfterLast('.', "mp4").lowercase()
        val mimeType = when (extension) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "webp" -> "image/webp"
            else -> "video/mp4"
        }
        val safeName = displayName
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
            .let { name -> if (name.substringAfterLast('.', "").equals(extension, ignoreCase = true)) name else "$name.$extension" }
        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, (if (isPhoto) Environment.DIRECTORY_PICTURES else Environment.DIRECTORY_MOVIES) + "/Vyntra")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = if (isPhoto) MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) else MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("Android could not create a Gallery entry.")
        try {
            resolver.openOutputStream(uri, "w")?.use { output ->
                FileInputStream(inputPath).use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("Android could not open the Gallery output.")
            val published = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
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
            val videoTrack = sourceTracks.firstOrNull { (extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME) ?: "").startsWith("video/") }
                ?: throw IllegalArgumentException("No video track was found.")
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
            var syncStartUs: Long? = null
            while (extractor.sampleTrackIndex >= 0) {
                val time = extractor.sampleTime
                if (time < 0 || time > startUs) break
                if (extractor.sampleTrackIndex == videoTrack && extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
                    syncStartUs = time
                    break
                }
                if (!extractor.advance()) break
            }
            val clipStartUs = syncStartUs
                ?: throw IllegalArgumentException("No preceding video keyframe was found for this clip boundary.")
            extractor.seekTo(clipStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
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
                if (time >= clipStartUs && trackMap.containsKey(track)) {
                    buffer.clear()
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) break
                    info.offset = 0
                    info.size = size
                    info.presentationTimeUs = time - clipStartUs
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
