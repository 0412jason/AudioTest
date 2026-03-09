package com.example.audiotest

import android.app.Activity
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.sin

class AudioPlaybackManager(private val activity: Activity) {
    private val context: Context = activity.applicationContext
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    // Maps to track active instances
    private val audioTracks = mutableMapOf<Int, AudioTrack>()
    private val playbackThreads = mutableMapOf<Int, Thread>()
    private val isPlayingMap = mutableMapOf<Int, Boolean>()
    private val isPausedMap = mutableMapOf<Int, Boolean>()

    private var amplitudeSink: EventChannel.EventSink? = null
    private var trackInfoSink: EventChannel.EventSink? = null

    fun setAmplitudeSink(sink: EventChannel.EventSink?) {
        amplitudeSink = sink
    }

    fun setTrackInfoSink(sink: EventChannel.EventSink?) {
        trackInfoSink = sink
    }

    fun startPlayback(
        instanceId: Int,
        sampleRate: Int,
        channelConfig: Int,
        audioFormat: Int,
        usage: Int,
        contentType: Int,
        flags: Int,
        preferredDeviceId: Int?,
        filePath: String?,
        offload: Boolean
    ) {
        stopPlayback(instanceId)

        val bufferSize = AudioTrack.getMinBufferSize(sampleRate, channelConfig, audioFormat)

        if (bufferSize <= 0) {
            Log.e("AudioPlaybackManager", "Invalid AudioTrack parameters.")
            activity.runOnUiThread { 
                trackInfoSink?.error("INVALID_PARAMS", "Invalid AudioTrack parameters: bufferSize <= 0", null) 
            }
            return
        }

        val audioAttributes = AudioAttributes.Builder()
            .setUsage(usage)
            .setContentType(contentType)
            .setFlags(flags)
            .build()

        isPlayingMap[instanceId] = true
        isPausedMap[instanceId] = false

        val playbackThread = Thread {
            if (filePath != null) {
                playLocalFile(
                    instanceId,
                    audioAttributes,
                    sampleRate,
                    channelConfig,
                    audioFormat,
                    bufferSize,
                    preferredDeviceId,
                    filePath,
                    offload
                )
            } else {
                playSineWave(
                    instanceId,
                    audioAttributes,
                    sampleRate,
                    channelConfig,
                    audioFormat,
                    bufferSize,
                    preferredDeviceId
                )
            }
        }
        playbackThreads[instanceId] = playbackThread
        playbackThread.start()
    }

    fun stopPlayback(instanceId: Int) {
        audioTracks[instanceId]?.let { fadeVolume(it, 1f, 0f) }

        isPlayingMap[instanceId] = false
        isPausedMap[instanceId] = false
        playbackThreads[instanceId]?.join()
        playbackThreads.remove(instanceId)

        audioTracks[instanceId]?.apply {
            try {
                pause()
                flush()
                stop()
                release()
            } catch (e: Exception) {
                Log.e("AudioPlaybackManager", "Error stopping track: $e")
            }
        }
        audioTracks.remove(instanceId)
    }

    fun pausePlayback(instanceId: Int) {
        if (isPlayingMap[instanceId] == true && isPausedMap[instanceId] == false) {
            audioTracks[instanceId]?.let { fadeVolume(it, 1f, 0f) }
            isPausedMap[instanceId] = true
            audioTracks[instanceId]?.pause()
        }
    }

    fun resumePlayback(instanceId: Int) {
        if (isPlayingMap[instanceId] == true && isPausedMap[instanceId] == true) {
            audioTracks[instanceId]?.setVolume(0f)
            isPausedMap[instanceId] = false
            audioTracks[instanceId]?.play()
            audioTracks[instanceId]?.let { fadeVolume(it, 0f, 1f) }
        }
    }

