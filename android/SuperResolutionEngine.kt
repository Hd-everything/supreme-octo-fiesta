package com.ptip.statushd

import android.content.Context
import android.graphics.Bitmap
import org.tensorflow.lite.InterpreterApi
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Loads and benchmarks the packaged ESPCN model. Video jobs must use this
 * same engine rather than treating a resize as neural restoration. */
class SuperResolutionEngine(private val context: Context) : AutoCloseable {
    private var interpreter: InterpreterApi? = null

    fun capability(): Map<String, Any> {
        return try {
            val model = loadModel()
            val input = model.getInputTensor(0).shape()
            val output = model.getOutputTensor(0).shape()
            if (!input.contentEquals(intArrayOf(1, 3, 64, 64)) || !output.contentEquals(intArrayOf(1, 3, 192, 192))) {
                close(); mapOf("ready" to false, "reason" to "model_tensor_shape_mismatch")
            } else {
                val started = System.nanoTime()
                val inputBuffer = ByteBuffer.allocateDirect(1 * 3 * 64 * 64 * 4).order(ByteOrder.nativeOrder())
                val outputBuffer = ByteBuffer.allocateDirect(1 * 3 * 192 * 192 * 4).order(ByteOrder.nativeOrder())
                model.run(inputBuffer, outputBuffer)
                mapOf("ready" to true, "videoPipeline" to true, "scale" to 3, "backend" to "tensorflow-lite-cpu", "benchmarkMs" to ((System.nanoTime() - started) / 1_000_000L))
            }
        } catch (error: Exception) {
            close(); mapOf("ready" to false, "reason" to (error.message ?: "model_initialization_failed"))
        }
    }

    fun upscaleFrame(frame: Bitmap, outputWidth: Int, outputHeight: Int): Bitmap {
        return NeuralFrameProcessor(loadModel()).upscaleFrame(frame, outputWidth, outputHeight)
    }

    private fun loadModel(): InterpreterApi {
        return interpreter ?: run {
            val bytes = context.assets.open("flutter_assets/assets/models/espcn_x3.tflite").use { it.readBytes() }
            InterpreterApi.create(ByteBuffer.wrap(bytes), InterpreterApi.Options().apply { setNumThreads(2) }).also { interpreter = it }
        }
    }

    override fun close() { interpreter?.close(); interpreter = null }
}
