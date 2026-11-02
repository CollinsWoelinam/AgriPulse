import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../geo.dart';
import '../location.dart';
import '../models.dart';
import '../services.dart';
import '../ui/theme.dart';

const _categoryColors = {
  'pest_infestation': Color(0xFFC2391F),
  'disease': Color(0xFF8E44AD),
  'nitrogen_deficiency': Color(0xFF9A7B00),
  'irrigation_failure': Color(0xFF1E6FC2),
  'weeds': Color(0xFF2E7D32),
  'weather_damage': Color(0xFF5E6D64),
  'no_issue': AP.forest,
  'other': AP.muted,
};

/// Records a geotagged observation (category, text, photos) into the local outbox.
class NoteScreen extends StatefulWidget {
  const NoteScreen({super.key, required this.fieldId, required this.fieldName, this.target});

  final String fieldId, fieldName;
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
    final canSave = _category != null && _position != null && !_saving;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(false),
                style: IconButton.styleFrom(backgroundColor: Colors.white, side: const BorderSide(color: AP.line), fixedSize: const Size(44, 44)),
                icon: const Icon(Icons.close, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.target == null ? widget.fieldName : 'Target ${widget.target!.rank} · ${widget.fieldName}',
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AP.muted)),
                  const Text('Log observation', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
                ]),
              ),
            ]),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                _locationCard(),
                const SizedBox(height: 20),
                const Text('What did you find?', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 3.4,
                  children: [for (final e in noteCategories.entries) _categoryButton(e.key, e.value)],
                ),
                const SizedBox(height: 20),
                const Text('Notes', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('note-text'),
                  controller: _text,
                  maxLines: 3,
                  maxLength: 2000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(hintText: 'Symptoms, extent, likely cause…'),
                ),
                const Text('Photos', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final (i, img) in _photos.indexed)
                    Stack(children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.file(File(img.path), width: 84, height: 84, fit: BoxFit.cover),
                      ),
                      Positioned(
                        right: 2,
                        top: 2,
                        child: IconButton.filledTonal(
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Remove photo',
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () => setState(() => _photos.removeAt(i)),
                        ),
                      ),
                    ]),
                  _photoButton(Icons.photo_camera_outlined, 'Camera', () => _addPhoto(ImageSource.camera)),
                  _photoButton(Icons.photo_library_outlined, 'Gallery', () => _addPhoto(ImageSource.gallery)),
                ]),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            decoration: const BoxDecoration(color: AP.bg, border: Border(top: BorderSide(color: AP.line))),
            child: Column(children: [
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('save-note'),
                  onPressed: canSave ? _save : null,
                  child: _saving
                      ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : const Text('Save observation'),
                ),
              ),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.cloud_outlined, size: 14, color: AP.muted),
                const SizedBox(width: 6),
                Text(_category == null ? 'Pick what you found to save.' : 'Saved on this phone first, uploaded when online',
                    style: const TextStyle(fontSize: 12, color: AP.muted)),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _categoryButton(String key, String label) {
    final on = _category == key;
    return Material(
      color: on ? AP.ink : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: on ? AP.ink : AP.line, width: 1.5)),
      child: InkWell(
        key: Key('cat-$key'),
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _category = key),
        child: Semantics(
          selected: on,
          button: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: on ? AP.lime : _categoryColors[key], shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: on ? Colors.white : AP.ink)),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _photoButton(IconData icon, String label, VoidCallback onTap) => SizedBox.square(
        dimension: 84,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            foregroundColor: AP.forest,
            side: const BorderSide(color: Color(0xFF9FB09A), width: 1.5),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 22),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
        ),
      );

  Widget _locationCard() {
    final pos = _position;
    final t = widget.target;
    String sub;
    if (pos == null) {
      sub = _locationProblem ?? '';
    } else if (t != null) {
      final d = distanceMeters(pos.latitude, pos.longitude, t.point.latitude, t.point.longitude);
      sub = d <= pos.accuracy.clamp(10, 50) ? 'At target ${t.rank} · ±${pos.accuracy.round()} m'
          : '${formatDistance(d)} from target ${t.rank} · ±${pos.accuracy.round()} m';
    } else {
      sub = 'Accuracy ±${pos.accuracy.round()} m';
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AP.line)),
      child: Row(children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(color: const Color(0xFFDDEBFB), borderRadius: BorderRadius.circular(12)),
          child: Icon(pos == null ? Icons.location_searching : Icons.my_location, size: 20, color: const Color(0xFF1E5DAA)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              _locating ? 'Getting your location…' : pos == null ? 'No location' : '${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}',
              style: pos == null ? const TextStyle(fontWeight: FontWeight.w700) : AP.monoStyle(14),
            ),
            if (sub.isNotEmpty) Text(sub, key: const Key('location-sub'), style: const TextStyle(fontSize: 12, color: AP.muted)),
          ]),
        ),
        IconButton(tooltip: 'Refresh location', icon: const Icon(Icons.refresh), onPressed: _locating ? null : _locate),
      ]),
    );
  }
}
