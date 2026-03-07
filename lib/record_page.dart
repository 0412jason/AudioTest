import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:collection';
import 'audio_engine.dart';
import 'widgets/split_view_layout.dart';
import 'widgets/audio_config_fields.dart';
import 'widgets/waveform_display.dart';
import 'widgets/audio_info_card.dart';

class RecordPage extends StatelessWidget {
  const RecordPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SplitViewLayout(
        title: 'Record Configuration',
        builder: () => const RecordConfigWidget(),
        initialSplitCount: 1,
      ),
    );
  }
}

class RecordConfigWidget extends StatefulWidget {
  const RecordConfigWidget({super.key});

  @override
  State<RecordConfigWidget> createState() => _RecordConfigWidgetState();
}

class _RecordConfigWidgetState extends State<RecordConfigWidget> {
  bool _isRecording = false;
  bool _saveToFile = false;
  String? _savedFilePath;

  // Unique ID for this specific widget instance to interface with the native tracker
  late final int _instanceId;

  final TextEditingController _sampleRateController = TextEditingController(
    text: "48000",
  );
  int _selectedChannelConfig = 12; // AudioFormat.CHANNEL_IN_STEREO
  int _selectedAudioFormat = 2; // AudioFormat.ENCODING_PCM_16BIT

  int _selectedSource = 1;
  int _selectedMode = -3; // Default BYPASS is -3

  List<AudioDevice> _inputDevices = [];
  Map<String, int> _audioSources = {};
  Map<String, int> _audioModes = {};
  AudioDevice? _selectedDevice;

  int? _originalMode; // Store original mode before modifying

  final Queue<double> _amplitudes = Queue();
  final ValueNotifier<int> _ampUpdateNotifier = ValueNotifier<int>(0);
  StreamSubscription? _amplitudeSub;
  StreamSubscription? _deviceChangeSub;
  StreamSubscription? _audioInfoSub;
  static const int _maxAmplitudes = 100;

  AudioInfo? _actualAudioInfo;

  @override
  void initState() {
    super.initState();
    _instanceId = hashCode;
    AudioEngine.initAttributeMaps().then((_) => _loadOptions());
    _deviceChangeSub = AudioEngine.deviceChangeStream.listen((_) {
      _loadDevices();
    });
    for (int i = 0; i < _maxAmplitudes; i++) {
      _amplitudes.add(0.0);
    }
  }

  @override
  void dispose() {
    _sampleRateController.dispose();
    _ampUpdateNotifier.dispose();
    _amplitudeSub?.cancel(); // Cancel subscription here
    _deviceChangeSub?.cancel();
    _audioInfoSub?.cancel();
    _stopRecording();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    await AudioEngine.initAttributeMaps();
    await _loadDevices();
    final modes = await AudioEngine.getAudioModeOptions();
    final sources = await AudioEngine.getAudioSourceOptions();
    if (mounted) {
      setState(() {
        var sortedSources = sources.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        _audioSources = Map.fromEntries(sortedSources);

        if (_audioSources.isNotEmpty &&
            !_audioSources.values.contains(_selectedSource)) {
          if (_audioSources.values.contains(1)) {
            _selectedSource = 1; // Default to MIC (1)
          } else {
            _selectedSource = _audioSources.values.first;
          }
        }

        var sortedModes = modes.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        _audioModes = {'BYPASS': -3};
        _audioModes.addEntries(sortedModes);

        if (_audioModes.isNotEmpty &&
            !_audioModes.values.contains(_selectedMode)) {
          if (_audioModes.values.contains(0)) {
            _selectedMode = 0; // Default to MODE_NORMAL (0)
          } else {
            _selectedMode = _audioModes.values.first;
          }
        }
      });
    }
  }

  Future<void> _loadDevices() async {
    final devices = await AudioEngine.getAudioDevices(false);
    if (mounted) {
      setState(() {
        _inputDevices = devices;
        if (_selectedDevice != null) {
          try {
            _selectedDevice = devices.firstWhere(
              (d) => d.id == _selectedDevice!.id,
            );
          } catch (_) {
            _selectedDevice = null;
          }
        }
      });
    }
  }

