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
import android.text.SpannableString
import android.text.style.ForegroundColorSpan
import android.graphics.Color
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.FileInputStream
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
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
                    effects.addAll(listOf(Brightness(brightness), Contrast(contrast), HslAdjustment.Builder().adjustSaturation(saturation).build(), DetailSharpenEffect(sharpness), LanczosResample.scaleToFit(outputWidth, outputHeight), Presentation.createForWidthAndHeight(outputWidth, outputHeight, Presentation.LAYOUT_SCALE_TO_FIT)))
                    if (call.argument<Boolean>("watermark") != false) {
                        val label = SpannableString("statushd")
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
                val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(inputPath)))).setEffects(Effects(emptyList(), effects)).build()
                val transformer = Transformer.Builder(this).setVideoMimeType(MimeTypes.VIDEO_H264).setAudioMimeType(MimeTypes.AUDIO_AAC).addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: androidx.media3.transformer.Composition, exportResult: ExportResult) {
                        activeTransformer = null
                        if (outputFile.isFile && outputFile.length() > 0L) result.success(mapOf("path" to outputFile.absolutePath))
                        else { outputFile.delete(); result.error("output_missing", "Processing completed without a usable output file.", null) }
                    }
                    override fun onError(composition: androidx.media3.transformer.Composition, exportResult: ExportResult, exportException: ExportException) {
                        activeTransformer = null
                        outputFile.delete()
                        result.error("processing_failed", exportException.message ?: "This device could not process the video.", null)
                    }
                }).build()
                activeTransformer = transformer
                try { transformer.start(item, outputFile.absolutePath) }
                catch (error: Exception) { activeTransformer = null; outputFile.delete(); result.error("processing_start_failed", error.message ?: "Could not start processing.", null) }
                return@setMethodCallHandler
            }
            if (call.method == "processNeuralVideo") {
                val inputPath = call.argument<String>("inputPath")
                val outputPath = call.argument<String>("outputPath")
                val width = call.argument<Int>("outputWidth") ?: 0
                val height = call.argument<Int>("outputHeight") ?: 0
                if (inputPath.isNullOrBlank() || outputPath.isNullOrBlank() || !File(inputPath).isFile || width < 2 || height < 2) {
                    result.error("invalid_neural_arguments", "Choose a valid source and neural output size.", null)
                    return@setMethodCallHandler
                }
                Thread {
                    try {
                        val engine = superResolutionEngine ?: SuperResolutionEngine(this).also { superResolutionEngine = it }
                        val output = NeuralVideoProcessor(engine).process(inputPath, outputPath, width, height)
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
            } else { callback.success(emptyList<Map<String, Any>>()) }
            return
        }
        if (requestCode != videoLibraryRequestCode) return
        val callback = pendingVideoLibraryResult ?: return
        pendingVideoLibraryResult = null
        if (grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            try { callback.success(queryDeviceVideos()) }
            catch (error: Exception) { callback.error("media_query_failed", error.message ?: "Could not scan device videos.", null) }
        } else { callback.success(emptyList<Map<String, Any>>()) }
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
            put(MediaStore.MediaColumns.RELATIVE_PATH, (if (isPhoto) Environment.DIRECTORY_PICTURES else Environment.DIRECTORY_MOVIES) + "/Status HD")
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
