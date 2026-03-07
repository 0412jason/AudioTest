import 'package:flutter/material.dart';
import 'package:audiotest/audio_engine.dart';
import 'package:audiotest/widgets/audio_config_fields.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers (package-internal)
// ─────────────────────────────────────────────────────────────────────────────

String _mapKeyLabel(Map<String, int> map, int? value) {
  if (value == null) return 'Unknown';
  if (map.isEmpty) return 'Loading... ($value)';
  for (final entry in map.entries) {
    if (entry.value == value) return '${entry.key} (${entry.value})';
  }
  return 'Unknown ($value)';
}

// ─────────────────────────────────────────────────────────────────────────────
// InfoRow
// ─────────────────────────────────────────────────────────────────────────────

class InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const InfoRow({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AudioInfoCard
// ─────────────────────────────────────────────────────────────────────────────

class AudioInfoCard extends StatelessWidget {
  final String title;
  final AudioInfo info;

  const AudioInfoCard({super.key, required this.title, required this.info});

  @override
  Widget build(BuildContext context) {
    final formatName = AudioConfigFields.audioFormatMap[info.audioFormat];
    final formatLabel = formatName != null
        ? '$formatName (${info.audioFormat})'
        : 'Unknown (${info.audioFormat})';

    return _InfoCardShell(
      title: title,
      children: [
        // ── Basic ─────────────────────────────────────────────────────────
        InfoRow(label: 'Sample Rate', value: '${info.sampleRate} Hz'),
        InfoRow(label: 'Channel Count', value: '${info.channelCount}'),
        InfoRow(label: 'Format', value: formatLabel),
        if (info.isOffloaded != null)
          InfoRow(label: 'Offloaded', value: info.isOffloaded! ? 'Yes' : 'No'),

        // ── Attributes ────────────────────────────────────────────────────
        const Divider(height: 16),
        _SectionLabel('Attributes'),
        if (info.usage != null)
          InfoRow(
            label: 'Usage',
            value: _mapKeyLabel(AudioEngine.cachedUsagesMap, info.usage),
          ),
        if (info.contentType != null)
          InfoRow(
            label: 'Content Type',
            value: _mapKeyLabel(
              AudioEngine.cachedContentTypesMap,
              info.contentType,
            ),
          ),
        if (info.flags != null)
          InfoRow(
            label: 'Flags',
            value: _mapKeyLabel(AudioEngine.cachedFlagsMap, info.flags),
          ),
        if (info.audioSource != null)
          InfoRow(
            label: 'Audio Source',
            value: _mapKeyLabel(
              AudioEngine.cachedAudioSourcesMap,
              info.audioSource,
            ),
          ),

        // ── Routed Device ─────────────────────────────────────────────────
        if (info.routedDeviceName != null) ...[
          const Divider(height: 16),
          _SectionLabel('Routed Device'),
          const SizedBox(height: 4),
          InfoRow(label: 'Name', value: info.routedDeviceName!),
          if (info.routedDeviceType != null)
            InfoRow(label: 'Type', value: info.routedDeviceType!),
          if (info.routedDeviceId != null)
            InfoRow(label: 'ID', value: '${info.routedDeviceId}'),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Private helpers
// ─────────────────────────────────────────────────────────────────────────────

class _InfoCardShell extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _InfoCardShell({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
    );
  }
}
