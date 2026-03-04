import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:collection';
import 'audio_engine.dart';
import 'menu_tracker.dart';
import 'waveform_painter.dart';

class VoIPPage extends StatefulWidget {
  const VoIPPage({super.key});

  @override
  State<VoIPPage> createState() => _VoIPPageState();
}

class _VoIPPageState extends State<VoIPPage> {
  int _splitCount = 1;

  void _increaseSplit() {
    setState(() {
      if (_splitCount == 1) {
        _splitCount = 2;
      } else if (_splitCount == 2) {
        _splitCount = 4;
      }
    });
  }

  void _decreaseSplit() {
    setState(() {
      if (_splitCount == 4) {
        _splitCount = 2;
      } else if (_splitCount == 2) {
        _splitCount = 1;
      }
    });
  }

  Widget _buildGrid() {
    if (_splitCount == 1) {
      return const VoIPConfigWidget();
    } else if (_splitCount == 2) {
      return Row(
        children: const [
          Expanded(child: VoIPConfigWidget()),
          VerticalDivider(width: 1, thickness: 1),
          Expanded(child: VoIPConfigWidget()),
        ],
      );
    } else {
      return Column(
        children: [
          Expanded(
            child: Row(
              children: const [
                Expanded(child: VoIPConfigWidget()),
                VerticalDivider(width: 1, thickness: 1),
                Expanded(child: VoIPConfigWidget()),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1),
          Expanded(
            child: Row(
              children: const [
                Expanded(child: VoIPConfigWidget()),
                VerticalDivider(width: 1, thickness: 1),
                Expanded(child: VoIPConfigWidget()),
              ],
            ),
          ),
        ],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.remove),
                onPressed: _splitCount > 1 ? _decreaseSplit : null,
              ),
              const Text(
                'VoIP Configuration',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: _splitCount < 4 ? _increaseSplit : null,
              ),
            ],
          ),
          Expanded(child: _buildGrid()),
        ],
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
  StreamSubscription? _amplitudeSub;
  static const int _maxAmplitudes = 100;

  @override
  void initState() {
    super.initState();
    _instanceId = hashCode;
    _loadDevices();
    for (int i = 0; i < _maxAmplitudes; i++) {
      _amplitudes.add(0.0);
    }
  }

  @override
  void dispose() {
    _txSampleRateController.dispose();
    _rxSampleRateController.dispose();
    _amplitudeSub?.cancel();
    _stopCall();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    final inputs = await AudioEngine.getAudioDevices(false);
    final outputs = await AudioEngine.getAudioDevices(true);
    if (mounted) {
      setState(() {
        _inputDevices = inputs;
        _outputDevices = outputs;
      });
    }
  }

  void _startCall() async {
    setState(() {
      _isCalling = true;
      _savedFilePath = null;
    });

    // 1. Set mode to ringtone (2 = MODE_RINGTONE)
    await AudioEngine.setAudioMode(2);

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

    // 3. Normal VoIP setup
    await AudioEngine.setAudioMode(_selectedMode);
    await AudioEngine.setCommunicationDevice(_selectedOutputDevice?.id);

    int txSampleRate = int.tryParse(_txSampleRateController.text) ?? 48000;
    int rxSampleRate = int.tryParse(_rxSampleRateController.text) ?? 48000;

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
      audioMode: _selectedMode,
      preferredDeviceId: _selectedInputDevice?.id,
      saveToFile: _saveToFile,
    );