  void _startRecording() async {
    int sampleRate = int.tryParse(_sampleRateController.text) ?? 48000;

    if (_selectedMode != -3) {
      _originalMode = await AudioEngine.getAudioMode();
      await AudioEngine.setAudioMode(_selectedMode);
    }

    // Subscribe BEFORE startRecording so we don't miss the initial event
    // that the native side fires synchronously during startRecording.
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
      if (mounted && info.id == _instanceId) {
        setState(() {
          _actualAudioInfo = info;
        });
      }
    });

    await AudioEngine.startRecording(
      instanceId: _instanceId,
      sampleRate: sampleRate,
      channelConfig: _selectedChannelConfig,
      audioFormat: _selectedAudioFormat,
      audioSource: _selectedSource,
      saveToFile: _saveToFile,
      preferredDeviceId: _selectedDevice?.id,
    );
    setState(() {
      _isRecording = true;
      _savedFilePath = null; // Clear previous path when starting
    });
  }

  void _stopRecording() async {
    setState(() {
      _isRecording = false;
      _actualAudioInfo = null;
      _amplitudes.clear();
      for (int i = 0; i < _maxAmplitudes; i++) {
        _amplitudes.add(0.0);
      }
      _ampUpdateNotifier.value++;
    });
    _amplitudeSub?.cancel();
    _audioInfoSub?.cancel();
    await AudioEngine.stopRecording(_instanceId);

    if (_selectedMode != -3 && _originalMode != null) {
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
                  AudioConfigFields.sampleRateField(
                    controller: _sampleRateController,
                    enabled: !_isRecording,
                  ),
                  const SizedBox(height: 4),

                  AudioConfigFields.channelConfigDropdown(
                    initialSelection: _selectedChannelConfig,
                    enabled: !_isRecording,
                    isInput: true,
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedChannelConfig = v);
                      }
                    },
                  ),
                  const SizedBox(height: 4),

                  AudioConfigFields.audioFormatDropdown(
                    initialSelection: _selectedAudioFormat,
                    enabled: !_isRecording,
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedAudioFormat = v);
                      }
                    },
                  ),
                  const SizedBox(height: 4),

                  AudioConfigFields.dropdown<int>(
                    label: 'Audio Source',
                    initialSelection: _selectedSource,
                    enabled: !_isRecording,
                    entries: _audioSources.isEmpty
                        ? const [
                            DropdownMenuEntry(value: 0, label: "DEFAULT (0)"),
                            DropdownMenuEntry(value: 1, label: "MIC (1)"),
                            DropdownMenuEntry(value: 5, label: "CAMCORDER (5)"),
                            DropdownMenuEntry(
                              value: 6,
                              label: "VOICE_RECOGNITION (6)",
                            ),
                            DropdownMenuEntry(
                              value: 7,
                              label: "VOICE_COMMUNICATION (7)",
                            ),
                          ]
                        : _audioSources.entries.map((entry) {
                            return DropdownMenuEntry(
                              value: entry.value,
                              label: "${entry.key} (${entry.value})",
                            );
                          }).toList(),
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedSource = v);
                      }
                    },
                  ),
                  const SizedBox(height: 8),

                  AudioConfigFields.dropdown<int>(
                    label: 'Audio Mode',
                    initialSelection: _selectedMode,
                    enabled: !_isRecording,
                    entries: _audioModes.isEmpty
                        ? const [
                            DropdownMenuEntry(value: -3, label: "BYPASS (-3)"),
                            DropdownMenuEntry(
                              value: 0,
                              label: "MODE_NORMAL (0)",
                            ),
                            DropdownMenuEntry(
                              value: 3,
                              label: "MODE_IN_COMMUNICATION (3)",
                            ),
                          ]
                        : _audioModes.entries.map((entry) {
                            return DropdownMenuEntry(
                              value: entry.value,
                              label: "${entry.key} (${entry.value})",
                            );
                          }).toList(),
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedMode = v);
                      }
                    },
                  ),
                  const SizedBox(height: 8),

                  AudioConfigFields.deviceDropdown(
                    label: 'Input Device (Port ID - Name - Type)',
                    initialSelection: _selectedDevice,
                    enabled: !_isRecording,
                    devices: _inputDevices,
                    defaultLabel: "Default Routing",
                    onSelected: (v) => setState(() => _selectedDevice = v),
                  ),
                  const SizedBox(height: 8),

                  CheckboxListTile(
                    title: Text(
                      'Save to WAV File',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    value: _saveToFile,
                    onChanged: _isRecording
                        ? null
                        : (bool? value) {
                            setState(() {
                              _saveToFile = value ?? false;
                            });
                          },
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 8),

                  if (_savedFilePath != null)
                    Text(
                      'Saved: $_savedFilePath',
                      style: const TextStyle(fontSize: 12, color: Colors.green),
                    ),

                  if (_isRecording && _actualAudioInfo != null) ...[
                    const SizedBox(height: 16),
                    AudioInfoCard(
                      title: 'Actual AudioRecord Info',
                      info: _actualAudioInfo!,
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

          ElevatedButton(
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 8),
              backgroundColor: _isRecording ? Colors.red.shade100 : null,
            ),
            onPressed: () {
              if (_isRecording) {
                _stopRecording();
              } else {
                _startRecording();
              }
            },
            child: Icon(_isRecording ? Icons.stop : Icons.mic),
          ),
        ],
      ),
    );
  }
}
