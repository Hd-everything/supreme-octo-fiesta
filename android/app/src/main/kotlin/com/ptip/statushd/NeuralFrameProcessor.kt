package com.ptip.statushd

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import org.tensorflow.lite.InterpreterApi
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Real ESPCN 3x frame/tile inference. The video bridge must call this for
 * each decoded tile and then composite the returned bitmap into the encoder. */
class NeuralFrameProcessor(private val interpreter: InterpreterApi) {
    companion object { const val TILE = 64; const val SCALE = 3; const val OUTPUT = 192 }

    fun upscale(tile: Bitmap): Bitmap {
        val inputBitmap = Bitmap.createScaledBitmap(tile, TILE, TILE, true)
        val input = Array(1) { Array(3) { Array(TILE) { FloatArray(TILE) } } }
        for (y in 0 until TILE) for (x in 0 until TILE) {
            val pixel = inputBitmap.getPixel(x, y)
            input[0][0][y][x] = Color.red(pixel) / 255f
            input[0][1][y][x] = Color.green(pixel) / 255f
            input[0][2][y][x] = Color.blue(pixel) / 255f
        }
        val output = Array(1) { Array(3) { Array(OUTPUT) { FloatArray(OUTPUT) } } }
        interpreter.run(input, output)
        val result = Bitmap.createBitmap(OUTPUT, OUTPUT, Bitmap.Config.ARGB_8888)
        for (y in 0 until OUTPUT) for (x in 0 until OUTPUT) {
            val red = (output[0][0][y][x].coerceIn(0f, 1f) * 255f).toInt()
            val green = (output[0][1][y][x].coerceIn(0f, 1f) * 255f).toInt()
            val blue = (output[0][2][y][x].coerceIn(0f, 1f) * 255f).toInt()
            result.setPixel(x, y, Color.rgb(red, green, blue))
        }
        inputBitmap.recycle()
        return result
    }

    fun upscaleFrame(frame: Bitmap, outputWidth: Int, outputHeight: Int): Bitmap {
        val scaled = Bitmap.createBitmap(outputWidth, outputHeight, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(scaled)
        val paint = android.graphics.Paint(android.graphics.Paint.FILTER_BITMAP_FLAG)
        val tileCountX = (frame.width + TILE - 1) / TILE
        val tileCountY = (frame.height + TILE - 1) / TILE
        for (tileY in 0 until tileCountY) for (tileX in 0 until tileCountX) {
            val left = tileX * TILE
            val top = tileY * TILE
            val width = minOf(TILE, frame.width - left)
            val height = minOf(TILE, frame.height - top)
            val tile = Bitmap.createBitmap(frame, left, top, width, height)
            val result = upscale(tile)
            canvas.drawBitmap(result, null, android.graphics.Rect(left * SCALE, top * SCALE, (left + width) * SCALE, (top + height) * SCALE), paint)
            tile.recycle()
            result.recycle()
        }
        return scaled
    }
}