    _amplitudeSub?.cancel();
    _amplitudeSub = AudioEngine.amplitudeStream.listen((event) {
      if (mounted && event['id'] == _instanceId) {
        if (event.containsKey('path')) {
          setState(() {
            _savedFilePath = event['path'] as String;
          });
        } else if (event.containsKey('amp')) {
          setState(() {
            _amplitudes.addLast(event['amp'] as double);
            if (_amplitudes.length > _maxAmplitudes) {
              _amplitudes.removeFirst();
            }
          });
        }
      }
    });
  }

  void _stopCall() async {
    setState(() {
      _isCalling = false;
      _amplitudes.clear();
      for (int i = 0; i < _maxAmplitudes; i++) {
        _amplitudes.add(0.0);
      }
    });
    await AudioEngine.stopRecording(_instanceId);
    await AudioEngine.stopPlayback(_instanceId + 1);
    await AudioEngine.stopPlayback(_instanceId + 2);
    await AudioEngine.setCommunicationDevice(null);
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
                  TextField(
                    controller: _rxSampleRateController,
                    decoration: const InputDecoration(
                      labelText: 'RX Sample Rate (Hz)',
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                    ),
                    keyboardType: TextInputType.number,
                    enabled: !_isCalling,
                  ),
                  const SizedBox(height: 8),
                  TrackedDropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('RX Channel Config'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _selectedPlaybackChannelConfig,
                    enabled: !_isCalling,
                    dropdownMenuEntries: const [
                      DropdownMenuEntry(value: 4, label: "Mono (Out)"),
                      DropdownMenuEntry(value: 12, label: "Stereo (Out)"),
                    ],
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedPlaybackChannelConfig = v);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  TrackedDropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('RX Audio Format'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _selectedPlaybackAudioFormat,
                    enabled: !_isCalling,
                    dropdownMenuEntries: const [
                      DropdownMenuEntry(value: 3, label: "8-bit PCM"),
                      DropdownMenuEntry(value: 2, label: "16-bit PCM"),
                      DropdownMenuEntry(value: 21, label: "24-bit PCM"),
                      DropdownMenuEntry(value: 4, label: "32-bit Float"),
                    ],
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedPlaybackAudioFormat = v);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  TrackedDropdownMenu<AudioDevice?>(
                    label: const Text('RX Output Device (Speaker/Earpiece)'),
                    initialSelection: _selectedOutputDevice,
                    enabled: !_isCalling,
                    expandedInsets: EdgeInsets.zero,
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    dropdownMenuEntries: [
                      const DropdownMenuEntry(
                        value: null,
                        label: "Default Output",
                      ),
                      ..._outputDevices.map(
                        (d) => DropdownMenuEntry(
                          value: d,
                          label: "${d.id} - ${d.name} - ${d.type}",
                        ),
                      ),
                    ],
                    onSelected: (v) =>
                        setState(() => _selectedOutputDevice = v),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    '--- TX (Transmit / Sender) ---',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _txSampleRateController,
                    decoration: const InputDecoration(
                      labelText: 'TX Sample Rate (Hz)',
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                    ),
                    keyboardType: TextInputType.number,
                    enabled: !_isCalling,
                  ),
                  const SizedBox(height: 8),
                  TrackedDropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('TX Channel Config'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _selectedChannelConfig,
                    enabled: !_isCalling,
                    dropdownMenuEntries: const [
                      DropdownMenuEntry(value: 16, label: "Mono (In)"),
                      DropdownMenuEntry(value: 12, label: "Stereo (In)"),
                    ],
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedChannelConfig = v);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  TrackedDropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('TX Audio Format'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _selectedAudioFormat,
                    enabled: !_isCalling,
                    dropdownMenuEntries: const [
                      DropdownMenuEntry(value: 3, label: "8-bit PCM"),
                      DropdownMenuEntry(value: 2, label: "16-bit PCM"),
                      DropdownMenuEntry(value: 21, label: "24-bit PCM"),
                      DropdownMenuEntry(value: 4, label: "32-bit Float"),
                    ],
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedAudioFormat = v);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  TrackedDropdownMenu<AudioDevice?>(
                    label: const Text('TX Input Device (Microphone)'),
                    initialSelection: _selectedInputDevice,
                    enabled: !_isCalling,
                    expandedInsets: EdgeInsets.zero,
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    dropdownMenuEntries: [
                      const DropdownMenuEntry(
                        value: null,
                        label: "Default Input",
                      ),
                      ..._inputDevices.map(
                        (d) => DropdownMenuEntry(
                          value: d,
                          label: "${d.id} - ${d.name} - ${d.type}",
                        ),
                      ),
                    ],
                    onSelected: (v) => setState(() => _selectedInputDevice = v),
                  ),
                  const SizedBox(height: 16),
                  CheckboxListTile(
                    title: const Text('TX Save to WAV File'),
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
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 60,
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: CustomPaint(
                painter: WaveformPainter(
                  amplitudes: _amplitudes,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
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
