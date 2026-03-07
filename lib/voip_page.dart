import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:collection';
import 'audio_engine.dart';
import 'widgets/split_view_layout.dart';
import 'widgets/audio_config_fields.dart';
import 'widgets/waveform_display.dart';
import 'widgets/audio_info_card.dart';

class VoIPPage extends StatelessWidget {
  const VoIPPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SplitViewLayout(
        title: 'VoIP Configuration',
        builder: () => const VoIPConfigWidget(),
        initialSplitCount: 1,
      ),
    );
  }
}

class VoIPConfigWidget extends StatefulWidget {
  const VoIPConfigWidget({super.key});

  @override
  State<VoIPConfigWidget> createState() => _VoIPConfigWidgetState();
}

class _VoIPConfigWidgetState extends State<VoIPConfigWidget> {
  bool _isCalling = false;
  bool _isRinging = false;
  bool _saveToFile = false;
  String? _savedFilePath;
  late final int _instanceId;

  final TextEditingController _txSampleRateController = TextEditingController(
    text: "48000",
  );
  final TextEditingController _rxSampleRateController = TextEditingController(
    text: "48000",
  );

  int _selectedChannelConfig = 12; // AudioFormat.CHANNEL_IN_STEREO
  int _selectedAudioFormat = 2; // AudioFormat.ENCODING_PCM_16BIT

  int _selectedPlaybackChannelConfig = 12; // AudioFormat.CHANNEL_OUT_STEREO
  int _selectedPlaybackAudioFormat = 2; // AudioFormat.ENCODING_PCM_16BIT

  List<AudioDevice> _inputDevices = [];
  List<AudioDevice> _outputDevices = [];
  AudioDevice? _selectedInputDevice;
  AudioDevice? _selectedOutputDevice;

  final int _selectedSource = 7; // VOICE_COMMUNICATION default
  final int _selectedMode = 3; // MODE_IN_COMMUNICATION default

  final Queue<double> _amplitudes = Queue();
  final ValueNotifier<int> _ampUpdateNotifier = ValueNotifier<int>(0);
  StreamSubscription? _amplitudeSub;
  StreamSubscription? _deviceChangeSub;
  int? _originalMode;

  AudioInfo? _actualRxAudioInfo;
  AudioInfo? _actualTxAudioInfo;
  StreamSubscription? _audioInfoSub;
  static const int _maxAmplitudes = 100;

  @override
  void initState() {
    super.initState();
    _instanceId = hashCode;
    AudioEngine.initAttributeMaps().then((_) => _loadAudioAttributesOptions());
    _loadDevices();
    _deviceChangeSub = AudioEngine.deviceChangeStream.listen((_) {
      _loadDevices();
    });
    for (int i = 0; i < _maxAmplitudes; i++) {
      _amplitudes.add(0.0);
    }
  }

  @override
  void dispose() {
    _txSampleRateController.dispose();
    _rxSampleRateController.dispose();
    _ampUpdateNotifier.dispose();
    _amplitudeSub?.cancel();
    _deviceChangeSub?.cancel();
    _audioInfoSub?.cancel();
    _stopCall();
    super.dispose();
  }

  Future<void> _loadAudioAttributesOptions() async {
    await AudioEngine.initAttributeMaps();
  }

  Future<void> _loadDevices() async {
    final inputs = await AudioEngine.getAudioDevices(false);
    final outputs = await AudioEngine.getAudioDevices(true);
    if (mounted) {
      setState(() {
        _inputDevices = inputs;
        _outputDevices = outputs;

        if (_selectedInputDevice != null) {
          try {
            _selectedInputDevice = inputs.firstWhere(
              (d) => d.id == _selectedInputDevice!.id,
            );
          } catch (_) {
            _selectedInputDevice = null;
          }
        }
        if (_selectedOutputDevice != null) {
          try {
            _selectedOutputDevice = outputs.firstWhere(
              (d) => d.id == _selectedOutputDevice!.id,
            );
          } catch (_) {
            _selectedOutputDevice = null;
          }
        }
      });
    }
  }

