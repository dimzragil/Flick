import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Platform-keystore copy of a TIDAL refresh token, keyed by server id.
///
/// TIDAL refresh tokens are long-lived OAuth2 credentials capable of minting
/// new access tokens. They must never live in plaintext in the Isar database.
/// Short-lived access tokens and non-secret session metadata (country code,
/// user id, expiry timestamp) remain in [NetworkServerEntity.token].
class TidalTokenStore {
  TidalTokenStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static String _key(int serverId) => 'tidal_refresh_token_$serverId';

  Future<String?> read(int serverId) => _storage.read(key: _key(serverId));

  Future<void> write(int serverId, String refreshToken) =>
      _storage.write(key: _key(serverId), value: refreshToken);

  Future<void> delete(int serverId) => _storage.delete(key: _key(serverId));
}