    private fun createAndStartAudioTrack(
        instanceId: Int,
        audioAttributes: AudioAttributes,
        sampleRate: Int,
        channelConfig: Int,
        audioFormat: Int,
        bufferSize: Int,
        preferredDeviceId: Int?,
        isOffloaded: Boolean = false
    ): AudioTrack? {
        val formatObj = AudioFormat.Builder()
            .setSampleRate(sampleRate)
            .setChannelMask(channelConfig)
            .setEncoding(audioFormat)
            .build()

        return try {
            val track = if (isOffloaded && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                AudioTrack.Builder()
                    .setAudioAttributes(audioAttributes)
                    .setAudioFormat(formatObj)
                    .setBufferSizeInBytes(bufferSize)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .setOffloadedPlayback(true)
                    .build()
            } else {
                AudioTrack(audioAttributes, formatObj, bufferSize, AudioTrack.MODE_STREAM, AudioManager.AUDIO_SESSION_ID_GENERATE)
            }

            preferredDeviceId?.let { id ->
                audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { it.id == id }?.let {
                    track.preferredDevice = it
                }
            }

            audioTracks[instanceId] = track

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                track.addOnRoutingChangedListener({ router -> 
                    sendAudioTrackInfo(instanceId, router as AudioTrack, isOffloaded) 
                }, null)
            }

            track.play()
            sendAudioTrackInfo(instanceId, track, isOffloaded)
            track
        } catch (e: Exception) {
            Log.e("AudioPlaybackManager", "Failed to create/start AudioTrack (offload=$isOffloaded): $e")
            null
        }
    }

    private fun notifyAmplitude(instanceId: Int, amplitude: Double) {
        activity.runOnUiThread { amplitudeSink?.success(mapOf("id" to instanceId, "amp" to amplitude)) }
    }

    private fun playLocalFile(
        instanceId: Int,
        audioAttributes: AudioAttributes,
        sampleRate: Int,
        channelConfig: Int,
        audioFormat: Int,
        bufferSize: Int,
        preferredDeviceId: Int?,
        filePath: String,
        offload: Boolean
    ) {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(filePath)
        } catch (e: Exception) {
            Log.e("AudioPlaybackManager", "Failed to set data source: $e")
            return
        }

        var audioTrackIndex = -1
        for (i in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(i)
            val mime = format.getString(MediaFormat.KEY_MIME)
            if (mime?.startsWith("audio/") == true) {
                audioTrackIndex = i
                break
            }
        }

        if (audioTrackIndex < 0) {
            Log.e("AudioPlaybackManager", "No audio track found in file.")
            extractor.release()
            return
        }

        extractor.selectTrack(audioTrackIndex)
        val format = extractor.getTrackFormat(audioTrackIndex)
        val mime = format.getString(MediaFormat.KEY_MIME) ?: return
        var useOffload = false
        var offloadTrack: AudioTrack? = null
        val isTearDown = AtomicBoolean(false)

        if (offload && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val encodingForOffload = AudioInfoHelper.getAudioFormatForMime(mime)
            if (encodingForOffload != AudioFormat.ENCODING_INVALID) {
                val trackSampleRate = if (format.containsKey(MediaFormat.KEY_SAMPLE_RATE))
                    format.getInteger(MediaFormat.KEY_SAMPLE_RATE) else sampleRate
                val trackChannelCount = if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT))
                    format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 1
                val trackChannelConfig = when (trackChannelCount) {
                    1 -> AudioFormat.CHANNEL_OUT_MONO
                    2 -> AudioFormat.CHANNEL_OUT_STEREO
                    else -> AudioFormat.CHANNEL_OUT_MONO
                }

                if (isPlayingMap[instanceId] == true) {
                    offloadTrack = createAndStartAudioTrack(
                        instanceId, audioAttributes, trackSampleRate, trackChannelConfig, 
                        encodingForOffload, 256 * 1024, preferredDeviceId, true
                    )
                    
                    offloadTrack?.let { track ->
                        track.registerStreamEventCallback({ r -> r.run() }, 
                            object : AudioTrack.StreamEventCallback() {
                                override fun onTearDown(track: AudioTrack) {
                                    Log.i("AudioPlaybackManager", "Offload track tear down!")
                                    isTearDown.set(true)
                                }
                            })
                        useOffload = true
                        Log.i("AudioPlaybackManager", "Started compress offload playback")
                    }
                }
            }
        }

        if (useOffload && offloadTrack != null) {
            val buffer = java.nio.ByteBuffer.allocateDirect(256 * 1024)
            while (isPlayingMap[instanceId] == true) {
                if (isPausedMap[instanceId] == true) {
                    Thread.sleep(50)
                    continue
                }
                if (isTearDown.get()) {
                    Log.i("AudioPlaybackManager", "Tearing down offload track, falling back to PCM")
                    break
                }

                buffer.clear()
                val sampleSize = extractor.readSampleData(buffer, 0)
                if (sampleSize < 0) break

                val bytes = ByteArray(sampleSize)
                buffer.get(bytes)
                val written = offloadTrack.write(bytes, 0, sampleSize, AudioTrack.WRITE_BLOCKING)
                if (written > 0) extractor.advance()

                notifyAmplitude(instanceId, 0.0)
            }

            try { offloadTrack.stop() } catch (e: Exception) {}
            offloadTrack.release()

            if (isTearDown.get() && isPlayingMap[instanceId] == true) {
                extractor.seekTo(extractor.sampleTime, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            } else {
                extractor.release()
                if (isPlayingMap[instanceId] == true) {
                    activity.runOnUiThread { stopPlayback(instanceId) }
                }
                return
            }
        }

        if (isPlayingMap[instanceId] != true) {
            extractor.release()
            return
        }

        Log.i("AudioPlaybackManager", "Starting PCM playback")

        val codec: MediaCodec
        try {
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()
        } catch (e: Exception) {
            Log.e("AudioPlaybackManager", "Failed to configure codec: $e")
            extractor.release()
            return
        }

        val info = MediaCodec.BufferInfo()
        var isEOS = false

        var audioTrack: AudioTrack? = null
        var trackSampleRate = if (format.containsKey(MediaFormat.KEY_SAMPLE_RATE)) format.getInteger(MediaFormat.KEY_SAMPLE_RATE) else sampleRate
        var trackChannelCount = if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 1
        var trackChannelConfig = if (trackChannelCount == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        var trackAudioFormat = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && format.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
            format.getInteger(MediaFormat.KEY_PCM_ENCODING)
        } else {
            AudioFormat.ENCODING_PCM_16BIT
        }
        var bytesPerFrame = trackChannelCount * AudioPcmHelper.getBytesPerSample(trackAudioFormat)
        var subChunkSizeInBytes = ((trackSampleRate / 40) * bytesPerFrame).coerceAtLeast(bytesPerFrame)

        while (isPlayingMap[instanceId] == true) {
            if (isPausedMap[instanceId] == true) {
                Thread.sleep(50)
                continue
            }

            if (!isEOS) {
                val inIndex = codec.dequeueInputBuffer(10000)
                if (inIndex >= 0) {
                    val buffer = codec.getInputBuffer(inIndex)
                    val sampleSize = buffer?.let { extractor.readSampleData(it, 0) } ?: -1
                    if (sampleSize < 0) {
                        codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        isEOS = true
                    } else {
                        codec.queueInputBuffer(inIndex, 0, sampleSize, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }

            val outIndex = codec.dequeueOutputBuffer(info, 10000)
            if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val newFormat = codec.outputFormat
                trackSampleRate = if (newFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) newFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE) else trackSampleRate
                trackChannelCount = if (newFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) newFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else trackChannelCount
                trackChannelConfig = if (trackChannelCount == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
                trackAudioFormat = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && newFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                    newFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
                } else {
                    AudioFormat.ENCODING_PCM_16BIT
                }
                bytesPerFrame = trackChannelCount * AudioPcmHelper.getBytesPerSample(trackAudioFormat)
                subChunkSizeInBytes = ((trackSampleRate / 40) * bytesPerFrame).coerceAtLeast(bytesPerFrame)
                Log.i("AudioPlaybackManager", "Decoded format changed: rate=$trackSampleRate, channels=$trackChannelCount, format=$trackAudioFormat")
            } else if (outIndex >= 0) {
                if (audioTrack == null) {
                    val outBufferSize = AudioTrack.getMinBufferSize(trackSampleRate, trackChannelConfig, trackAudioFormat)
                    val bufferSizeToUse = if (outBufferSize > 0) outBufferSize * 2 else 2048
                    audioTrack = createAndStartAudioTrack(
                        instanceId, audioAttributes, trackSampleRate, trackChannelConfig, trackAudioFormat, bufferSizeToUse, preferredDeviceId, false
                    )
                    if (audioTrack == null) {
                        Log.e("AudioPlaybackManager", "Failed to create dynamic PCM AudioTrack")
                        break
                    }
                }

                val buffer = codec.getOutputBuffer(outIndex)
                if (buffer != null && info.size > 0 && audioTrack != null) {
                    val chunk = ByteArray(info.size)
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    buffer.get(chunk)
                    buffer.clear()

                    for (i in 0 until chunk.size step subChunkSizeInBytes) {
                        if (isPlayingMap[instanceId] != true) break
                        
                        val length = Math.min(subChunkSizeInBytes, chunk.size - i)
                        audioTrack!!.write(chunk, i, length)

                        val maxAmp = AudioPcmHelper.calculateMaxAmplitude(chunk, i, length, trackAudioFormat, bytesPerFrame)
                        notifyAmplitude(instanceId, maxAmp)
                    }
                }
                codec.releaseOutputBuffer(outIndex, false)
            }

            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
        }

        codec.stop()
        codec.release()
        extractor.release()

        if (isPlayingMap[instanceId] == true) {
            activity.runOnUiThread { stopPlayback(instanceId) }
        }
    }

    private fun playSineWave(
        instanceId: Int,
        audioAttributes: AudioAttributes,
        sampleRate: Int,
        channelConfig: Int,
        audioFormat: Int,
        bufferSize: Int,
        preferredDeviceId: Int?
    ) {
        val audioTrack = createAndStartAudioTrack(
            instanceId, audioAttributes, sampleRate, channelConfig, audioFormat, bufferSize, preferredDeviceId, false
        )
        if (audioTrack == null) return

        val frequency = 440.0
        var angle = 0.0
        val angleIncrement = 2.0 * Math.PI * frequency / sampleRate
        val channelCount = AudioPcmHelper.getChannelCount(channelConfig)

        val is8Bit = audioFormat == AudioFormat.ENCODING_PCM_8BIT
        val is16Bit = audioFormat == AudioFormat.ENCODING_PCM_16BIT
        val is24Bit = audioFormat == AudioFormat.ENCODING_PCM_24BIT_PACKED
        val isFloat = audioFormat == AudioFormat.ENCODING_PCM_FLOAT

        val framesPerUpdate = sampleRate / 40 // ~25ms
        val bytesPerSample = AudioPcmHelper.getBytesPerSample(audioFormat)
        val updateBufferSizeInBytes = framesPerUpdate * channelCount * bytesPerSample

        val byteBuffer = if (is8Bit || is24Bit) ByteArray(updateBufferSizeInBytes) else null
        val shortBuffer = if (is16Bit) ShortArray(framesPerUpdate * channelCount) else null
        val floatBuffer = if (isFloat) FloatArray(framesPerUpdate * channelCount) else null

        while (isPlayingMap[instanceId] == true) {
            if (isPausedMap[instanceId] == true) {
                Thread.sleep(50)
                continue
            }

            var normalizedAmp = 0.0

            if (is8Bit && byteBuffer != null) {
                var maxAmp = 0
                var i = 0
                while (i < byteBuffer.size) {
                    val sampleValue = (sin(angle) * 127).toInt() + 128
                    val sample = sampleValue.toByte()
                    repeat(channelCount) { ch -> if (i + ch < byteBuffer.size) byteBuffer[i + ch] = sample }
                    i += channelCount
                    angle += angleIncrement
                    val amp = Math.abs(sampleValue - 128)
                    if (amp > maxAmp) maxAmp = amp
                }
                audioTrack.write(byteBuffer, 0, byteBuffer.size)
                normalizedAmp = maxAmp.toDouble() / 128.0
            } else if (is24Bit && byteBuffer != null) {
                var maxAmp = 0
                val bytesPerFrame = bytesPerSample * channelCount
                var i = 0
                while (i + bytesPerFrame <= byteBuffer.size) {
                    val sampleInt = (sin(angle) * 8388607).toInt()
                    val b0 = (sampleInt and 0xFF).toByte()
                    val b1 = ((sampleInt shr 8) and 0xFF).toByte()
                    val b2 = ((sampleInt shr 16) and 0xFF).toByte()
                    for (ch in 0 until channelCount) {
                        val base = i + ch * bytesPerSample
                        byteBuffer[base] = b0
                        byteBuffer[base + 1] = b1
                        byteBuffer[base + 2] = b2
                    }
                    i += bytesPerFrame
                    angle += angleIncrement
                    if (Math.abs(sampleInt) > maxAmp) maxAmp = Math.abs(sampleInt)
                }
                audioTrack.write(byteBuffer, 0, byteBuffer.size)
                normalizedAmp = maxAmp.toDouble() / 8388607.0
            } else if (isFloat && floatBuffer != null) {
                var maxAmp = 0.0f
                var i = 0
                while (i < floatBuffer.size) {
                    val sample = sin(angle).toFloat()
                    repeat(channelCount) { ch -> if (i + ch < floatBuffer.size) floatBuffer[i + ch] = sample }
                    i += channelCount
                    angle += angleIncrement
                    if (Math.abs(sample) > maxAmp) maxAmp = Math.abs(sample)
                }
                audioTrack.write(floatBuffer, 0, floatBuffer.size, AudioTrack.WRITE_BLOCKING)
                normalizedAmp = maxAmp.toDouble()
            } else if (shortBuffer != null) {
                var maxAmp = 0
                var i = 0
                while (i < shortBuffer.size) {
                    val sample = (sin(angle) * Short.MAX_VALUE).toInt().toShort()
                    repeat(channelCount) { ch -> if (i + ch < shortBuffer.size) shortBuffer[i + ch] = sample }
                    i += channelCount
                    angle += angleIncrement
                    if (Math.abs(sample.toInt()) > maxAmp) maxAmp = Math.abs(sample.toInt())
                }
                audioTrack.write(shortBuffer, 0, shortBuffer.size)
                normalizedAmp = maxAmp.toDouble() / Short.MAX_VALUE
            }

            notifyAmplitude(instanceId, normalizedAmp)
        }
    }

    private fun fadeVolume(track: AudioTrack, from: Float, to: Float, steps: Int = 40, stepMs: Long = 1) {
        for (i in 0..steps) {
            val vol = from + (to - from) * (i.toFloat() / steps)
            track.setVolume(vol)
            Thread.sleep(stepMs)
        }
    }

    private fun sendAudioTrackInfo(instanceId: Int, track: AudioTrack, isOffloaded: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.CUPCAKE) {
            val infoMap = mutableMapOf<String, Any>(
                "id" to instanceId,
                "sampleRate" to track.sampleRate,
                "channelCount" to track.channelCount,
                "audioFormat" to track.audioFormat,
                "isOffloaded" to isOffloaded
            )

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val attrs = track.audioAttributes
                infoMap["usage"] = attrs.usage
                infoMap["contentType"] = attrs.contentType
                infoMap["flags"] = attrs.flags
            }

            val routedDevicesList = mutableListOf<Map<String, Any>>()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
                val devices = track.routedDevices
                for (device in devices) {
                    routedDevicesList.add(mapOf(
                        "name" to device.productName.toString(),
                        "type" to "${AudioDeviceManager(context).getDeviceTypeName(device.type)} (${device.type})",
                        "id" to device.id
                    ))
                }
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                track.routedDevice?.let { device ->
                    routedDevicesList.add(mapOf(
                        "name" to device.productName.toString(),
                        "type" to "${AudioDeviceManager(context).getDeviceTypeName(device.type)} (${device.type})",
                        "id" to device.id
                    ))
                }
            }

            if (routedDevicesList.isNotEmpty()) {
                infoMap["routedDevices"] = routedDevicesList
            }

            activity.runOnUiThread { trackInfoSink?.success(infoMap) }
        }
    }
}
