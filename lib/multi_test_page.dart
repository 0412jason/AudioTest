import 'package:flutter/material.dart';
import 'record_page.dart';
import 'playback_page.dart';
import 'voip_page.dart';
import 'menu_tracker.dart';

class MultiTestPage extends StatefulWidget {
  const MultiTestPage({super.key});

  @override
  State<MultiTestPage> createState() => _MultiTestPageState();
}

class _MultiTestPageState extends State<MultiTestPage> {
  int _splitCount = 4;

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
      return const TestSlot();
    } else if (_splitCount == 2) {
      return Row(
        children: const [
          Expanded(child: TestSlot()),
          VerticalDivider(width: 1, thickness: 1),
          Expanded(child: TestSlot()),
        ],
      );
    } else {
      return Column(
        children: [
          Expanded(
            child: Row(
              children: const [
                Expanded(child: TestSlot()),
                VerticalDivider(width: 1, thickness: 1),
                Expanded(child: TestSlot()),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1),
          Expanded(
            child: Row(
              children: const [
                Expanded(child: TestSlot()),
                VerticalDivider(width: 1, thickness: 1),
                Expanded(child: TestSlot()),
              ],
            ),
          ),
        ],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Multi-Test Grid'),
        toolbarHeight: 0, // Hide app bar to match other pages' style
      ),
      body: SafeArea(
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
                  'Multi Test',
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
          child: TrackedDropdownMenu<TestType>(
            expandedInsets: EdgeInsets.zero,
            label: const Text('Test Mode'),
            initialSelection: _selectedType,
            inputDecorationTheme: const InputDecorationTheme(
              contentPadding: EdgeInsets.symmetric(vertical: 4),
              isDense: true,
            ),
            dropdownMenuEntries: const [
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
