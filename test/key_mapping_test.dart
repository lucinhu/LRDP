import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/rdp/key_mapping.dart';

void main() {
  test(
    'Latin IME maps printable ASCII and control characters to real keys',
    () {
      for (var unit = 32; unit < 127; unit++) {
        expect(
          rdpCharacterChord(unit),
          isNotNull,
          reason: String.fromCharCode(unit),
        );
      }
      expect(rdpCharacterChord(0x61), [0x1e]);
      expect(rdpCharacterChord(0x41), [0x2a, 0x1e]);
      expect(rdpCharacterChord(0x21), [0x2a, 0x02]);
      expect(rdpCharacterChord(0x3f), [0x2a, 0x35]);
      expect(rdpCharacterChord(0x5c), [0x2b]);
      expect(rdpCharacterChord(8), [0x0e]);
      expect(rdpCharacterChord(10), [0x1c]);
      expect(rdpCharacterChord(0x4e2d), isNull);
      expect(rdpCharacterChord(0x200b), isNull);
    },
  );
}
