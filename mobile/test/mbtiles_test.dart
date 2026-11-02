import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:agripulse_scout/mbtiles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('reads XYZ tiles from TMS rows', () async {
    final db = await databaseFactoryFfiNoIsolate.openDatabase(inMemoryDatabasePath);
    await db.execute('CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)');
    // XYZ tile z=16 x=33787 y=21523 is TMS row 2^16 - 1 - 21523 = 44012.
    await db.insert('tiles', {'zoom_level': 16, 'tile_column': 33787, 'tile_row': 44012, 'tile_data': Uint8List.fromList([1, 2, 3])});
    final provider = MbtilesTileProvider(db);

    expect(await provider.tile(16, 33787, 21523), [1, 2, 3]);
    expect(await provider.tile(16, 33787, 44012), isNull); // the raw TMS row is not an XYZ y
    expect(await provider.tile(17, 0, 0), isNull);
    await db.close();
  });

  testWidgets('the placeholder for missing tiles is a valid transparent PNG', (tester) async {
    final image = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(transparentTile);
      return (await codec.getNextFrame()).image;
    });
    expect(image!.width, 1);
    expect(image.height, 1);
    final rgba = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba));
    expect(rgba!.getUint8(3), 0); // alpha
  });
}
