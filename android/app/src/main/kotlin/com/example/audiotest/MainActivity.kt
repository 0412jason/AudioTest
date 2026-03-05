package com.example.audiotest

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.math.sin

class MainActivity : FlutterActivity() {
    private val AUDIO_CHANNEL = "com.example.audiotest/audio"
    private val AMPLITUDE_CHANNEL = "com.example.audiotest/amplitude"
    private val DEVICE_CHANGE_CHANNEL = "com.example.audiotest/deviceChanges"

    // Maps to track active instances
    private val audioTracks = mutableMapOf<Int, AudioTrack>()
    private val playbackThreads = mutableMapOf<Int, Thread>()
    private val isPlayingMap = mutableMapOf<Int, Boolean>()
    private val isPausedMap = mutableMapOf<Int, Boolean>()

    private val audioRecords = mutableMapOf<Int, AudioRecord>()
    private val recordThreads = mutableMapOf<Int, Thread>()
    private val isRecordingMap = mutableMapOf<Int, Boolean>()

    private var eventSink: EventChannel.EventSink? = null
    private var deviceChangeEventSink: EventChannel.EventSink? = null
    private var audioDeviceCallback: android.media.AudioDeviceCallback? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, AMPLITUDE_CHANNEL)
                .setStreamHandler(
                        object : EventChannel.StreamHandler {
                            override fun onListen(
                                    arguments: Any?,
                                    events: EventChannel.EventSink?
                            ) {
                                eventSink = events
                            }

                            override fun onCancel(arguments: Any?) {
                                eventSink = null
                            }
                        }
                )

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANGE_CHANNEL)
                .setStreamHandler(
                        object : EventChannel.StreamHandler {
                            override fun onListen(
                                    arguments: Any?,
                                    events: EventChannel.EventSink?
                            ) {
                                deviceChangeEventSink = events
                                registerAudioDeviceCallback()
                            }

                            override fun onCancel(arguments: Any?) {
                                deviceChangeEventSink = null
                                unregisterAudioDeviceCallback()
                            }
                        }
                )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getAudioDevices" -> {
                            val isOutput = call.argument<Boolean>("isOutput") ?: true
                            val devices = getAudioDevices(isOutput)
                            result.success(devices)
                        }
                        "getAudioAttributesOptions" -> {
                            val options = getAudioAttributesOptions()
                            result.success(options)
                        }
                        "getAudioSourceOptions" -> {
                            val options = getAudioSourceOptions()
                            result.success(options)
                        }
                        "getAudioModeOptions" -> {
                            val options = getAudioModeOptions()
                            result.success(options)
                        }
                        "getFileAudioInfo" -> {
                            val filePath =
                                    call.argument<String>("filePath")
                                            ?: return@setMethodCallHandler result.error(
                                                    "NO_PATH",
                                                    "filePath is required",
                                                    null
                                            )
                            val info = getFileAudioInfo(filePath)
                            if (info == null) {
                                result.error(
                                        "READ_ERROR",
                                        "Could not read audio info from file",
                                        null
                                )
                            } else {
                                result.success(info)
                            }
                        }
                        "getAudioMode" -> {
                            val audioManager =
                                    getSystemService(Context.AUDIO_SERVICE) as AudioManager
                            result.success(audioManager.mode)
                        }
                        "setAudioMode" -> {
                            val audioMode =
                                    call.argument<Int>("audioMode") ?: AudioManager.MODE_NORMAL
                            val audioManager =
                                    getSystemService(Context.AUDIO_SERVICE) as AudioManager
                            audioManager.mode = audioMode
                            Log.d("AudioTest", "setAudioMode: mode changed to $audioMode")
                            result.success(null)
                        }
                        "setCommunicationDevice" -> {
                            val deviceId = call.argument<Int>("deviceId")
                            val audioManager =
                                    getSystemService(Context.AUDIO_SERVICE) as AudioManager
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                if (deviceId == null) {
                                    audioManager.clearCommunicationDevice()
                                    Log.d("AudioTest", "clearCommunicationDevice")
                                    result.success(true)
                                } else {
                                    val devices = audioManager.availableCommunicationDevices
                                    val device = devices.firstOrNull { it.id == deviceId }
                                    if (device != null) {
                                        val success = audioManager.setCommunicationDevice(device)
                                        Log.d(
                                                "AudioTest",
                                                "setCommunicationDevice ($deviceId): $success"
                                        )
                                        result.success(success)
                                    } else {
                                        Log.w(
                                                "AudioTest",
                                                "setCommunicationDevice: device $deviceId not found"
                                        )
                                        result.success(false)
                                    }
                                }
                            } else {
                                Log.w(
                                        "AudioTest",
                                        "setCommunicationDevice is only supported on Android 12+"
                                )
                                result.success(false)
                            }
                        }
                        "startPlayback" -> {
                            val instanceId =
                                    call.argument<Int>("instanceId")
                                            ?: return@setMethodCallHandler result.error(
                                                    "NO_ID",
                                                    "instanceId is required",
                                                    null
                                            )
                            val sampleRate = call.argument<Int>("sampleRate") ?: 48000
                            val channelConfig =
                                    call.argument<Int>("channelConfig")
                                            ?: AudioFormat.CHANNEL_OUT_MONO
                            val audioFormat =
                                    call.argument<Int>("audioFormat")
                                            ?: AudioFormat.ENCODING_PCM_16BIT
                            val usage = call.argument<Int>("usage") ?: AudioAttributes.USAGE_MEDIA
                            val contentType =
                                    call.argument<Int>("contentType")
                                            ?: AudioAttributes.CONTENT_TYPE_MUSIC
                            val flags = call.argument<Int>("flags") ?: 0
                            val preferredDeviceId = call.argument<Int>("preferredDeviceId")
                            val filePath = call.argument<String>("filePath")

                            startPlayback(
                                    instanceId,
                                    sampleRate,
                                    channelConfig,
                                    audioFormat,
                                    usage,
                                    contentType,
                                    flags,
                                    preferredDeviceId,
                                    filePath
                            )
                            result.success(null)
                        }
                        "stopPlayback" -> {
                            val instanceId =
                                    call.argument<Int>("instanceId")
                                            ?: return@setMethodCallHandler result.error(
                                                    "NO_ID",
                                                    "instanceId is required",
                                                    null
                                            )
                            stopPlayback(instanceId)
                            result.success(null)
                        }
                        "pausePlayback" -> {
                            val instanceId =
                                    call.argument<Int>("instanceId")
                                            ?: return@setMethodCallHandler result.error(
                                                    "NO_ID",
                                                    "instanceId is required",
                                                    null
                                            )
                            pausePlayback(instanceId)
                            result.success(null)
                        }
                        "resumePlayback" -> {
                            val instanceId =
                                    call.argument<Int>("instanceId")
                                            ?: return@setMethodCallHandler result.error(
                                                    "NO_ID",
                                                    "instanceId is required",
                                                    null
                                            )
                            resumePlayback(instanceId)
                            result.success(null)
                        }
                        "startRecording" -> {
                            val instanceId =
                                    call.argument<Int>("instanceId")
                                            ?: return@setMethodCallHandler result.error(
                                                    "NO_ID",
                                                    "instanceId is required",
                                                    null
                                            )
                            val sampleRate = call.argument<Int>("sampleRate") ?: 48000
                            val channelConfig =
                                    call.argument<Int>("channelConfig")
                                            ?: AudioFormat.CHANNEL_IN_MONO
                            val audioFormat =
                                    call.argument<Int>("audioFormat")
                                            ?: AudioFormat.ENCODING_PCM_16BIT
                            val audioSource = call.argument<Int>("audioSource") ?: 0
                            val saveToFile = call.argument<Boolean>("saveToFile") ?: false
                            val preferredDeviceId = call.argument<Int>("preferredDeviceId")

                            if (ContextCompat.checkSelfPermission(
                                            this,
                                            Manifest.permission.RECORD_AUDIO
                                    ) != PackageManager.PERMISSION_GRANTED
                            ) {
                                ActivityCompat.requestPermissions(
                                        this,
                                        arrayOf(Manifest.permission.RECORD_AUDIO),
                                        100
                                )
                                result.error(
                                        "PERMISSION_DENIED",
                                        "Record audio permission not granted",
                                        null
                                )
                                return@setMethodCallHandler
                            }

                            startRecording(
                                    instanceId,
                                    sampleRate,
                                    channelConfig,
                                    audioFormat,
                                    audioSource,
                                    saveToFile,
                                    preferredDeviceId
                            )
                            result.success(null)
                        }
                        "stopRecording" -> {
                            val instanceId =
                                    call.argument<Int>("instanceId")
                                            ?: return@setMethodCallHandler result.error(
                                                    "NO_ID",
                                                    "instanceId is required",
                                                    null
                                            )
                            stopRecording(instanceId)
                            result.success(null)
                        }
                        else -> {
                            result.notImplemented()
                        }
                    }
                }
    }

    private fun registerAudioDeviceCallback() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioDeviceCallback =
                    object : android.media.AudioDeviceCallback() {
                        override fun onAudioDevicesAdded(
                                addedDevices: Array<out AudioDeviceInfo>?
                        ) {
                            super.onAudioDevicesAdded(addedDevices)
                            runOnUiThread { deviceChangeEventSink?.success("changed") }
                        }

                        override fun onAudioDevicesRemoved(
                                removedDevices: Array<out AudioDeviceInfo>?
                        ) {
                            super.onAudioDevicesRemoved(removedDevices)
                            runOnUiThread { deviceChangeEventSink?.success("changed") }
                        }
                    }
            audioManager.registerAudioDeviceCallback(audioDeviceCallback, null)
        }
    }

    private fun unregisterAudioDeviceCallback() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioDeviceCallback?.let {
                val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audioManager.unregisterAudioDeviceCallback(it)
                audioDeviceCallback = null
            }
        }
    }

    private fun getDeviceTypeName(type: Int): String {
        return when (type) {
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "Built-in Earpiece"
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Built-in Speaker"
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Wired Headset"
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "Wired Headphones"
            AudioDeviceInfo.TYPE_LINE_ANALOG -> "Line Analog"
            AudioDeviceInfo.TYPE_LINE_DIGITAL -> "Line Digital"
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth SCO"
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth A2DP"
            AudioDeviceInfo.TYPE_HDMI -> "HDMI"
            AudioDeviceInfo.TYPE_HDMI_ARC -> "HDMI ARC"
            AudioDeviceInfo.TYPE_USB_DEVICE -> "USB Device"
            AudioDeviceInfo.TYPE_USB_ACCESSORY -> "USB Accessory"
            AudioDeviceInfo.TYPE_DOCK -> "Dock"
            AudioDeviceInfo.TYPE_FM -> "FM"
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> "Built-in Mic"
            AudioDeviceInfo.TYPE_FM_TUNER -> "FM Tuner"
            AudioDeviceInfo.TYPE_TV_TUNER -> "TV Tuner"
            AudioDeviceInfo.TYPE_TELEPHONY -> "Telephony"
            AudioDeviceInfo.TYPE_AUX_LINE -> "Aux Line"
            AudioDeviceInfo.TYPE_IP -> "IP"
            AudioDeviceInfo.TYPE_BUS -> "Bus"
            AudioDeviceInfo.TYPE_USB_HEADSET -> "USB Headset"
            AudioDeviceInfo.TYPE_HEARING_AID -> "Hearing Aid"
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE -> "Built-in Speaker Safe"
            AudioDeviceInfo.TYPE_REMOTE_SUBMIX -> "Remote Submix"
            AudioDeviceInfo.TYPE_BLE_HEADSET -> "BLE Headset"
            AudioDeviceInfo.TYPE_BLE_SPEAKER -> "BLE Speaker"
            AudioDeviceInfo.TYPE_BLE_BROADCAST -> "BLE Broadcast"
            else -> "Unknown"
        }
    }

    private fun getAudioModeOptions(): Map<String, Int> {
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

    private fun getAudioSourceOptions(): Map<String, Int> {
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

    private fun getAudioAttributesOptions(): Map<String, Map<String, Int>> {
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

    private fun getFileAudioInfo(filePath: String): Map<String, Int>? {
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
            // MediaCodec typically decodes to PCM_16BIT; KEY_PCM_ENCODING may not be present
            val pcmEncoding =
                    if (fmt.containsKey(MediaFormat.KEY_PCM_ENCODING))
                            fmt.getInteger(MediaFormat.KEY_PCM_ENCODING)
                    else AudioFormat.ENCODING_PCM_16BIT

            // Map channel count to AudioFormat channel mask
            val channelConfig =
                    when (channelCount) {
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
            Log.e("AudioTest", "getFileAudioInfo failed: $e")
            null
        } finally {
            extractor.release()
        }
    }

    private fun getAudioDevices(isOutput: Boolean): List<Map<String, Any>> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val flag =
                if (isOutput) AudioManager.GET_DEVICES_OUTPUTS else AudioManager.GET_DEVICES_INPUTS
        val devices = audioManager.getDevices(flag)

        return devices.map { device ->
            val typeName = getDeviceTypeName(device.type)
            mapOf(
                    "id" to device.id,
                    "name" to device.productName.toString(),
                    "type" to "$typeName (${device.type})", // Changed to String as requested
                    "isSink" to device.isSink,
                    "isSource" to device.isSource
            )
        }
    }

    private fun startPlayback(
            instanceId: Int,
            sampleRate: Int,
            channelConfig: Int,
            audioFormat: Int,
            usage: Int,
            contentType: Int,
            flags: Int,
            preferredDeviceId: Int?,
            filePath: String?
    ) {
        stopPlayback(instanceId)

        val bufferSize = AudioTrack.getMinBufferSize(sampleRate, channelConfig, audioFormat)

        if (bufferSize <= 0) {
            Log.e("AudioTest", "Invalid AudioTrack parameters.")
            return
        }

        val audioAttributes =
                AudioAttributes.Builder()
                        .setUsage(usage)
                        .setContentType(contentType)
                        .setFlags(flags)
                        .build()

        val audioFormatObj =
                AudioFormat.Builder()
                        .setSampleRate(sampleRate)
                        .setChannelMask(channelConfig)
                        .setEncoding(audioFormat)
                        .build()

        val audioTrack =
                AudioTrack(
                        audioAttributes,
                        audioFormatObj,
                        bufferSize,
                        AudioTrack.MODE_STREAM,
                        AudioManager.AUDIO_SESSION_ID_GENERATE
                )

        audioTracks[instanceId] = audioTrack

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && preferredDeviceId != null) {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            val preferredDevice = devices.firstOrNull { it.id == preferredDeviceId }
            if (preferredDevice != null) {
                audioTrack.preferredDevice = preferredDevice
            }
        }

        audioTrack.play()
        isPlayingMap[instanceId] = true
        isPausedMap[instanceId] = false

        val playbackThread = Thread {
            if (filePath != null) {
                playLocalFile(instanceId, audioTrack, filePath)
            } else {
                playSineWave(
                        instanceId,
                        audioTrack,
                        sampleRate,
                        channelConfig,
                        audioFormat,
                        bufferSize
                )
            }
        }
        playbackThreads[instanceId] = playbackThread
        playbackThread.start()
    }

    private fun playLocalFile(instanceId: Int, audioTrack: AudioTrack, filePath: String) {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(filePath)
        } catch (e: Exception) {
            Log.e("AudioTest", "Failed to set data source for extractor: $e")
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
            Log.e("AudioTest", "No audio track found in file.")
            extractor.release()
            return
        }

        extractor.selectTrack(audioTrackIndex)
        val format = extractor.getTrackFormat(audioTrackIndex)
        val mime = format.getString(MediaFormat.KEY_MIME) ?: return

        val codec: MediaCodec
        try {
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()
        } catch (e: Exception) {
            Log.e("AudioTest", "Failed to configure codec: $e")
            extractor.release()
            return
        }

        val info = MediaCodec.BufferInfo()
        var isEOS = false

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
                        codec.queueInputBuffer(
                                inIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM
                        )
                        isEOS = true
                    } else {
                        codec.queueInputBuffer(inIndex, 0, sampleSize, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }

            val outIndex = codec.dequeueOutputBuffer(info, 10000)
            when (outIndex) {
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {}
                MediaCodec.INFO_TRY_AGAIN_LATER -> {}
                else -> {
                    if (outIndex >= 0) {
                        val buffer = codec.getOutputBuffer(outIndex)
                        if (buffer != null && info.size > 0) {
                            val chunk = ByteArray(info.size)
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            buffer.get(chunk)
                            buffer.clear()

                            // Write directly to AudioTrack
                            audioTrack.write(chunk, 0, chunk.size)

                            // Calculate approximate amplitude
                            var maxAmp = 0
                            for (i in chunk.indices step 2) {
                                if (i + 1 < chunk.size) {
                                    val sample =
                                            (chunk[i].toInt() and 0xFF) or
                                                    (chunk[i + 1].toInt() shl 8)
                                    val absSample = Math.abs(sample.toShort().toInt())
                                    if (absSample > maxAmp) {
                                        maxAmp = absSample
                                    }
                                }
                            }
                            val normalizedAmp = maxAmp.toDouble() / Short.MAX_VALUE

                            runOnUiThread {
                                eventSink?.success(
                                        mapOf("id" to instanceId, "amp" to normalizedAmp)
                                )
                            }
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                    }
                }
            }

            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                break
            }
        }

        codec.stop()
        codec.release()
        extractor.release()

        if (isPlayingMap[instanceId] == true) {
            runOnUiThread { stopPlayback(instanceId) }
        }
    }

    private fun playSineWave(
            instanceId: Int,
            audioTrack: AudioTrack,
            sampleRate: Int,
            channelConfig: Int,
            audioFormat: Int,
            bufferSize: Int
    ) {
        val frequency = 440.0 // A4 note
        var angle = 0.0
        val angleIncrement = 2.0 * Math.PI * frequency / sampleRate
        // Each audio frame has one sample per channel; derive channel count from the mask
        val channelCount = Integer.bitCount(channelConfig).coerceAtLeast(1)

        val is8Bit = audioFormat == AudioFormat.ENCODING_PCM_8BIT
        val is16Bit = audioFormat == AudioFormat.ENCODING_PCM_16BIT
        val is24Bit = audioFormat == AudioFormat.ENCODING_PCM_24BIT_PACKED
        val isFloat = audioFormat == AudioFormat.ENCODING_PCM_FLOAT

        val byteBuffer = if (is8Bit || is24Bit) ByteArray(bufferSize) else null
        val shortBuffer = if (is16Bit) ShortArray(bufferSize) else null
        val floatBuffer = if (isFloat) FloatArray(bufferSize) else null

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
                    repeat(channelCount) { ch ->
                        if (i + ch < byteBuffer.size) byteBuffer[i + ch] = sample
                    }
                    i += channelCount
                    angle += angleIncrement
                    val amp = Math.abs(sampleValue - 128)
                    if (amp > maxAmp) maxAmp = amp
                }
                audioTrack.write(byteBuffer, 0, byteBuffer.size)
                normalizedAmp = maxAmp.toDouble() / 128.0
            } else if (is24Bit && byteBuffer != null) {
                var maxAmp = 0
                // 24-bit packed: 3 bytes per sample, channelCount samples per frame
                val bytesPerSample = 3
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
                    repeat(channelCount) { ch ->
                        if (i + ch < floatBuffer.size) floatBuffer[i + ch] = sample
                    }
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
                    repeat(channelCount) { ch ->
                        if (i + ch < shortBuffer.size) shortBuffer[i + ch] = sample
                    }
                    i += channelCount
                    angle += angleIncrement
                    if (Math.abs(sample.toInt()) > maxAmp) maxAmp = Math.abs(sample.toInt())
                }
                audioTrack.write(shortBuffer, 0, shortBuffer.size)
                normalizedAmp = maxAmp.toDouble() / Short.MAX_VALUE
            }

            runOnUiThread { eventSink?.success(mapOf("id" to instanceId, "amp" to normalizedAmp)) }
        }
    }

    /**
     * Smoothly ramps the AudioTrack volume between [from] and [to] over [steps] steps. Each step
     * sleeps [stepMs] milliseconds.
     */
    private fun fadeVolume(
            track: AudioTrack,
            from: Float,
            to: Float,
            steps: Int = 40,
            stepMs: Long = 1
    ) {
        for (i in 0..steps) {
            val vol = from + (to - from) * (i.toFloat() / steps)
            track.setVolume(vol)
            Thread.sleep(stepMs)
        }
    }

    private fun stopPlayback(instanceId: Int) {
        // Fade out before signalling the playback thread to stop
        audioTracks[instanceId]?.let { fadeVolume(it, 1f, 0f) }

        isPlayingMap[instanceId] = false
        isPausedMap[instanceId] = false
        playbackThreads[instanceId]?.join()
        playbackThreads.remove(instanceId)

        // Pause and flush immediately discards unplayed buffer, reducing stop latency
        audioTracks[instanceId]?.pause()
        audioTracks[instanceId]?.flush()
        audioTracks[instanceId]?.stop()
        audioTracks[instanceId]?.release()
        audioTracks.remove(instanceId)
    }

    private fun pausePlayback(instanceId: Int) {
        if (isPlayingMap[instanceId] == true && isPausedMap[instanceId] == false) {
            // Fade out, then pause — prevents the abrupt discontinuity / pop
            audioTracks[instanceId]?.let { fadeVolume(it, 1f, 0f) }
            isPausedMap[instanceId] = true
            audioTracks[instanceId]?.pause()
        }
    }

    private fun resumePlayback(instanceId: Int) {
        if (isPlayingMap[instanceId] == true && isPausedMap[instanceId] == true) {
            // Start at volume 0, resume playback, then fade in
            audioTracks[instanceId]?.setVolume(0f)
            isPausedMap[instanceId] = false
            audioTracks[instanceId]?.play()
            audioTracks[instanceId]?.let { fadeVolume(it, 0f, 1f) }
        }
    }

    private fun startRecording(
            instanceId: Int,
            sampleRate: Int,
            channelConfig: Int,
            audioFormat: Int,
            audioSource: Int,
            saveToFile: Boolean,
            preferredDeviceId: Int?
    ) {
        stopRecording(instanceId)

        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) !=
                        PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        val bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)

        if (bufferSize <= 0) {
            Log.e("AudioTest", "Invalid AudioRecord parameters.")
            return
        }

        val audioRecord =
                AudioRecord.Builder()
                        .setAudioSource(audioSource)
                        .setAudioFormat(
                                AudioFormat.Builder()
                                        .setSampleRate(sampleRate)
                                        .setChannelMask(channelConfig)
                                        .setEncoding(audioFormat)
                                        .build()
                        )
                        .setBufferSizeInBytes(bufferSize)
                        .build()

        audioRecords[instanceId] = audioRecord

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && preferredDeviceId != null) {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val devices = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
            val preferredDevice = devices.firstOrNull { it.id == preferredDeviceId }
            if (preferredDevice != null) {
                audioRecord.preferredDevice = preferredDevice
            }
        }

        audioRecord.startRecording()
        isRecordingMap[instanceId] = true

        val recordThread = Thread {
            val is8Bit = audioFormat == AudioFormat.ENCODING_PCM_8BIT
            val is16Bit = audioFormat == AudioFormat.ENCODING_PCM_16BIT
            val is24Bit = audioFormat == AudioFormat.ENCODING_PCM_24BIT_PACKED
            val isFloat = audioFormat == AudioFormat.ENCODING_PCM_FLOAT

            val byteBuffer = if (is8Bit || is24Bit) ByteArray(bufferSize) else null
            val shortBuffer = if (is16Bit) ShortArray(bufferSize) else null
            val floatBuffer = if (isFloat) FloatArray(bufferSize) else null

            var randomAccessFile: java.io.RandomAccessFile? = null
            var totalAudioLen: Long = 0
            var outputFilePath: String? = null

            if (saveToFile) {
                try {
                    val timeStamp =
                            java.text.SimpleDateFormat("yyyyMMdd_HHmmss", java.util.Locale.US)
                                    .format(java.util.Date())
                    val fileName = "Record_$timeStamp.wav"
                    val musicDir = getExternalFilesDir(android.os.Environment.DIRECTORY_MUSIC)
                    if (musicDir != null) {
                        if (!musicDir.exists()) musicDir.mkdirs()
                        val file = java.io.File(musicDir, fileName)
                        outputFilePath = file.absolutePath
                        randomAccessFile = java.io.RandomAccessFile(file, "rw")
                        // Write dummy header (44 bytes)
                        val header = ByteArray(44)
                        randomAccessFile.write(header)
                    }
                } catch (e: Exception) {
                    Log.e("AudioTest", "Failed to create WAV file: $e")
                }
            }

            while (isRecordingMap[instanceId] == true) {
                var normalizedAmp = 0.0

                if (is8Bit && byteBuffer != null) {
                    val readResult = audioRecord.read(byteBuffer, 0, byteBuffer.size)
                    if (readResult > 0) {
                        var maxAmp = 0
                        for (i in 0 until readResult) {
                            val sample = (byteBuffer[i].toInt() and 0xFF) - 128
                            if (Math.abs(sample) > maxAmp) {
                                maxAmp = Math.abs(sample)
                            }
                        }
                        normalizedAmp = maxAmp.toDouble() / 128.0
                        if (randomAccessFile != null) {
                            try {
                                randomAccessFile.write(byteBuffer, 0, readResult)
                                totalAudioLen += readResult
                            } catch (e: Exception) {
                                Log.e("AudioTest", "Failed to write 8-bit PCM: $e")
                            }
                        }
                    }
                } else if (is24Bit && byteBuffer != null) {
                    val readResult = audioRecord.read(byteBuffer, 0, byteBuffer.size)
                    if (readResult > 0) {
                        var maxAmp = 0
                        for (i in 0 until readResult - 2 step 3) {
                            // Little endian parsing
                            val b1 = byteBuffer[i].toInt() and 0xFF
                            val b2 = byteBuffer[i + 1].toInt() and 0xFF
                            val b3 = byteBuffer[i + 2].toInt() // keep sign from highest byte

                            val sampleInt = b1 or (b2 shl 8) or (b3 shl 16)
                            if (Math.abs(sampleInt) > maxAmp) {
                                maxAmp = Math.abs(sampleInt)
                            }
                        }
                        normalizedAmp = maxAmp.toDouble() / 8388607.0
                        if (randomAccessFile != null) {
                            try {
                                randomAccessFile.write(byteBuffer, 0, readResult)
                                totalAudioLen += readResult
                            } catch (e: Exception) {
                                Log.e("AudioTest", "Failed to write 24-bit PCM: $e")
                            }
                        }
                    }
                } else if (isFloat && floatBuffer != null) {
                    val readResult =
                            audioRecord.read(
                                    floatBuffer,
                                    0,
                                    floatBuffer.size,
                                    AudioRecord.READ_BLOCKING
                            )
                    if (readResult > 0) {
                        var maxAmp = 0.0f
                        for (i in 0 until readResult) {
                            if (Math.abs(floatBuffer[i]) > maxAmp) {
                                maxAmp = Math.abs(floatBuffer[i])
                            }
                        }
                        normalizedAmp = maxAmp.toDouble()
                        if (randomAccessFile != null) {
                            try {
                                val bytes = ByteArray(readResult * 4)
                                java.nio.ByteBuffer.wrap(bytes)
                                        .order(java.nio.ByteOrder.LITTLE_ENDIAN)
                                        .asFloatBuffer()
                                        .put(floatBuffer, 0, readResult)
                                randomAccessFile.write(bytes)
                                totalAudioLen += bytes.size
                            } catch (e: Exception) {
                                Log.e("AudioTest", "Failed to write float PCM: $e")
                            }
                        }
                    }
                } else if (shortBuffer != null) {
                    val readResult = audioRecord.read(shortBuffer, 0, shortBuffer.size)
                    if (readResult > 0) {
                        var maxAmp = 0
                        for (i in 0 until readResult) {
                            if (Math.abs(shortBuffer[i].toInt()) > maxAmp) {
                                maxAmp = Math.abs(shortBuffer[i].toInt())
                            }
                        }
                        normalizedAmp = maxAmp.toDouble() / Short.MAX_VALUE
                        if (randomAccessFile != null) {
                            try {
                                val bytes = ByteArray(readResult * 2)
                                java.nio.ByteBuffer.wrap(bytes)
                                        .order(java.nio.ByteOrder.LITTLE_ENDIAN)
                                        .asShortBuffer()
                                        .put(shortBuffer, 0, readResult)
                                randomAccessFile.write(bytes)
                                totalAudioLen += bytes.size
                            } catch (e: Exception) {
                                Log.e("AudioTest", "Failed to write 16-bit PCM: $e")
                            }
                        }
                    }
                }

                runOnUiThread {
                    eventSink?.success(mapOf("id" to instanceId, "amp" to normalizedAmp))
                }
            }

            if (randomAccessFile != null) {
                try {
                    val totalDataLen = totalAudioLen + 36
                    val longSampleRate = sampleRate.toLong()
                    val channels = if (channelConfig == AudioFormat.CHANNEL_IN_STEREO) 2 else 1

                    val bitsPerSample =
                            when {
                                is8Bit -> 8
                                is16Bit -> 16
                                is24Bit -> 24
                                isFloat -> 32
                                else -> 16
                            }
                    val byteRate = bitsPerSample * sampleRate * channels / 8

                    val header = ByteArray(44)
                    header[0] = 'R'.code.toByte() // RIFF/WAVE header
                    header[1] = 'I'.code.toByte()
                    header[2] = 'F'.code.toByte()
                    header[3] = 'F'.code.toByte()
                    header[4] = (totalDataLen and 0xff).toByte()
                    header[5] = ((totalDataLen shr 8) and 0xff).toByte()
                    header[6] = ((totalDataLen shr 16) and 0xff).toByte()
                    header[7] = ((totalDataLen shr 24) and 0xff).toByte()
                    header[8] = 'W'.code.toByte()
                    header[9] = 'A'.code.toByte()
                    header[10] = 'V'.code.toByte()
                    header[11] = 'E'.code.toByte()
                    header[12] = 'f'.code.toByte() // 'fmt ' chunk
                    header[13] = 'm'.code.toByte()
                    header[14] = 't'.code.toByte()
                    header[15] = ' '.code.toByte()
                    header[16] = 16 // 4 bytes: size of 'fmt ' chunk
                    header[17] = 0
                    header[18] = 0
                    header[19] = 0
                    header[20] = if (isFloat) 3 else 1 // format = 1 for PCM, 3 for IEEE float
                    header[21] = 0
                    header[22] = channels.toByte()
                    header[23] = 0
                    header[24] = (longSampleRate and 0xff).toByte()
                    header[25] = ((longSampleRate shr 8) and 0xff).toByte()
                    header[26] = ((longSampleRate shr 16) and 0xff).toByte()
                    header[27] = ((longSampleRate shr 24) and 0xff).toByte()
                    header[28] = (byteRate and 0xff).toByte()
                    header[29] = ((byteRate shr 8) and 0xff).toByte()
                    header[30] = ((byteRate shr 16) and 0xff).toByte()
                    header[31] = ((byteRate shr 24) and 0xff).toByte()
                    header[32] = (channels * bitsPerSample / 8).toByte() // block align
                    header[33] = 0
                    header[34] = bitsPerSample.toByte() // bits per sample
                    header[35] = 0
                    header[36] = 'd'.code.toByte()
                    header[37] = 'a'.code.toByte()
                    header[38] = 't'.code.toByte()
                    header[39] = 'a'.code.toByte()
                    header[40] = (totalAudioLen and 0xff).toByte()
                    header[41] = ((totalAudioLen shr 8) and 0xff).toByte()
                    header[42] = ((totalAudioLen shr 16) and 0xff).toByte()
                    header[43] = ((totalAudioLen shr 24) and 0xff).toByte()

                    randomAccessFile.seek(0)
                    randomAccessFile.write(header)
                    randomAccessFile.close()

                    if (outputFilePath != null) {
                        runOnUiThread {
                            android.widget.Toast.makeText(
                                            this@MainActivity,
                                            "WAV file successfully saved",
                                            android.widget.Toast.LENGTH_SHORT
                                    )
                                    .show()
                            eventSink?.success(mapOf("id" to instanceId, "path" to outputFilePath))
                        }
                    }
                } catch (e: Exception) {
                    Log.e("AudioTest", "Failed to update WAV header: $e")
                }
            }
        }
        recordThreads[instanceId] = recordThread
        recordThread.start()
    }

    private fun stopRecording(instanceId: Int) {
        isRecordingMap[instanceId] = false
        recordThreads[instanceId]?.join()
        recordThreads.remove(instanceId)

        audioRecords[instanceId]?.stop()
        audioRecords[instanceId]?.release()
        audioRecords.remove(instanceId)
    }
}
