import 'package:flick/core/utils/dev_log.dart';
import 'package:flick/services/listenbrainz/listenbrainz_api_client.dart';
import 'package:flick/services/listenbrainz/listenbrainz_models.dart';
import 'package:flick/services/listenbrainz/listenbrainz_scrobble_service.dart';
import 'package:flick/services/scrobble_queue.dart';

/// Offline-safe ListenBrainz listen queue persisted in SharedPreferences.
class ListenBrainzScrobbleQueue extends ScrobbleQueue<ListenBrainzListenEntry> {
  ListenBrainzScrobbleQueue({ListenBrainzScrobbleService? service})
      : this._internal(service ?? ListenBrainzScrobbleService());

  ListenBrainzScrobbleQueue._internal(ListenBrainzScrobbleService service)
      : super(
          logTag: '[ListenBrainz]',
          queueKey: 'listenbrainz_scrobble_queue_v1',
          maxQueueSize: 1000,
          toJson: (entry) => entry.toJson(),
          fromJson: (json) => ListenBrainzListenEntry.fromJson(json),
          describeEntry: (entry) =>
              'artist="${entry.artistName}" track="${entry.trackName}"',
          sendBatch: service.scrobbleBatch,
          handleAuthError: (e) {
            if (e is ListenBrainzNoTokenException) {
              devLog('[ListenBrainz] queue flush skipped: no token; queue retained');
              return true;
            }
            if (e is ListenBrainzApiException && e.statusCode == 401) {
              devLog(
                '[ListenBrainz] queue flush failed: token invalid (401); queue retained until re-auth',
              );
              return true;
            }
            return false;
          },
        );
}
