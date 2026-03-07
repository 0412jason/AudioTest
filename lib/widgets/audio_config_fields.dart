import 'package:flutter/material.dart';
import 'package:audiotest/widgets/menu_tracker.dart';
import 'package:audiotest/audio_engine.dart';

class AudioConfigFields {
  static const Map<int, String> inputChannelMap = {
    16: "Mono (In)",
    12: "Stereo (In)",
  };

  static const Map<int, String> outputChannelMap = {
    4: "Mono (Out)",
    12: "Stereo (Out)",
  };

  static const Map<int, String> audioFormatMap = {
    3: "8-bit PCM",
    2: "16-bit PCM",
    21: "24-bit PCM",
    4: "Float PCM",
  };
  static Widget sampleRateField({
    required TextEditingController controller,
    required bool enabled,
    String label = 'Sample Rate (Hz)',
  }) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        contentPadding: const EdgeInsets.symmetric(vertical: 4),
      ),
      keyboardType: TextInputType.number,
      enabled: enabled,
    );
  }

  static Widget dropdown<T>({
    required String label,
    required T initialSelection,
    required bool enabled,
    required List<DropdownMenuEntry<T>> entries,
    required ValueChanged<T?> onSelected,
  }) {
    return TrackedDropdownMenu<T>(
      expandedInsets: EdgeInsets.zero,
      label: Text(label),
      inputDecorationTheme: const InputDecorationTheme(
        contentPadding: EdgeInsets.symmetric(vertical: 4),
        isDense: true,
      ),
      initialSelection: initialSelection,
      enabled: enabled,
      dropdownMenuEntries: entries,
      onSelected: onSelected,
    );
  }

  static Widget channelConfigDropdown({
    required int initialSelection,
    required bool enabled,
    required ValueChanged<int?> onSelected,
    required bool isInput,
    String? customLabel,
  }) {
    return dropdown<int>(
      label: customLabel ?? (isInput ? 'Channel Config' : 'Channel Config'),
      initialSelection: initialSelection,
      enabled: enabled,
      entries: (isInput ? inputChannelMap : outputChannelMap).entries
          .map((e) => DropdownMenuEntry(value: e.key, label: e.value))
          .toList(),
      onSelected: onSelected,
    );
  }

  static Widget audioFormatDropdown({
    required int initialSelection,
    required bool enabled,
    required ValueChanged<int?> onSelected,
    String label = 'Audio Format',
  }) {
    return dropdown<int>(
      label: label,
      initialSelection: initialSelection,
      enabled: enabled,
      entries: audioFormatMap.entries
          .map((e) => DropdownMenuEntry(value: e.key, label: e.value))
          .toList(),
      onSelected: onSelected,
    );
  }

  static Widget deviceDropdown({
    required AudioDevice? initialSelection,
    required bool enabled,
    required List<AudioDevice> devices,
    required ValueChanged<AudioDevice?> onSelected,
    required String label,
    required String defaultLabel,
  }) {
    return TrackedDropdownMenu<AudioDevice?>(
      expandedInsets: EdgeInsets.zero,
      label: Text(label),
      inputDecorationTheme: const InputDecorationTheme(
        contentPadding: EdgeInsets.symmetric(vertical: 4),
        isDense: true,
      ),
      initialSelection: initialSelection,
      enabled: enabled,
      dropdownMenuEntries: [
        DropdownMenuEntry(value: null, label: defaultLabel),
        ...devices.map(
          (d) => DropdownMenuEntry(
            value: d,
            label: "${d.id} - ${d.name} - ${d.type}",
          ),
        ),
      ],
      onSelected: onSelected,
    );
  }
}
