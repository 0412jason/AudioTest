package com.example.audiotest

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log

object AudioInfoHelper {

    fun getAudioModeOptions(): Map<String, Int> {
        val options = mutableMapOf<String, Int>()
        for (field in AudioManager::class.java.fields) {
            try {
                if (field.type == Int::class.javaPrimitiveType && field.name.startsWith("MODE_")) {
                    val value = field.getInt(null)
                    val name = field.name
                    options[name] = value
                }
            } catch (e: Exception) {
                // Ignore inaccessible fields
            }
        }
        return options
    }

    fun getAudioSourceOptions(): Map<String, Int> {
        val options = mutableMapOf<String, Int>()
        for (field in android.media.MediaRecorder.AudioSource::class.java.fields) {
            try {
                if (field.type == Int::class.javaPrimitiveType) {
                    val value = field.getInt(null)
                    val name = field.name
                    options[name] = value
                }
            } catch (e: Exception) {
                // Ignore inaccessible fields
            }
        }
        return options
    }

    fun getAudioAttributesOptions(): Map<String, Map<String, Int>> {
        val usages = mutableMapOf<String, Int>()
        val contentTypes = mutableMapOf<String, Int>()
        val flags = mutableMapOf<String, Int>()

        for (field in AudioAttributes::class.java.fields) {
            try {
                if (field.type == Int::class.javaPrimitiveType) {
                    val value = field.getInt(null)
                    val name = field.name
                    if (name.startsWith("USAGE_")) {
                        usages[name] = value
                    } else if (name.startsWith("CONTENT_TYPE_")) {
                        contentTypes[name] = value
                    } else if (name.startsWith("FLAG_")) {
                        flags[name] = value
                    }
                }
            } catch (e: Exception) {
                // Ignore inaccessible fields
            }
        }

        return mapOf("usages" to usages, "contentTypes" to contentTypes, "flags" to flags)
    }

    fun getFileAudioInfo(filePath: String): Map<String, Int>? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(filePath)
            var audioTrackIndex = -1
            for (i in 0 until extractor.trackCount) {
                val fmt = extractor.getTrackFormat(i)
                if (fmt.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    audioTrackIndex = i
                    break
                }
            }
            if (audioTrackIndex < 0) return null

            val fmt = extractor.getTrackFormat(audioTrackIndex)
            val sampleRate =
                if (fmt.containsKey(MediaFormat.KEY_SAMPLE_RATE))
                    fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                else 48000
            val channelCount =
                if (fmt.containsKey(MediaFormat.KEY_CHANNEL_COUNT))
                    fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                else 1
            
            val pcmEncoding =
                if (fmt.containsKey(MediaFormat.KEY_PCM_ENCODING))
                    fmt.getInteger(MediaFormat.KEY_PCM_ENCODING)
                else AudioFormat.ENCODING_PCM_16BIT

            val channelConfig = when (channelCount) {
                1 -> AudioFormat.CHANNEL_OUT_MONO
                2 -> AudioFormat.CHANNEL_OUT_STEREO
                else -> AudioFormat.CHANNEL_OUT_MONO
            }

            mapOf(
                "sampleRate" to sampleRate,
                "channelConfig" to channelConfig,
                "audioFormat" to pcmEncoding
            )
        } catch (e: Exception) {
            Log.e("AudioInfoHelper", "getFileAudioInfo failed: $e")
            null
        } finally {
            extractor.release()
        }
    }

    fun getAudioFormatForMime(mime: String): Int {
        return when (mime) {
            MediaFormat.MIMETYPE_AUDIO_MPEG -> AudioFormat.ENCODING_MP3
            MediaFormat.MIMETYPE_AUDIO_AAC -> AudioFormat.ENCODING_AAC_LC
            MediaFormat.MIMETYPE_AUDIO_OPUS -> AudioFormat.ENCODING_OPUS
            "audio/mp4a-latm" -> AudioFormat.ENCODING_AAC_LC
            else -> AudioFormat.ENCODING_INVALID
        }
    }
}
