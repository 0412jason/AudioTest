package com.example.audiotest

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val AUDIO_CHANNEL = "com.example.audiotest/audio"
    private val AMPLITUDE_CHANNEL = "com.example.audiotest/amplitude"
    private val DEVICE_CHANGE_CHANNEL = "com.example.audiotest/deviceChanges"
    private val AUDIO_TRACK_INFO_CHANNEL = "com.example.audiotest/audioTrackInfo"
    private val AUDIO_RECORD_INFO_CHANNEL = "com.example.audiotest/audioRecordInfo"

    private lateinit var deviceManager: AudioDeviceManager
    private lateinit var playbackManager: AudioPlaybackManager
    private lateinit var recordingManager: AudioRecordingManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        deviceManager = AudioDeviceManager(this)
        playbackManager = AudioPlaybackManager(this)
        recordingManager = AudioRecordingManager(this)

        // Setup EventChannels
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, AMPLITUDE_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    playbackManager.setAmplitudeSink(events)
                    recordingManager.setAmplitudeSink(events)
                }
                override fun onCancel(arguments: Any?) {
                    playbackManager.setAmplitudeSink(null)
                    recordingManager.setAmplitudeSink(null)
                }
            })

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANGE_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    deviceManager.setDeviceChangeEventSink(events)
                }
                override fun onCancel(arguments: Any?) {
                    deviceManager.setDeviceChangeEventSink(null)
                }
            })

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_TRACK_INFO_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    playbackManager.setTrackInfoSink(events)
                }
                override fun onCancel(arguments: Any?) {
                    playbackManager.setTrackInfoSink(null)
                }
            })

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_RECORD_INFO_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    recordingManager.setRecordInfoSink(events)
                }
                override fun onCancel(arguments: Any?) {
                    recordingManager.setRecordInfoSink(null)
                }
            })

        // Setup MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAudioDevices" -> {
                        val isOutput = call.argument<Boolean>("isOutput") ?: true
                        result.success(deviceManager.getAudioDevices(isOutput))
                    }
                    "getAudioAttributesOptions" -> result.success(AudioInfoHelper.getAudioAttributesOptions())
                    "getAudioSourceOptions" -> result.success(AudioInfoHelper.getAudioSourceOptions())
                    "getAudioModeOptions" -> result.success(AudioInfoHelper.getAudioModeOptions())
                    "getFileAudioInfo" -> {
                        val filePath = call.argument<String>("filePath") ?: return@setMethodCallHandler result.error("NO_PATH", "filePath is required", null)
                        val info = AudioInfoHelper.getFileAudioInfo(filePath)
                        if (info == null) result.error("READ_ERROR", "Could not read audio info", null) else result.success(info)
                    }
                    "getAudioMode" -> {
                        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        result.success(am.mode)
                    }
                    "setAudioMode" -> {
                        val mode = call.argument<Int>("audioMode") ?: AudioManager.MODE_NORMAL
                        (getSystemService(Context.AUDIO_SERVICE) as AudioManager).mode = mode
                        result.success(null)
                    }
                    "setCommunicationDevice" -> {
                        val deviceId = call.argument<Int>("deviceId")
                        result.success(deviceManager.setCommunicationDevice(deviceId))
                    }
                    "startPlayback" -> {
                        val id = call.argument<Int>("instanceId") ?: return@setMethodCallHandler result.error("NO_ID", "instanceId required", null)
                        playbackManager.startPlayback(
                            id,
                            call.argument<Int>("sampleRate") ?: 48000,
                            call.argument<Int>("channelConfig") ?: android.media.AudioFormat.CHANNEL_OUT_MONO,
                            call.argument<Int>("audioFormat") ?: android.media.AudioFormat.ENCODING_PCM_16BIT,
                            call.argument<Int>("usage") ?: android.media.AudioAttributes.USAGE_MEDIA,
                            call.argument<Int>("contentType") ?: android.media.AudioAttributes.CONTENT_TYPE_MUSIC,
                            call.argument<Int>("flags") ?: 0,
                            call.argument<Int>("preferredDeviceId"),
                            call.argument<String>("filePath"),
                            call.argument<Boolean>("offload") ?: false
                        )
                        result.success(null)
                    }
                    "stopPlayback" -> {
                        val id = call.argument<Int>("instanceId") ?: return@setMethodCallHandler result.error("NO_ID", "instanceId required", null)
                        playbackManager.stopPlayback(id)
                        result.success(null)
                    }
                    "pausePlayback" -> {
                        val id = call.argument<Int>("instanceId") ?: return@setMethodCallHandler result.error("NO_ID", "instanceId required", null)
                        playbackManager.pausePlayback(id)
                        result.success(null)
                    }
                    "resumePlayback" -> {
                        val id = call.argument<Int>("instanceId") ?: return@setMethodCallHandler result.error("NO_ID", "instanceId required", null)
                        playbackManager.resumePlayback(id)
                        result.success(null)
                    }
                    "startRecording" -> {
                        val id = call.argument<Int>("instanceId") ?: return@setMethodCallHandler result.error("NO_ID", "instanceId required", null)
                        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), 100)
                            return@setMethodCallHandler result.error("PERMISSION_DENIED", "Record audio permission not granted", null)
                        }
                        recordingManager.startRecording(
                            id,
                            call.argument<Int>("sampleRate") ?: 48000,
                            call.argument<Int>("channelConfig") ?: android.media.AudioFormat.CHANNEL_IN_MONO,
                            call.argument<Int>("audioFormat") ?: android.media.AudioFormat.ENCODING_PCM_16BIT,
                            call.argument<Int>("audioSource") ?: 0,
                            call.argument<Boolean>("saveToFile") ?: false,
                            call.argument<Int>("preferredDeviceId")
                        )
                        result.success(null)
                    }
                    "stopRecording" -> {
                        val id = call.argument<Int>("instanceId") ?: return@setMethodCallHandler result.error("NO_ID", "instanceId required", null)
                        recordingManager.stopRecording(id)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
