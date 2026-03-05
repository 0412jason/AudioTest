import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:collection';
import 'package:file_picker/file_picker.dart';
import 'audio_engine.dart';
import 'widgets/split_view_layout.dart';
import 'widgets/audio_config_fields.dart';
import 'widgets/waveform_display.dart';

class PlaybackPage extends StatelessWidget {
  const PlaybackPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SplitViewLayout(
        title: 'Playback Configuration',
        builder: () => const PlaybackConfigWidget(),
        initialSplitCount: 1,
      ),
    );
  }
}

class PlaybackConfigWidget extends StatefulWidget {
  const PlaybackConfigWidget({super.key});

  @override
  State<PlaybackConfigWidget> createState() => _PlaybackConfigWidgetState();
}

class _PlaybackConfigWidgetState extends State<PlaybackConfigWidget> {
  bool _isPlaying = false;
  bool _isPaused = false;

  // Unique ID for this specific widget instance to interface with the native tracker
  late final int _instanceId;

  final TextEditingController _sampleRateController = TextEditingController(
    text: "48000",
  );
  int _playbackSource = 0; // 0 for Sine Wave, 1 for Local File
  String? _localFilePath;

  int _selectedChannelConfig = 12; // AudioFormat.CHANNEL_OUT_STEREO
  int _selectedAudioFormat = 2; // AudioFormat.ENCODING_PCM_16BIT

  int _selectedUsage = 1;
  int _selectedContentType = 2;
  int _selectedFlags = 0;

  List<AudioDevice> _outputDevices = [];
  AudioDevice? _selectedDevice;

  Map<String, int> _usagesMap = {};
  Map<String, int> _contentTypesMap = {};
  Map<String, int> _flagsMap = {};
  Map<String, int> _audioModes = {};

  final Queue<double> _amplitudes = Queue();
  final ValueNotifier<int> _ampUpdateNotifier = ValueNotifier<int>(0);
  StreamSubscription? _amplitudeSub;
  StreamSubscription? _deviceChangeSub;
  static const int _maxAmplitudes = 100;

  int? _originalMode; // Store original mode before modifying

  // Non-null when a local file has been analysed
  FileAudioInfo? _detectedFileInfo;

  @override
  void initState() {
    super.initState();
    _instanceId = hashCode;
    _loadDevices();
    _deviceChangeSub = AudioEngine.deviceChangeStream.listen((_) {
      _loadDevices();
    });
    _loadAudioAttributesOptions();
    for (int i = 0; i < _maxAmplitudes; i++) {
      _amplitudes.add(0.0);
    }
  }

  Future<void> _loadAudioAttributesOptions() async {
    final options = await AudioEngine.getAudioAttributesOptions();
    final modes = await AudioEngine.getAudioModeOptions();
    if (mounted) {
      setState(() {
        _usagesMap = options['usages'] ?? {};
        _contentTypesMap = options['contentTypes'] ?? {};
        _flagsMap = options['flags'] ?? {};

        var sortedModes = modes.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        _audioModes = {'BYPASS': -3};
        _audioModes.addEntries(sortedModes);
      });
    }
  }

