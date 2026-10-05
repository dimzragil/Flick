import 'package:flick/core/utils/dev_log.dart';
import 'package:flick/services/lastfm/lastfm_api_client.dart';
import 'package:flick/services/lastfm/lastfm_models.dart';
import 'package:flick/services/lastfm/lastfm_scrobble_service.dart';
import 'package:flick/services/scrobble_queue.dart';

/// Offline-safe scrobble queue persisted in SharedPreferences.
class LastFmScrobbleQueue extends ScrobbleQueue<ScrobbleEntry> {
  LastFmScrobbleQueue({LastFmScrobbleService? service})
      : this._internal(service ?? LastFmScrobbleService());

  LastFmScrobbleQueue._internal(LastFmScrobbleService service)
      : super(
          logTag: '[LastFm]',
          queueKey: 'lastfm_scrobble_queue_v1',
          maxQueueSize: 500,
          toJson: (entry) => entry.toJson(),
          fromJson: (json) => ScrobbleEntry.fromJson(json),
          describeEntry: (entry) =>
              'artist="${entry.artist}" track="${entry.track}"',
          sendBatch: service.scrobbleBatch,
          handleAuthError: (e) {
            if (e is LastFmNoSessionException) {
              devLog('[LastFm] queue flush skipped: no session; queue retained');
              return true;
            }
            if (e is LastFmApiException && e.code == 9) {
              devLog(
                '[LastFm] queue flush failed: session expired (code 9); queue retained until re-auth',
              );
              return true;
            }
            return false;
          },
        );
}