  void _startCall() async {
    setState(() {
      _isCalling = true;
      _isRinging = true;
      _savedFilePath = null;
    });

    _originalMode = await AudioEngine.getAudioMode();

    // 1. Set mode to ringtone (1 = MODE_RINGTONE)
    await AudioEngine.setAudioMode(1);

    int ringtoneId = _instanceId + 2;

    // 2. Play 2 seconds of beep beep sound as ringtone
    await AudioEngine.startPlayback(
      instanceId: ringtoneId,
      sampleRate: 48000,
      channelConfig: 12, // Stereo out
      audioFormat: 2, // 16-bit PCM
      usage: 6, // USAGE_NOTIFICATION_RINGTONE
      contentType: 4, // CONTENT_TYPE_SONIFICATION
      flags: 0,
    );

    // 2 seconds of beeps (400ms on, 100ms off, 4 times)
    for (int i = 0; i < 4; i++) {
      if (!mounted || !_isCalling) {
        await AudioEngine.stopPlayback(ringtoneId);
        return;
      }
      if (i > 0) {
        await AudioEngine.resumePlayback(ringtoneId);
      }
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted || !_isCalling) {
        await AudioEngine.stopPlayback(ringtoneId);
        return;
      }
      await AudioEngine.pausePlayback(ringtoneId);
      await Future.delayed(const Duration(milliseconds: 100));
    }

    await AudioEngine.stopPlayback(ringtoneId);

    if (!mounted || !_isCalling) return;

    setState(() {
      _isRinging = false;
    });

    // 3. Normal VoIP setup
    await AudioEngine.setAudioMode(_selectedMode);
    await AudioEngine.setCommunicationDevice(_selectedOutputDevice?.id);

    int txSampleRate = int.tryParse(_txSampleRateController.text) ?? 48000;
    int rxSampleRate = int.tryParse(_rxSampleRateController.text) ?? 48000;

    // Subscribe BEFORE startPlayback/startRecording so we don't miss initial events.
    _amplitudeSub?.cancel();
    _amplitudeSub = AudioEngine.amplitudeStream.listen((event) {
      if (mounted && event['id'] == _instanceId) {
        if (event.containsKey('path')) {
          setState(() {
            _savedFilePath = event['path'] as String;
          });
        } else if (event.containsKey('amp')) {
          _amplitudes.addLast(event['amp'] as double);
          if (_amplitudes.length > _maxAmplitudes) {
            _amplitudes.removeFirst();
          }
          _ampUpdateNotifier.value++;
        }
      }
    });

    _audioInfoSub?.cancel();
    _audioInfoSub = AudioEngine.audioInfoStream.listen((info) {
      if (mounted) {
        if (info.id == _instanceId + 1) {
          setState(() {
            _actualRxAudioInfo = info;
          });
        } else if (info.id == _instanceId) {
          setState(() {
            _actualTxAudioInfo = info;
          });
        }
      }
    });

    // Start playback (receiver) sine wave
    await AudioEngine.startPlayback(
      instanceId: _instanceId + 1,
      sampleRate: rxSampleRate,
      channelConfig: _selectedPlaybackChannelConfig,
      audioFormat: _selectedPlaybackAudioFormat,
      usage: 2, // USAGE_VOICE_COMMUNICATION
      contentType: 1, // CONTENT_TYPE_SPEECH
      flags: 0,
      preferredDeviceId: _selectedOutputDevice?.id,
    );

    if (!mounted || !_isCalling) {
      await AudioEngine.stopPlayback(_instanceId + 1);
      return;
    }

