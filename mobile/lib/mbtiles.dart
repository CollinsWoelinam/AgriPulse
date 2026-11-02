import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:sqflite/sqflite.dart';

/// Reads raster tiles from an MBTiles file (SQLite, TMS rows) for flutter_map, fully offline.
class MbtilesTileProvider extends TileProvider {
  MbtilesTileProvider(this.db);

  final Database db;

  static Future<MbtilesTileProvider> open(String path, {DatabaseFactory? factory}) async =>
      MbtilesTileProvider(await (factory ?? databaseFactory).openDatabase(path, options: OpenDatabaseOptions(readOnly: true)));

  Future<Uint8List?> tile(int z, int x, int y) async {
    final rows = await db.query('tiles',
        columns: ['tile_data'],
        where: 'zoom_level = ? AND tile_column = ? AND tile_row = ?',
        whereArgs: [z, x, (1 << z) - 1 - y]); // XYZ -> TMS
    return rows.isEmpty ? null : rows.first['tile_data'] as Uint8List;
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _MbtilesImage(this, coordinates.z, coordinates.x, coordinates.y);

  @override
  Future<void> dispose() async {
    await db.close();
    super.dispose();
  }
}

/// 1x1 transparent PNG for tiles outside the package.
@visibleForTesting
final transparentTile = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0B, 0x49,
  0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0x00, 0x02, 0x00, 0x00, 0x05, 0x00, 0x01, 0x7A, 0x5E, 0xAB, 0x3F, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

@immutable
class _MbtilesImage extends ImageProvider<_MbtilesImage> {
  const _MbtilesImage(this.provider, this.z, this.x, this.y);

  final MbtilesTileProvider provider;
  final int z, x, y;

  @override
  Future<_MbtilesImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_MbtilesImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_load(decode));

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final bytes = await provider.tile(z, x, y) ?? transparentTile;
    final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    return ImageInfo(image: (await codec.getNextFrame()).image);
  }

  @override
  bool operator ==(Object other) =>
      other is _MbtilesImage && other.provider == provider && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(provider, z, x, y);
}
