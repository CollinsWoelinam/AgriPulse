import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../location.dart';
import '../models.dart';
import '../services.dart';

/// Records a geotagged observation (category, text, photos) into the local outbox.
class NoteScreen extends StatefulWidget {
  const NoteScreen({super.key, required this.fieldId, this.target});

  final String fieldId;
  final StressTarget? target;

  @override
  State<NoteScreen> createState() => _NoteScreenState();
}

class _NoteScreenState extends State<NoteScreen> {
  static const _uuid = Uuid();
  final _text = TextEditingController();
  final _picker = ImagePicker();
  final List<XFile> _photos = [];
  String? _category;
  Position? _position;
  String? _locationProblem;
  bool _locating = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  Future<void> _locate() async {
    setState(() => _locating = true);
    _locationProblem = await ensureLocation();
    if (_locationProblem == null) {
      try {
        _position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, timeLimit: Duration(seconds: 20)),
        );
      } on Exception {
        _position = await Geolocator.getLastKnownPosition();
        if (_position == null) _locationProblem = 'No GPS fix yet. Move into the open and try again.';
      }
    }
    if (mounted) setState(() => _locating = false);
  }

  Future<void> _addPhoto(ImageSource source) async {
    try {
      final img = await _picker.pickImage(source: source, maxWidth: 2048, imageQuality: 80);
      if (img != null) setState(() => _photos.add(img));
    } on Exception {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(source == ImageSource.camera ? 'Camera not available.' : "Couldn't open photos."),
      ));
    }
  }

  Future<void> _save() async {
    final s = ServicesScope.of(context);
    final pos = _position!;
    setState(() => _saving = true);
    final noteId = _uuid.v4();
    // Copy photos out of the picker's temp folder, which the OS may clear before the next sync.
    final photos = <({String id, String path})>[];
    for (final img in _photos) {
      final id = _uuid.v4();
      final ext = p.extension(img.path).isEmpty ? '.jpg' : p.extension(img.path).toLowerCase();
      final dest = p.join(s.photoDir.path, '$id$ext');
      await File(img.path).copy(dest);
      photos.add((id: id, path: dest));
    }
    await s.store.addNote(
      LocalNote(
        id: noteId,
        fieldId: widget.fieldId,
        zoneId: widget.target?.zoneId,
        lat: pos.latitude,
        lon: pos.longitude,
        accuracyM: pos.accuracy,
        category: _category!,
        note: _text.text.trim(),
        observedAt: DateTime.now(),
      ),
      photos,
    );
    final sync = s.sync!;
    await sync.syncNow();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(sync.pending == 0 ? 'Observation saved and uploaded.' : 'Saved on this phone. It will upload when online.'),
    ));
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canSave = _category != null && _position != null && !_saving;
    return Scaffold(
      appBar: AppBar(title: Text(widget.target == null ? 'New observation' : 'Target ${widget.target!.rank}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _locationCard(theme),
          const SizedBox(height: 16),
          Text('What did you find?', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in noteCategories.entries)
                ChoiceChip(
                  key: Key('cat-${e.key}'),
                  label: Text(e.value),
                  selected: _category == e.key,
                  onSelected: (_) => setState(() => _category = e.key),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('note-text'),
            controller: _text,
            maxLines: 4,
            maxLength: 2000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Notes',
              hintText: 'Symptoms, extent, likely cause…',
              border: OutlineInputBorder(),
            ),
          ),
          Text('Photos', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (i, img) in _photos.indexed)
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(File(img.path), width: 88, height: 88, fit: BoxFit.cover),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IconButton.filledTonal(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Remove photo',
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () => setState(() => _photos.removeAt(i)),
                      ),
                    ),
                  ],
                ),
              OutlinedButton.icon(
                onPressed: () => _addPhoto(ImageSource.camera),
                icon: const Icon(Icons.photo_camera),
                label: const Text('Camera'),
              ),
              OutlinedButton.icon(
                onPressed: () => _addPhoto(ImageSource.gallery),
                icon: const Icon(Icons.photo_library),
                label: const Text('Gallery'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('save-note'),
            onPressed: canSave ? _save : null,
            child: _saving
                ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Text('Save observation'),
          ),
          if (_category == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Pick what you found to save.', style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
            ),
        ],
      ),
    );
  }

  Widget _locationCard(ThemeData theme) {
    final pos = _position;
    return Card(
      child: ListTile(
        leading: Icon(pos == null ? Icons.location_searching : Icons.my_location),
        title: Text(_locating
            ? 'Getting your location…'
            : pos == null
                ? (_locationProblem ?? 'No location')
                : '${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}'),
        subtitle: pos == null ? null : Text('Accuracy ±${pos.accuracy.round()} m'),
        trailing: IconButton(tooltip: 'Refresh location', icon: const Icon(Icons.refresh), onPressed: _locating ? null : _locate),
      ),
    );
  }
}
