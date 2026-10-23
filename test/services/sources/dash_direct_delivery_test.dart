import 'dart:io';

import 'package:flick/services/sources/dash_direct_delivery.dart';
import 'package:flick/services/sources/dash_manifest_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _oneRepMpd = '''<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
  <Period>
    <AdaptationSet mimeType="audio/mp4" codecs="flac">
      <Representation id="rep1" audioSamplingRate="96000" bandwidth="2000000">
        <SegmentTemplate initialization="https://cdn.tidal.com/init.mp4" media="https://cdn.tidal.com/seg_\$Number\$.mp4" startNumber="1">
          <SegmentTimeline><S d="1000" r="1" /></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';

const _twoRepMpd = '''<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
  <Period>
    <AdaptationSet mimeType="audio/mp4" codecs="flac">
      <Representation id="low" audioSamplingRate="44100" bandwidth="900000">
        <SegmentTemplate initialization="https://cdn.tidal.com/low_init.mp4" media="https://cdn.tidal.com/low_\$Number\$.mp4" startNumber="1">
          <SegmentTimeline><S d="1000" /></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
      <Representation id="hi" audioSamplingRate="96000" bandwidth="3000000">
        <SegmentTemplate initialization="https://cdn.tidal.com/hi_init.mp4" media="https://cdn.tidal.com/hi_\$Number\$.mp4" startNumber="1">
          <SegmentTimeline><S d="1000" r="1" /></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';

void main() {
  group('DashTrackInfo manifest retention', () {
    test('keeps the raw manifest and reports one representation', () {
      final info = DashManifestParser.parse(_oneRepMpd);
      expect(info, isNotNull);
      expect(info!.manifestXml, _oneRepMpd);
      expect(info.representationCount, 1);
      expect(info.representationId, 'rep1');
    });

    test('bit depth is null: the MPD carries none', () {
      final info = DashManifestParser.parse(_oneRepMpd);
      expect(info!.bitDepth, isNull);
    });
  });

  group('stripToSingleRepresentation', () {
    test('keeps the highest representation and its timeline intact', () {
      final stripped = DashManifestParser.stripToSingleRepresentation(
        _twoRepMpd,
      );
      expect(stripped, isNotNull);
      expect(
        RegExp('<Representation').allMatches(stripped!).length,
        1,
        reason: 'only the chosen representation may reach the player',
      );
      expect(stripped, contains('SegmentTimeline'));
      expect(stripped, isNot(contains('audioSamplingRate="44100"')));

      // The stripped manifest must parse to the same stream as the original.
      final original = DashManifestParser.parse(_twoRepMpd);
      final rewritten = DashManifestParser.parse(stripped);
      expect(rewritten, isNotNull);
      expect(rewritten!.initializationUrl, original!.initializationUrl);
      expect(rewritten.segmentUrls, original.segmentUrls);
      expect(rewritten.sampleRate, 96000);
    });

    test('is a no-op for a single-representation manifest', () {
      final stripped = DashManifestParser.stripToSingleRepresentation(
        _oneRepMpd,
      );
      expect(stripped, isNotNull);
      expect(RegExp('<Representation').allMatches(stripped!).length, 1);
      final info = DashManifestParser.parse(stripped);
      expect(info!.segmentUrls.length, 2);
    });

    test('returns null for malformed XML', () {
      expect(DashManifestParser.stripToSingleRepresentation('not xml'), isNull);
      expect(
        DashManifestParser.stripToSingleRepresentation('<MPD></MPD>'),
        isNull,
      );
    });
  });

  group('dashManifestIsSelfContained', () {
    test('accepts absolute https init and segment URLs', () {
      expect(
        dashManifestIsSelfContained(DashManifestParser.parse(_oneRepMpd)!),
        isTrue,
      );
    });

    test('rejects relative URLs the player would have to resolve', () {
      const relative = '''<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
  <Period>
    <AdaptationSet mimeType="audio/mp4">
      <Representation id="r" audioSamplingRate="96000">
        <SegmentTemplate initialization="init.mp4" media="seg_\$Number\$.mp4">
          <SegmentTimeline><S d="1000" /></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';
      expect(
        dashManifestIsSelfContained(DashManifestParser.parse(relative)!),
        isFalse,
      );
    });
  });

  group('DashManifestStore', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('dash_store_test');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('writes the exact bytes to a .mpd file', () async {
      final store = DashManifestStore(rootDirectory: root);
      final path = await store.write(trackId: '12345', xml: _oneRepMpd);
      expect(path, endsWith('.mpd'));
      expect(path, contains('12345'));
      expect(File(path).readAsStringSync(), _oneRepMpd);
      expect(store.pathFor('12345'), path);
    });

    test(
      'does not rewrite an unchanged manifest on the second resolve',
      () async {
        final store = DashManifestStore(rootDirectory: root);
        final path = await store.write(trackId: '12345', xml: _oneRepMpd);
        final firstWrite = File(path).lastModifiedSync();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final again = await store.write(trackId: '12345', xml: _oneRepMpd);
        expect(again, path);
        expect(File(path).lastModifiedSync(), firstWrite);
      },
    );

    test('evict deletes one track, evictAll clears the rest', () async {
      final store = DashManifestStore(rootDirectory: root);
      final a = await store.write(trackId: 'a', xml: _oneRepMpd);
      final b = await store.write(trackId: 'b', xml: _oneRepMpd);
      await store.evict('a');
      expect(File(a).existsSync(), isFalse);
      expect(File(b).existsSync(), isTrue);
      expect(store.pathFor('a'), isNull);

      await store.evictAll();
      expect(File(b).existsSync(), isFalse);
      expect(store.trackedFileCount, 0);
    });

    test('stays bounded: no accumulation past the cap', () async {
      final store = DashManifestStore(rootDirectory: root);
      for (var i = 0; i < DashManifestStore.maxFiles + 4; i++) {
        await store.write(trackId: 'track_$i', xml: _oneRepMpd);
      }
      expect(store.trackedFileCount, DashManifestStore.maxFiles);
      final onDisk = root
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.mpd'))
          .length;
      expect(onDisk, DashManifestStore.maxFiles);
      expect(store.pathFor('track_0'), isNull, reason: 'oldest pruned first');
    });

    test('clears manifests left by an earlier run', () async {
      final stale = File('${root.path}/stale.mpd')..writeAsStringSync('x');
      final store = DashManifestStore(rootDirectory: root);
      await store.write(trackId: 'fresh', xml: _oneRepMpd);
      expect(stale.existsSync(), isFalse);
    });

    test('sanitizes track ids used as file names', () async {
      final store = DashManifestStore(rootDirectory: root);
      final path = await store.write(trackId: 'a/b:c', xml: _oneRepMpd);
      expect(path, endsWith('a_b_c.mpd'));
    });
  });
}
