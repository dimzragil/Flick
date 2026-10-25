import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/sources/dash_manifest_parser.dart';

void main() {
  group('DashManifestParser', () {
    test(r'parses SegmentTimeline with $Number$ and BaseURL', () {
      const xml = '''<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" minBufferTime="PT1.5S" type="static" mediaPresentationDuration="PT30S">
  <Period>
    <BaseURL>https://sp-pr-cf.audio.tidal.com/data/</BaseURL>
    <AdaptationSet mimeType="audio/mp4" codecs="flac" contentType="audio">
      <Representation id="flac_96000_24" audioSamplingRate="96000" bandwidth="2800000">
        <SegmentTemplate timescale="1000" initialization="init_\$RepresentationID\$.mp4" media="seg_\$RepresentationID\$_\$Number%03d\$.mp4" startNumber="1">
          <SegmentTimeline>
            <S t="0" d="10000" r="2" />
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';

      final info = DashManifestParser.parse(xml);
      expect(info, isNotNull);
      expect(info!.codec, 'flac');
      expect(info.sampleRate, 96000);
      expect(
        info.initializationUrl,
        'https://sp-pr-cf.audio.tidal.com/data/init_flac_96000_24.mp4',
      );
      // r="2" means 1 initial + 2 repeats = 3 segments total
      expect(info.segmentUrls.length, 3);
      expect(
        info.segmentUrls[0],
        'https://sp-pr-cf.audio.tidal.com/data/seg_flac_96000_24_001.mp4',
      );
      expect(
        info.segmentUrls[1],
        'https://sp-pr-cf.audio.tidal.com/data/seg_flac_96000_24_002.mp4',
      );
      expect(
        info.segmentUrls[2],
        'https://sp-pr-cf.audio.tidal.com/data/seg_flac_96000_24_003.mp4',
      );
    });

    test(r'parses SegmentTimeline with $Time$ and absolute URLs', () {
      const xml = '''<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
  <Period>
    <AdaptationSet mimeType="audio/mp4">
      <Representation id="1" codecs="flac" audioSamplingRate="192000" bandwidth="5000000">
        <SegmentTemplate timescale="1000" initialization="https://cdn.tidal.com/init.mp4" media="https://cdn.tidal.com/chunk_\$Time\$.mp4">
          <SegmentTimeline>
            <S t="0" d="3000" />
            <S d="3000" />
            <S d="2500" />
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';

      final info = DashManifestParser.parse(xml);
      expect(info, isNotNull);
      expect(info!.sampleRate, 192000);
      expect(info.initializationUrl, 'https://cdn.tidal.com/init.mp4');
      expect(info.segmentUrls.length, 3);
      expect(info.segmentUrls[0], 'https://cdn.tidal.com/chunk_0.mp4');
      expect(info.segmentUrls[1], 'https://cdn.tidal.com/chunk_3000.mp4');
      expect(info.segmentUrls[2], 'https://cdn.tidal.com/chunk_6000.mp4');
    });

    test(
      'selects highest audioSamplingRate when multiple representations exist',
      () {
        const xml = '''<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
  <Period>
    <AdaptationSet mimeType="audio/mp4">
      <Representation id="low" audioSamplingRate="44100" bandwidth="1000000">
        <SegmentTemplate initialization="http://example.com/low_init.mp4" media="http://example.com/low_\$Number\$.mp4">
          <SegmentTimeline><S d="1000" /></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
      <Representation id="hi_res" audioSamplingRate="96000" bandwidth="3000000">
        <SegmentTemplate initialization="http://example.com/hires_init.mp4" media="http://example.com/hires_\$Number\$.mp4">
          <SegmentTimeline><S d="1000" /></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';

        final info = DashManifestParser.parse(xml);
        expect(info, isNotNull);
        expect(info!.sampleRate, 96000);
        expect(info.initializationUrl, 'http://example.com/hires_init.mp4');
      },
    );

    test(
      'when allowDolbyAtmos is false, filters out ec-3 representation and selects stereo representation',
      () {
        const xml = '''<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
  <Period>
    <AdaptationSet mimeType="audio/mp4">
      <Representation id="atmos_rep" codecs="ec-3" audioSamplingRate="48000" bandwidth="448000">
        <SegmentTemplate initialization="http://example.com/atmos_init.mp4" media="http://example.com/atmos_\$Number\$.mp4">
          <SegmentTimeline><S d="1000" /></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
      <Representation id="stereo_flac" codecs="flac" audioSamplingRate="44100" bandwidth="900000">
        <SegmentTemplate initialization="http://example.com/stereo_init.mp4" media="http://example.com/stereo_\$Number\$.mp4">
          <SegmentTimeline><S d="1000" /></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';

        // When allowDolbyAtmos is true, ec-3 Atmos representation is allowed:
        final atmosInfo = DashManifestParser.parse(xml, allowDolbyAtmos: true);
        expect(atmosInfo, isNotNull);
        expect(atmosInfo!.codec, 'ec-3');
        expect(atmosInfo.sampleRate, 48000);

        // When allowDolbyAtmos is false, ec-3 representation is skipped and stereo flac is picked:
        final stereoInfo = DashManifestParser.parse(xml, allowDolbyAtmos: false);
        expect(stereoInfo, isNotNull);
        expect(stereoInfo!.codec, 'flac');
        expect(stereoInfo.sampleRate, 44100);
        expect(stereoInfo.initializationUrl, 'http://example.com/stereo_init.mp4');

        // stripToSingleRepresentation with allowDolbyAtmos: false selects stereo representation
        final stripped = DashManifestParser.stripToSingleRepresentation(xml, allowDolbyAtmos: false);
        expect(stripped, isNotNull);
        expect(stripped, contains('id="stereo_flac"'));
        expect(stripped, isNot(contains('id="atmos_rep"')));
      },
    );

    test('handles malformed XML gracefully', () {
      expect(DashManifestParser.parse('not xml'), isNull);
      expect(DashManifestParser.parse('<MPD></MPD>'), isNull);
    });
  });
}
