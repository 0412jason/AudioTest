import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:collection';
import 'package:file_picker/file_picker.dart';
import 'audio_engine.dart';
import 'waveform_painter.dart';
import 'menu_tracker.dart';

class PlaybackPage extends StatefulWidget {
  const PlaybackPage({super.key});

  @override
  State<PlaybackPage> createState() => _PlaybackPageState();
}

class _PlaybackPageState extends State<PlaybackPage> {
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
      return const PlaybackConfigWidget();
    } else if (_splitCount == 2) {
      return Row(
        children: const [
          Expanded(child: PlaybackConfigWidget()),
          VerticalDivider(width: 1, thickness: 1),
          Expanded(child: PlaybackConfigWidget()),
        ],
      );
    } else {
      return Column(
        children: [
          Expanded(
            child: Row(
              children: const [
                Expanded(child: PlaybackConfigWidget()),
                VerticalDivider(width: 1, thickness: 1),
                Expanded(child: PlaybackConfigWidget()),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1),
          Expanded(
            child: Row(
              children: const [
                Expanded(child: PlaybackConfigWidget()),
                VerticalDivider(width: 1, thickness: 1),
                Expanded(child: PlaybackConfigWidget()),
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
                'Playback Configuration',
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

  final Queue<double> _amplitudes = Queue();
  StreamSubscription? _amplitudeSub;
  static const int _maxAmplitudes = 100;

  // Non-null when a local file has been analysed
  FileAudioInfo? _detectedFileInfo;

  @override
  void initState() {
    super.initState();
    _instanceId = hashCode;
    _loadDevices();
    _loadAudioAttributesOptions();
    for (int i = 0; i < _maxAmplitudes; i++) {
      _amplitudes.add(0.0);
    }
  }

  Future<void> _loadAudioAttributesOptions() async {
    final options = await AudioEngine.getAudioAttributesOptions();
    if (mounted) {
      setState(() {
        _usagesMap = options['usages'] ?? {};
        _contentTypesMap = options['contentTypes'] ?? {};
        _flagsMap = options['flags'] ?? {};
      });
    }
  }

  @override
  void dispose() {
    _sampleRateController.dispose();
    _stopPlayback();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    final devices = await AudioEngine.getAudioDevices(true);
    if (mounted) {
      setState(() {
        _outputDevices = devices;
      });
    }
  }

  void _startPlayback() async {
    int sampleRate = int.tryParse(_sampleRateController.text) ?? 44100;

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
        setState(() {
          _amplitudes.addLast(event['amp'] as double);
          if (_amplitudes.length > _maxAmplitudes) {
            _amplitudes.removeFirst();
          }
        });
      }
    });
  }

  void _stopPlayback() async {
    setState(() {
      _isPlaying = false;
      _isPaused = false;
      _amplitudes.clear();
      for (int i = 0; i < _maxAmplitudes; i++) {
        _amplitudes.add(0.0);
      }
    });
    _amplitudeSub?.cancel();
    await AudioEngine.stopPlayback(_instanceId);
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
                  TrackedDropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Playback Source'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _playbackSource,
                    enabled: !_isPlaying,
                    dropdownMenuEntries: const [
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
                            _sampleRateController.text = '44100';
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
                  TextField(
                    controller: _sampleRateController,
                    decoration: const InputDecoration(
                      labelText: 'Sample Rate (Hz)',
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                    ),
                    keyboardType: TextInputType.number,
                    enabled:
                        !_isPlaying &&
                        (_playbackSource == 0 || _detectedFileInfo == null),
                  ),
                  const SizedBox(height: 4),

                  // ── Channel Config ──────────────────────────────────────
                  TrackedDropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Channel Config'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _selectedChannelConfig,
                    enabled:
                        !_isPlaying &&
                        (_playbackSource == 0 || _detectedFileInfo == null),
                    dropdownMenuEntries: const [
                      DropdownMenuEntry(value: 4, label: "Mono (Out)"),
                      DropdownMenuEntry(value: 12, label: "Stereo (Out)"),
                    ],
                    onSelected: (v) {
                      if (v != null) {
                        setState(() => _selectedChannelConfig = v);
                      }
                    },
                  ),
                  const SizedBox(height: 4),

                  // ── Audio Format ────────────────────────────────────────
                  TrackedDropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Audio Format'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _selectedAudioFormat,
                    enabled:
                        !_isPlaying &&
                        (_playbackSource == 0 || _detectedFileInfo == null),
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
                    label: const Text('Usage'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _selectedUsage,
                    enabled: !_isPlaying,
                    dropdownMenuEntries: _usagesMap.isEmpty
                        ? [
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

                  TrackedDropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Content Type'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _selectedContentType,
                    enabled: !_isPlaying,
                    dropdownMenuEntries: _contentTypesMap.isEmpty
                        ? [
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

                  TrackedDropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Flags'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _selectedFlags,
                    enabled: !_isPlaying,
                    dropdownMenuEntries: _flagsMap.isEmpty
                        ? [
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

                  TrackedDropdownMenu<AudioDevice?>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Output Device (Port ID - Name - Type)'),
                    inputDecorationTheme: const InputDecorationTheme(
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      isDense: true,
                    ),
                    initialSelection: _selectedDevice,
                    enabled: !_isPlaying,
                    dropdownMenuEntries: [
                      const DropdownMenuEntry(
                        value: null,
                        label: "Default Routing",
                      ),
                      ..._outputDevices.map(
                        (d) => DropdownMenuEntry(
                          value: d,
                          label: "${d.id} - ${d.name} - ${d.type}",
                        ),
                      ),
                    ],
                    onSelected: (v) => setState(() => _selectedDevice = v),
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
