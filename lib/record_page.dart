import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:collection';
import 'audio_engine.dart';
import 'waveform_painter.dart';
import 'menu_tracker.dart';

class RecordPage extends StatefulWidget {
  const RecordPage({super.key});

  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> {
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
      return const RecordConfigWidget();
    } else if (_splitCount == 2) {
      return Row(
        children: const [
          Expanded(child: RecordConfigWidget()),
          VerticalDivider(width: 1, thickness: 1),
          Expanded(child: RecordConfigWidget()),
        ],
      );
    } else {
      return Column(
        children: [
          Expanded(
            child: Row(
              children: const [
                Expanded(child: RecordConfigWidget()),
                VerticalDivider(width: 1, thickness: 1),
                Expanded(child: RecordConfigWidget()),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1),
          Expanded(
            child: Row(
              children: const [
                Expanded(child: RecordConfigWidget()),
                VerticalDivider(width: 1, thickness: 1),
                Expanded(child: RecordConfigWidget()),
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
                'Record Configuration',
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
    text: "44100",
  );
  int _selectedChannelConfig = 16; // AudioFormat.CHANNEL_IN_MONO
  int _selectedAudioFormat = 2; // AudioFormat.ENCODING_PCM_16BIT

  int _selectedSource = 1;
  int _selectedMode = 0; // Default MODE_NORMAL is 0

  List<AudioDevice> _inputDevices = [];
  Map<String, int> _audioSources = {};
  Map<String, int> _audioModes = {};
  AudioDevice? _selectedDevice;

  final Queue<double> _amplitudes = Queue();
  StreamSubscription? _amplitudeSub;
  static const int _maxAmplitudes = 100;

  @override
  void initState() {
    super.initState();
    _instanceId = hashCode;
    _loadOptions();
    for (int i = 0; i < _maxAmplitudes; i++) {
      _amplitudes.add(0.0);
    }
  }

  @override
  void dispose() {
    _sampleRateController.dispose();
    _amplitudeSub?.cancel(); // Cancel subscription here
    _stopRecording();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    final devices = await AudioEngine.getAudioDevices(false);
    final sources = await AudioEngine.getAudioSourceOptions();
    final modes = await AudioEngine.getAudioModeOptions();
    if (mounted) {
      setState(() {
        _inputDevices = devices;

        // Sort the audio sources by their integer values
        var sortedEntries = sources.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        _audioSources = Map.fromEntries(sortedEntries);

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
        _audioModes = Map.fromEntries(sortedModes);

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

  void _startRecording() async {
    int sampleRate = int.tryParse(_sampleRateController.text) ?? 44100;

    await AudioEngine.startRecording(
      instanceId: _instanceId,
      sampleRate: sampleRate,
      channelConfig: _selectedChannelConfig,
      audioFormat: _selectedAudioFormat,
      audioSource: _selectedSource,
      saveToFile: _saveToFile,
      preferredDeviceId: _selectedDevice?.id,
      audioMode: _selectedMode,
    );
    setState(() {
      _isRecording = true;
      _savedFilePath = null; // Clear previous path when starting
    });

    _amplitudeSub
        ?.cancel(); // Cancel old subscription before starting a new one
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

  void _stopRecording() async {
    setState(() {
      _isRecording = false;
      _amplitudes.clear();
      for (int i = 0; i < _maxAmplitudes; i++) {
        _amplitudes.add(0.0);
      }
    });
    // Do not cancel _amplitudeSub here, wait for the final 'path' event.
    await AudioEngine.stopRecording(_instanceId);
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
                  TextField(
                    controller: _sampleRateController,
                    decoration: const InputDecoration(
                      labelText: 'Sample Rate (Hz)',
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                    ),
                    keyboardType: TextInputType.number,
                    enabled: !_isRecording,
                  ),
                  const SizedBox(height: 4),

                  TrackedDropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Channel Config'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _selectedChannelConfig,
                    enabled: !_isRecording,
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
                  const SizedBox(height: 4),

                  TrackedDropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Audio Format'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _selectedAudioFormat,
                    enabled: !_isRecording,
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
                  const SizedBox(height: 4),

                  TrackedDropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Audio Source'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _selectedSource,
                    enabled: !_isRecording,
                    dropdownMenuEntries: _audioSources.isEmpty
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

                  TrackedDropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Audio Mode'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _selectedMode,
                    enabled: !_isRecording,
                    dropdownMenuEntries: _audioModes.isEmpty
                        ? const [
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

                  TrackedDropdownMenu<AudioDevice?>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Input Device (Port ID - Name - Type)'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _selectedDevice,
                    enabled: !_isRecording,
                    dropdownMenuEntries: [
                      const DropdownMenuEntry(
                        value: null,
                        label: "Default Routing",
                      ),
                      ..._inputDevices.map(
                        (d) => DropdownMenuEntry(
                          value: d,
                          label: "${d.id} - ${d.name} - ${d.type}",
                        ),
                      ),
                    ],
                    onSelected: (v) => setState(() => _selectedDevice = v),
                  ),
                  const SizedBox(height: 8),

                  CheckboxListTile(
                    title: const Text('Save to WAV File'),
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
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
            ),
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
