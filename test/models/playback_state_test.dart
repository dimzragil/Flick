import 'package:flutter_test/flutter_test.dart';

import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/playback_state.dart';

void main() {
  group('PlaybackState errorMessage', () {
    PlaybackState base() => PlaybackState.empty(AudioEngineType.normalAndroid);

    test('copyWith(errorMessage:) sets it and ==/hashCode reflect it', () {
      final withError = base().copyWith(errorMessage: 'boom');
      expect(withError.errorMessage, 'boom');

      // The error state is distinct from the no-error state...
      expect(withError, isNot(equals(base())));
      expect(withError.hashCode, isNot(equals(base().hashCode)));

      // ...but equal states stay equal (hashCode contract).
      final sameError = base().copyWith(errorMessage: 'boom');
      expect(withError, equals(sameError));
      expect(withError.hashCode, equals(sameError.hashCode));

      // errorMessage survives unrelated copyWith calls.
      final moved = withError.copyWith(position: const Duration(seconds: 5));
      expect(moved.errorMessage, 'boom');
      expect(moved.position, const Duration(seconds: 5));
    });

    test('copyWith(clearError: true) resets to the no-error state', () {
      final withError = base().copyWith(errorMessage: 'boom');
      final cleared = withError.copyWith(clearError: true);

      expect(cleared.errorMessage, isNull);
      expect(cleared, equals(base()));
      expect(cleared.hashCode, equals(base().hashCode));
    });

    test(
      'clearError wins when both errorMessage and clearError are passed',
      () {
        final cleared = base()
            .copyWith(errorMessage: 'boom')
            .copyWith(errorMessage: 'other', clearError: true);
        expect(cleared.errorMessage, isNull);
      },
    );
  });
}