  void dispose() {
    _sampleRateController.dispose();
    _ampUpdateNotifier.dispose();
    _deviceChangeSub?.cancel();
    _stopPlayback();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    final devices = await AudioEngine.getAudioDevices(true);
    if (mounted) {
      setState(() {
        _outputDevices = devices;
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

  int _selectedMode = -3; // Default BYPASS is -3

  void _startPlayback() async {
    int sampleRate = int.tryParse(_sampleRateController.text) ?? 48000;

    if (_selectedMode != -3) {
      _originalMode = await AudioEngine.getAudioMode();
      await AudioEngine.setAudioMode(_selectedMode);
    }
    await AudioEngine.startPlayback(
      instanceId: _instanceId,
      sampleRate: sampleRate,
      channelConfig: _selectedChannelConfig,
      audioFormat: _selectedAudioFormat,
      usage: _selectedUsage,
      contentType: _selectedContentType,
      flags: _selectedFlags,
      preferredDeviceId: _selectedDevice?.id,
      filePath: _playbackSource == 1 ? _localFilePath : null,
    );
    setState(() {
      _isPlaying = true;
      _isPaused = false;
    });

    _amplitudeSub = AudioEngine.amplitudeStream.listen((event) {
      if (mounted && event['id'] == _instanceId) {
        if (event.containsKey('amp')) {
          _amplitudes.addLast(event['amp'] as double);
          if (_amplitudes.length > _maxAmplitudes) {
            _amplitudes.removeFirst();
          }
          _ampUpdateNotifier.value++;
        }
      }
    });
  }

  void _stopPlayback() async {
    setState(() {
      _isPlaying = false;
      _isPaused = false;
    });
    _amplitudes.clear();
    for (int i = 0; i < _maxAmplitudes; i++) {
      _amplitudes.add(0.0);
    }
    _ampUpdateNotifier.value++;
    _amplitudeSub?.cancel();
    await AudioEngine.stopPlayback(_instanceId);

    if (_selectedMode != -3 && _originalMode != null) {
      await AudioEngine.setAudioMode(_originalMode!);
      _originalMode = null;
    }
  }

  void _pausePlayback() async {
    setState(() {
      _isPaused = true;
    });
    await AudioEngine.pausePlayback(_instanceId);
  }

  void _resumePlayback() async {
    setState(() {
      _isPaused = false;
    });
    await AudioEngine.resumePlayback(_instanceId);
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
    );
    if (result != null && mounted) {
      final path = result.files.single.path!;
      final info = await AudioEngine.getFileAudioInfo(path);
      setState(() {
        _localFilePath = path;
        _detectedFileInfo = info;
        if (info != null) {
          _sampleRateController.text = info.sampleRate.toString();
          _selectedChannelConfig = info.channelConfig;
          _selectedAudioFormat = info.audioFormat;
        }
      });
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
                  // ── Playback Source (always first) ──────────────────────
                  AudioConfigFields.dropdown<int>(
                    label: 'Playback Source',
                    initialSelection: _playbackSource,
                    enabled: !_isPlaying,
                    entries: const [
                      DropdownMenuEntry(value: 0, label: "Sine Wave"),
                      DropdownMenuEntry(value: 1, label: "Local File"),
                    ],
                    onSelected: (v) {
                      if (v != null) {
                        setState(() {
                          _playbackSource = v;
                          if (v == 0) {
                            // restore editable defaults when switching to sine
                            _detectedFileInfo = null;
                            _localFilePath = null;
                            _sampleRateController.text = '48000';
                            _selectedChannelConfig = 4;
                            _selectedAudioFormat = 2;
                          }
                        });
                      }
                    },
                  ),
                  if (_playbackSource == 1) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _localFilePath?.split('/').last ??
                                'No file selected',
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        ElevatedButton(
                          onPressed: _isPlaying ? null : _pickFile,
                          child: const Text('Pick File'),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 4),

                  // ── Sample Rate ─────────────────────────────────────────
                  AudioConfigFields.sampleRateField(
                    controller: _sampleRateController,
                    enabled:
                        !_isPlaying &&
                        (_playbackSource == 0 || _detectedFileInfo == null),
                  ),
                  const SizedBox(height: 4),

                  // ── Channel Config ──────────────────────────────────────
                  AudioConfigFields.channelConfigDropdown(
                    initialSelection: _selectedChannelConfig,
                    enabled:
                        !_isPlaying &&
                        (_playbackSource == 0 || _detectedFileInfo == null),
                    isInput: false,
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedChannelConfig = v);
                      }
                    },
                  ),
                  const SizedBox(height: 4),

                  // ── Audio Format ────────────────────────────────────────
                  AudioConfigFields.audioFormatDropdown(
                    initialSelection: _selectedAudioFormat,
                    enabled:
                        !_isPlaying &&
                        (_playbackSource == 0 || _detectedFileInfo == null),
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedAudioFormat = v);
                      }
                    },
                  ),
                  const SizedBox(height: 4),

                  AudioConfigFields.dropdown<int>(
                    label: 'Usage',
                    initialSelection: _selectedUsage,
                    enabled: !_isPlaying,
                    entries: _usagesMap.isEmpty
                        ? const [
                            DropdownMenuEntry(value: 1, label: "Media (1)"),
                            DropdownMenuEntry(
                              value: 2,
                              label: "Voice Comm (2)",
                            ),
                            DropdownMenuEntry(value: 4, label: "Alarm (4)"),
                            DropdownMenuEntry(
                              value: 5,
                              label: "Notification (5)",
                            ),
                            DropdownMenuEntry(
                              value: 12,
                              label: "Navigation (12)",
                            ),
                          ]
                        : (_usagesMap.entries.toList()
                                ..sort((a, b) => a.value.compareTo(b.value)))
                              .map(
                                (e) => DropdownMenuEntry(
                                  value: e.value,
                                  label:
                                      "${e.key.replaceFirst('USAGE_', '')} (${e.value})",
                                ),
                              )
                              .toList(),
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedUsage = v);
                      }
                    },
                  ),
                  const SizedBox(height: 4),

                  AudioConfigFields.dropdown<int>(
                    label: 'Content Type',
                    initialSelection: _selectedContentType,
                    enabled: !_isPlaying,
                    entries: _contentTypesMap.isEmpty
                        ? const [
                            DropdownMenuEntry(value: 0, label: "Unknown (0)"),
                            DropdownMenuEntry(value: 1, label: "Speech (1)"),
                            DropdownMenuEntry(value: 2, label: "Music (2)"),
                            DropdownMenuEntry(value: 3, label: "Movie (3)"),
                            DropdownMenuEntry(
                              value: 4,
                              label: "Sonification (4)",
                            ),
                          ]
                        : (_contentTypesMap.entries.toList()
                                ..sort((a, b) => a.value.compareTo(b.value)))
                              .map(
                                (e) => DropdownMenuEntry(
                                  value: e.value,
                                  label:
                                      "${e.key.replaceFirst('CONTENT_TYPE_', '')} (${e.value})",
                                ),
                              )
                              .toList(),
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedContentType = v);
                      }
                    },
                  ),
                  const SizedBox(height: 4),

                  AudioConfigFields.dropdown<int>(
                    label: 'Flags',
                    initialSelection: _selectedFlags,
                    enabled: !_isPlaying,
                    entries: _flagsMap.isEmpty
                        ? const [
                            DropdownMenuEntry(value: 0, label: "None (0)"),
                            DropdownMenuEntry(
                              value: 0x1,
                              label: "Audibility Enforced (0x1)",
                            ),
                            DropdownMenuEntry(
                              value: 0x10,
                              label: "HW AV Sync (0x10)",
                            ),
                            DropdownMenuEntry(
                              value: 0x100,
                              label: "Low Latency (0x100)",
                            ),
                          ]
                        : [
                            const DropdownMenuEntry(
                              value: 0,
                              label: "None (0)",
                            ),
                            ...(_flagsMap.entries.toList()
                                  ..sort((a, b) => a.value.compareTo(b.value)))
                                .map(
                                  (e) => DropdownMenuEntry(
                                    value: e.value,
                                    label:
                                        "${e.key.replaceFirst('FLAG_', '')} (0x${e.value.toRadixString(16).toUpperCase()})",
                                  ),
                                ),
                          ],
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedFlags = v);
                      }
                    },
                  ),
                  const SizedBox(height: 4),

                  AudioConfigFields.dropdown<int>(
                    label: 'Audio Mode',
                    initialSelection: _selectedMode,
                    enabled: !_isPlaying,
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
                  const SizedBox(height: 4),

                  AudioConfigFields.deviceDropdown(
                    label: 'Output Device (Port ID - Name - Type)',
                    initialSelection: _selectedDevice,
                    enabled: !_isPlaying,
                    devices: _outputDevices,
                    defaultLabel: "Default Routing",
                    onSelected: (v) => setState(() => _selectedDevice = v),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          ValueListenableBuilder<int>(
            valueListenable: _ampUpdateNotifier,
            builder: (context, _, __) {
              return WaveformDisplay(
                amplitudes: _amplitudes,
                color: Theme.of(context).colorScheme.primary,
              );
            },
          ),
          const SizedBox(height: 8),

          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    backgroundColor: _isPlaying ? Colors.red.shade100 : null,
                  ),
                  onPressed: () {
                    if (_isPlaying) {
                      _stopPlayback();
                    } else {
                      _startPlayback();
                    }
                  },
                  child: Icon(_isPlaying ? Icons.stop : Icons.play_arrow),
                ),
              ),
              if (_isPlaying) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      backgroundColor: Colors.orange.shade100,
                    ),
                    onPressed: () {
                      if (_isPaused) {
                        _resumePlayback();
                      } else {
                        _pausePlayback();
                      }
                    },
                    child: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
