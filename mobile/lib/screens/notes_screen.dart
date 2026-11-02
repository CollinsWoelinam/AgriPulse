import 'dart:io';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services.dart';
import '../ui/theme.dart';
import '../widgets/sync_button.dart';

/// "My notes": every observation logged on this phone. "Outbox": only those not uploaded yet.
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key, required this.outbox});

  final bool outbox;

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  List<LocalNote>? _notes;
  Map<String, String> _fieldNames = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  Future<void> _load() async {
    final s = ServicesScope.of(context);
    final all = await s.store.notes();
    final cached = (await s.store.getCache('fields'))?.$1 as List?;
    _fieldNames = {for (final f in cached ?? const []) f['id'] as String: f['field_name'] as String};
    if (mounted) setState(() => _notes = widget.outbox ? all.where((n) => !n.synced).toList() : all);
  }

  @override
  Widget build(BuildContext context) {
    final s = ServicesScope.of(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async {
            await s.sync?.syncNow();
            await _load();
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: [
              Row(children: [
                Expanded(child: Text(widget.outbox ? 'Outbox' : 'My notes', style: Theme.of(context).textTheme.headlineMedium)),
                const SyncButton(),
              ]),
              const SizedBox(height: 6),
              Text(
                widget.outbox
                    ? 'Observations saved on this phone that haven\'t reached the server yet. They upload automatically when online.'
                    : 'Everything you\'ve logged from this phone.',
                style: const TextStyle(color: AP.muted, height: 1.4),
              ),
              const SizedBox(height: 16),
              if (_notes == null)
                const Center(child: CircularProgressIndicator())
              else if (_notes!.isEmpty)
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: AP.line)),
                  child: Row(children: [
                    Icon(widget.outbox ? Icons.cloud_done_outlined : Icons.edit_note, color: AP.forest),
                    const SizedBox(width: 12),
                    Expanded(child: Text(widget.outbox ? 'Nothing waiting. Everything is uploaded.' : 'No observations yet.')),
                  ]),
                )
              else
                for (final n in _notes!) Padding(padding: const EdgeInsets.only(bottom: 10), child: _NoteCard(note: n, fieldName: _fieldNames[n.fieldId])),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note, this.fieldName});

  final LocalNote note;
  final String? fieldName;

  @override
  Widget build(BuildContext context) {
    final t = note.observedAt.toLocal();
    final when = '${t.day}/${t.month} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: AP.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(noteCategories[note.category] ?? note.category, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
          note.synced
              ? Pill.ok('Uploaded')
              : note.lastError != null
                  ? Pill('Needs attention', bg: AP.alertBg, fg: AP.alert, icon: Icons.error_outline)
                  : const Pill('Waiting', bg: Color(0xFFFDF1D8), fg: Color(0xFF7A5000), icon: Icons.schedule),
        ]),
        if (note.note.isNotEmpty) ...[const SizedBox(height: 6), Text(note.note, style: const TextStyle(height: 1.4))],
        const SizedBox(height: 6),
        Text('${fieldName ?? 'Field'} · $when · ±${note.accuracyM?.round() ?? '?'} m', style: const TextStyle(fontSize: 12, color: AP.muted)),
        if (note.lastError != null && !note.synced) ...[
          const SizedBox(height: 6),
          Text('Server said: ${note.lastError}', style: const TextStyle(fontSize: 12, color: AP.alert)),
        ],
        if (note.photoPaths.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in note.photoPaths)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(File(p), width: 64, height: 64, fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(width: 64, height: 64, color: AP.line)),
              ),
          ]),
        ],
      ]),
    );
  }
}
