import 'package:flick/services/sources/tidal_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tierStartHintFor', () {
    test('field HIGH + no tags stays HIGH', () {
      expect(TidalService.tierStartHintFor('HIGH', []), 'HIGH');
    });

    test('field HIGH + LOSSLESS tag upgrades to LOSSLESS (the hint gap)', () {
      expect(TidalService.tierStartHintFor('HIGH', ['LOSSLESS']), 'LOSSLESS');
    });

    test('field LOSSLESS + no tags stays LOSSLESS', () {
      expect(TidalService.tierStartHintFor('LOSSLESS', []), 'LOSSLESS');
    });

    test('unknown field + LOSSLESS tag yields LOSSLESS', () {
      expect(TidalService.tierStartHintFor(null, ['LOSSLESS']), 'LOSSLESS');
    });

    test('field HI_RES beats LOSSLESS tag (highest wins)', () {
      expect(TidalService.tierStartHintFor('HI_RES', ['LOSSLESS']), 'HI_RES');
    });

    test('unknown field + no tags yields null (full cascade)', () {
      expect(TidalService.tierStartHintFor(null, []), isNull);
    });

    test('hi-res field keeps full cascade (null hint)', () {
      expect(TidalService.tierStartHintFor('HI_RES_LOSSLESS', []), isNull);
    });

    test('hi-res tag keeps full cascade (null hint)', () {
      expect(TidalService.tierStartHintFor('HIGH', ['HIRES_LOSSLESS']), isNull);
      expect(
        TidalService.tierStartHintFor('HIGH', ['HIRES_LOSSLESS_MQA']),
        isNull,
      );
    });

    test('unrelated tags do not change the field hint', () {
      expect(TidalService.tierStartHintFor('HIGH', ['DOLBY_ATMOS']), 'HIGH');
    });
  });
}
