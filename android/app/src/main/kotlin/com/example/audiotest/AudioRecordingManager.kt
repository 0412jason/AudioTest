package com.example.audiotest

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.os.Build
import android.os.Environment
import android.util.Log
import androidx.core.app.ActivityCompat
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class AudioRecordingManager(private val activity: Activity) {
    private val context: Context = activity.applicationContext
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private val audioRecords = mutableMapOf<Int, AudioRecord>()
    private val recordThreads = mutableMapOf<Int, Thread>()
    private val isRecordingMap = mutableMapOf<Int, Boolean>()

    private var amplitudeSink: EventChannel.EventSink? = null
    private var recordInfoSink: EventChannel.EventSink? = null

    fun setAmplitudeSink(sink: EventChannel.EventSink?) {
        amplitudeSink = sink
    }

    fun setRecordInfoSink(sink: EventChannel.EventSink?) {
        recordInfoSink = sink
    }

    fun startRecording(
        instanceId: Int,
        sampleRate: Int,
        channelConfig: Int,
        audioFormat: Int,
        audioSource: Int,
        saveToFile: Boolean,
        preferredDeviceId: Int?
    ) {
        stopRecording(instanceId)

        if (ActivityCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            return
        }

        val bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        if (bufferSize <= 0) {
            Log.e("AudioRecordingManager", "Invalid AudioRecord parameters.")
            return
        }

        val audioRecord = AudioRecord.Builder()
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

        preferredDeviceId?.let { deviceId ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.id == deviceId }?.let {
                    audioRecord.preferredDevice = it
                }
            }
        }

        audioRecord.startRecording()
        isRecordingMap[instanceId] = true

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            audioRecord.addOnRoutingChangedListener({ router -> sendAudioRecordInfo(instanceId, router as AudioRecord) }, null)
        }
        sendAudioRecordInfo(instanceId, audioRecord)

        val recordThread = Thread {
            val is8Bit = audioFormat == AudioFormat.ENCODING_PCM_8BIT
            val is16Bit = audioFormat == AudioFormat.ENCODING_PCM_16BIT
            val is24Bit = audioFormat == AudioFormat.ENCODING_PCM_24BIT_PACKED
            val isFloat = audioFormat == AudioFormat.ENCODING_PCM_FLOAT

            val framesPerUpdate = sampleRate / 40 // ~25ms
            val channels = AudioPcmHelper.getChannelCount(channelConfig)
            val bytesPerSample = AudioPcmHelper.getBytesPerSample(audioFormat)
            val bytesPerFrame = channels * bytesPerSample
            val updateBufferSizeInBytes = framesPerUpdate * bytesPerFrame

            val byteBuffer = if (is8Bit || is24Bit) ByteArray(updateBufferSizeInBytes) else null
            val shortBuffer = if (is16Bit) ShortArray(framesPerUpdate * channels) else null
            val floatBuffer = if (isFloat) FloatArray(framesPerUpdate * channels) else null

            var raf: RandomAccessFile? = null
            var totalAudioLen: Long = 0
            var outputFilePath: String? = null

            if (saveToFile) {
                try {
                    val timeStamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
                    val fileName = "Record_$timeStamp.wav"
                    val musicDir = activity.getExternalFilesDir(Environment.DIRECTORY_MUSIC)
                    if (musicDir != null) {
                        if (!musicDir.exists()) musicDir.mkdirs()
                        val file = File(musicDir, fileName)
                        outputFilePath = file.absolutePath
                        raf = RandomAccessFile(file, "rw")
                        raf.write(ByteArray(44)) // Dummy header
                    }
                } catch (e: Exception) {
                    Log.e("AudioRecordingManager", "Failed to create WAV file: $e")
                }
            }

            while (isRecordingMap[instanceId] == true) {
                var normalizedAmp = 0.0

                if (is8Bit && byteBuffer != null) {
                    val read = audioRecord.read(byteBuffer, 0, byteBuffer.size)
                    if (read > 0) {
                        normalizedAmp = AudioPcmHelper.calculateMaxAmplitude(byteBuffer, 0, read, audioFormat, bytesPerFrame)
                        raf?.let { it.write(byteBuffer, 0, read); totalAudioLen += read }
                    }
                } else if (is24Bit && byteBuffer != null) {
                    val read = audioRecord.read(byteBuffer, 0, byteBuffer.size)
                    if (read > 0) {
                        normalizedAmp = AudioPcmHelper.calculateMaxAmplitude(byteBuffer, 0, read, audioFormat, bytesPerFrame)
                        raf?.let { it.write(byteBuffer, 0, read); totalAudioLen += read }
                    }
                } else if (isFloat && floatBuffer != null) {
                    val read = audioRecord.read(floatBuffer, 0, floatBuffer.size, AudioRecord.READ_BLOCKING)
                    if (read > 0) {
                        var maxAmp = 0.0f
                        for (i in 0 until read) if (Math.abs(floatBuffer[i]) > maxAmp) maxAmp = Math.abs(floatBuffer[i])
                        normalizedAmp = maxAmp.toDouble()
                        raf?.let {
                            val bytes = ByteArray(read * 4)
                            java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN).asFloatBuffer().put(floatBuffer, 0, read)
                            it.write(bytes)
                            totalAudioLen += bytes.size
                        }
                    }
                } else if (shortBuffer != null) {
                    val read = audioRecord.read(shortBuffer, 0, shortBuffer.size)
                    if (read > 0) {
                        var maxAmp = 0
                        for (i in 0 until read) if (Math.abs(shortBuffer[i].toInt()) > maxAmp) maxAmp = Math.abs(shortBuffer[i].toInt())
                        normalizedAmp = maxAmp.toDouble() / Short.MAX_VALUE
                        raf?.let {
                            val bytes = ByteArray(read * 2)
                            java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(shortBuffer, 0, read)
                            it.write(bytes)
                            totalAudioLen += bytes.size
                        }
                    }
                }
                activity.runOnUiThread { amplitudeSink?.success(mapOf("id" to instanceId, "amp" to normalizedAmp)) }
            }

            raf?.let {
                try {
                    updateWavHeader(it, totalAudioLen, sampleRate, channelConfig, audioFormat)
                    it.close()
                    outputFilePath?.let { path ->
                        activity.runOnUiThread {
                            android.widget.Toast.makeText(activity, "WAV file successfully saved", android.widget.Toast.LENGTH_SHORT).show()
                            amplitudeSink?.success(mapOf("id" to instanceId, "path" to path))
                        }
                    }
                } catch (e: Exception) {
                    Log.e("AudioRecordingManager", "Failed to update WAV header: $e")
                }
            }
        }
        recordThreads[instanceId] = recordThread
        recordThread.start()
    }

    fun stopRecording(instanceId: Int) {
        isRecordingMap[instanceId] = false
        recordThreads[instanceId]?.join()
        recordThreads.remove(instanceId)

        audioRecords[instanceId]?.apply {
            try {
                stop()
                release()
            } catch (e: Exception) {
                Log.e("AudioRecordingManager", "Error stopping record: $e")
            }
        }
        audioRecords.remove(instanceId)
    }

    private fun updateWavHeader(raf: RandomAccessFile, totalAudioLen: Long, sampleRate: Int, channelConfig: Int, audioFormat: Int) {
        val channels = if (channelConfig == AudioFormat.CHANNEL_IN_STEREO) 2 else 1
        val bitsPerSample = when (audioFormat) {
            AudioFormat.ENCODING_PCM_8BIT -> 8
            AudioFormat.ENCODING_PCM_16BIT -> 16
            AudioFormat.ENCODING_PCM_24BIT_PACKED -> 24
            AudioFormat.ENCODING_PCM_FLOAT -> 32
            else -> 16
        }
        val isFloat = audioFormat == AudioFormat.ENCODING_PCM_FLOAT
        val byteRate = bitsPerSample * sampleRate * channels / 8
        val totalDataLen = totalAudioLen + 36

        val header = ByteArray(44)
        header[0] = 'R'.code.toByte()
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
        header[12] = 'f'.code.toByte()
        header[13] = 'm'.code.toByte()
        header[14] = 't'.code.toByte()
        header[15] = ' '.code.toByte()
        header[16] = 16
        header[17] = 0
        header[18] = 0
        header[19] = 0
        header[20] = if (isFloat) 3 else 1
        header[21] = 0
        header[22] = channels.toByte()
        header[23] = 0
        header[24] = (sampleRate.toLong() and 0xff).toByte()
        header[25] = ((sampleRate.toLong() shr 8) and 0xff).toByte()
        header[26] = ((sampleRate.toLong() shr 16) and 0xff).toByte()
        header[27] = ((sampleRate.toLong() shr 24) and 0xff).toByte()
        header[28] = (byteRate.toLong() and 0xff).toByte()
        header[29] = ((byteRate.toLong() shr 8) and 0xff).toByte()
        header[30] = ((byteRate.toLong() shr 16) and 0xff).toByte()
        header[31] = ((byteRate.toLong() shr 24) and 0xff).toByte()
        header[32] = (channels * bitsPerSample / 8).toByte()
        header[33] = 0
        header[34] = bitsPerSample.toByte()
        header[35] = 0
        header[36] = 'd'.code.toByte()
        header[37] = 'a'.code.toByte()
        header[38] = 't'.code.toByte()
        header[39] = 'a'.code.toByte()
        header[40] = (totalAudioLen and 0xff).toByte()
        header[41] = ((totalAudioLen shr 8) and 0xff).toByte()
        header[42] = ((totalAudioLen shr 16) and 0xff).toByte()
        header[43] = ((totalAudioLen shr 24) and 0xff).toByte()

        raf.seek(0)
        raf.write(header)
    }

    private fun sendAudioRecordInfo(instanceId: Int, record: AudioRecord) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val infoMap = mutableMapOf<String, Any>(
                "id" to instanceId,
                "sampleRate" to record.sampleRate,
                "channelCount" to record.channelCount,
                "audioFormat" to record.audioFormat,
                "audioSource" to record.audioSource
            )

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                val routedDevicesList = mutableListOf<Map<String, Any>>()

                record.routedDevice?.let { device ->
                    routedDevicesList.add(mapOf(
                        "name" to device.productName.toString(),
                        "type" to "${AudioDeviceManager(context).getDeviceTypeName(device.type)} (${device.type})",
                        "id" to device.id
                    ))
                }

                if (routedDevicesList.isNotEmpty()) {
                    infoMap["routedDevices"] = routedDevicesList
                }
            }
            activity.runOnUiThread { recordInfoSink?.success(infoMap) }
        }
    }
}
