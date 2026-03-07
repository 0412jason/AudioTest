package com.example.audiotest

import android.media.AudioFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder

object AudioPcmHelper {

    fun getBytesPerSample(audioFormat: Int): Int {
        return when (audioFormat) {
            AudioFormat.ENCODING_PCM_8BIT -> 1
            AudioFormat.ENCODING_PCM_16BIT -> 2
            AudioFormat.ENCODING_PCM_24BIT_PACKED -> 3
            AudioFormat.ENCODING_PCM_FLOAT -> 4
            else -> 2
        }
    }

    fun getChannelCount(channelConfig: Int): Int {
        val count = Integer.bitCount(channelConfig)
        return if (count > 0) count else 1
    }

    fun calculateMaxAmplitude(
        chunk: ByteArray,
        offset: Int,
        length: Int,
        audioFormat: Int,
        bytesPerFrame: Int
    ): Double {
        var maxAmp = 0.0
        for (j in offset until offset + length step bytesPerFrame) {
            if (j + bytesPerFrame > chunk.size) break

            val sampleAmp = when (audioFormat) {
                AudioFormat.ENCODING_PCM_8BIT -> {
                    val s = (chunk[j].toInt() and 0xFF) - 128
                    Math.abs(s).toDouble() / 128.0
                }
                AudioFormat.ENCODING_PCM_16BIT -> {
                    val b1 = chunk[j].toInt() and 0xFF
                    val b2 = chunk[j + 1].toInt()
                    val s = (b1 or (b2 shl 8)).toShort()
                    Math.abs(s.toInt()).toDouble() / Short.MAX_VALUE
                }
                AudioFormat.ENCODING_PCM_24BIT_PACKED -> {
                    val b1 = chunk[j].toInt() and 0xFF
                    val b2 = chunk[j + 1].toInt() and 0xFF
                    val b3 = chunk[j + 2].toInt()
                    val s = b1 or (b2 shl 8) or (b3 shl 16)
                    Math.abs(s).toDouble() / 8388607.0
                }
                AudioFormat.ENCODING_PCM_FLOAT -> {
                    val bb = ByteBuffer.wrap(chunk, j, 4).order(ByteOrder.LITTLE_ENDIAN)
                    val s = bb.float
                    Math.abs(s).toDouble()
                }
                else -> 0.0
            }
            if (sampleAmp > maxAmp) maxAmp = sampleAmp
        }
        return maxAmp
    }
}
