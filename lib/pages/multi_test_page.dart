import 'package:flutter/material.dart';
import 'record_page.dart';
import 'playback_page.dart';
import 'voip_page.dart';
import 'package:audiotest/widgets/split_view_layout.dart';
import 'package:audiotest/widgets/audio_config_fields.dart';

class MultiTestPage extends StatelessWidget {
  const MultiTestPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Multi-Test Grid'),
        toolbarHeight: 0, // Hide app bar to match other pages' style
      ),
      body: SafeArea(
        child: SplitViewLayout(
          title: 'Multi Test',
          builder: () => const TestSlot(),
          initialSplitCount: 4,
        ),
      ),
    );
  }
}

enum TestType { none, record, playback, voip }

class TestSlot extends StatefulWidget {
  const TestSlot({super.key});

  @override
  State<TestSlot> createState() => _TestSlotState();
}

class _TestSlotState extends State<TestSlot> {
  TestType _selectedType = TestType.none;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(4.0),
          child: AudioConfigFields.dropdown<TestType>(
            label: 'Test Mode',
            initialSelection: _selectedType,
            enabled: true,
            entries: const [
              DropdownMenuEntry(value: TestType.none, label: 'None'),
              DropdownMenuEntry(value: TestType.playback, label: 'Playback'),
              DropdownMenuEntry(value: TestType.record, label: 'Record'),
              DropdownMenuEntry(value: TestType.voip, label: 'VoIP'),
            ],
            onSelected: (v) {
              if (v != null) {
                setState(() => _selectedType = v);
              }
            },
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildTestWidget()),
      ],
    );
  }

  Widget _buildTestWidget() {
    switch (_selectedType) {
      case TestType.record:
        return const RecordConfigWidget();
      case TestType.playback:
        return const PlaybackConfigWidget();
      case TestType.voip:
        return const VoIPConfigWidget();
      case TestType.none:
        return const Center(child: Text('Select Test Mode'));
    }
  }
}