    // Start recording (sender)
    await AudioEngine.startRecording(
      instanceId: _instanceId,
      sampleRate: txSampleRate,
      channelConfig: _selectedChannelConfig,
      audioFormat: _selectedAudioFormat,
      audioSource: _selectedSource,
      preferredDeviceId: _selectedInputDevice?.id,
      saveToFile: _saveToFile,
    );
  }

  void _stopCall() async {
    setState(() {
      _isCalling = false;
      _isRinging = false;
      _actualRxAudioInfo = null;
      _actualTxAudioInfo = null;
      _amplitudes.clear();
      for (int i = 0; i < _maxAmplitudes; i++) {
        _amplitudes.add(0.0);
      }
    });
    _ampUpdateNotifier.value++;
    _audioInfoSub?.cancel();
    await AudioEngine.stopRecording(_instanceId);
    await AudioEngine.stopPlayback(_instanceId + 1);
    await AudioEngine.stopPlayback(_instanceId + 2);
    await AudioEngine.setCommunicationDevice(null);

    if (_originalMode != null) {
      await AudioEngine.setAudioMode(_originalMode!);
      _originalMode = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  const Text(
                    '--- RX (Receive / Receiver) ---',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),

                  AudioConfigFields.sampleRateField(
                    controller: _rxSampleRateController,
                    enabled: !_isCalling,
                    label: 'RX Sample Rate (Hz)',
                  ),
                  const SizedBox(height: 8),

                  AudioConfigFields.channelConfigDropdown(
                    customLabel: 'RX Channel Config',
                    initialSelection: _selectedPlaybackChannelConfig,
                    enabled: !_isCalling,
                    isInput: false,
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedPlaybackChannelConfig = v);
                      }
                    },
                  ),
                  const SizedBox(height: 8),

                  AudioConfigFields.audioFormatDropdown(
                    label: 'RX Audio Format',
                    initialSelection: _selectedPlaybackAudioFormat,
                    enabled: !_isCalling,
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedPlaybackAudioFormat = v);
                      }
                    },
                  ),
                  const SizedBox(height: 8),

                  AudioConfigFields.deviceDropdown(
                    label: 'RX Output Device (Speaker/Earpiece)',
                    initialSelection: _selectedOutputDevice,
                    enabled: !_isRinging,
                    devices: _outputDevices,
                    defaultLabel: "Default Output",
                    onSelected: (v) async {
                      setState(() => _selectedOutputDevice = v);
                      if (_isCalling && !_isRinging) {
                        await AudioEngine.setCommunicationDevice(v?.id);
                      }
                    },
                  ),
                  const SizedBox(height: 24),

                  const Text(
                    '--- TX (Transmit / Sender) ---',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),

                  AudioConfigFields.sampleRateField(
                    controller: _txSampleRateController,
                    enabled: !_isCalling,
                    label: 'TX Sample Rate (Hz)',
                  ),
                  const SizedBox(height: 8),

                  AudioConfigFields.channelConfigDropdown(
                    customLabel: 'TX Channel Config',
                    initialSelection: _selectedChannelConfig,
                    enabled: !_isCalling,
                    isInput: true,
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedChannelConfig = v);
                      }
                    },
                  ),
                  const SizedBox(height: 8),

                  AudioConfigFields.audioFormatDropdown(
                    label: 'TX Audio Format',
                    initialSelection: _selectedAudioFormat,
                    enabled: !_isCalling,
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedAudioFormat = v);
                      }
                    },
                  ),
                  const SizedBox(height: 8),

                  AudioConfigFields.deviceDropdown(
                    label: 'TX Input Device (Microphone)',
                    initialSelection: _selectedInputDevice,
                    enabled: !_isCalling,
                    devices: _inputDevices,
                    defaultLabel: "Default Input",
                    onSelected: (v) => setState(() => _selectedInputDevice = v),
                  ),
                  const SizedBox(height: 16),

                  CheckboxListTile(
                    title: Text(
                      'TX Save to WAV File',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    value: _saveToFile,
                    onChanged: _isCalling
                        ? null
                        : (bool? value) {
                            setState(() {
                              _saveToFile = value ?? false;
                            });
                          },
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (_savedFilePath != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Text(
                        'Saved: $_savedFilePath',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.green,
                        ),
                      ),
                    ),

                  if (_isCalling &&
                      !_isRinging &&
                      _actualRxAudioInfo != null) ...[
                    const SizedBox(height: 16),
                    AudioInfoCard(
                      title: 'Actual RX AudioTrack Info',
                      info: _actualRxAudioInfo!,
                    ),
                  ],

                  if (_isCalling &&
                      !_isRinging &&
                      _actualTxAudioInfo != null) ...[
                    const SizedBox(height: 16),
                    AudioInfoCard(
                      title: 'Actual TX AudioRecord Info',
                      info: _actualTxAudioInfo!,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          ValueListenableBuilder<int>(
            valueListenable: _ampUpdateNotifier,
            builder: (context, _, _) {
              return WaveformDisplay(
                amplitudes: _amplitudes,
                color: Theme.of(context).colorScheme.primary,
              );
            },
          ),
          const SizedBox(height: 8),

          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 8),
              backgroundColor: _isCalling ? Colors.red.shade100 : null,
            ),
            onPressed: () {
              if (_isCalling) {
                _stopCall();
              } else {
                _startCall();
              }
            },
            icon: Icon(_isCalling ? Icons.call_end : Icons.call),
            label: Text(_isCalling ? 'End Call' : 'Start Call'),
          ),
        ],
      ),
    );
  }
}
