import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/services/scrobble_queue.dart';

class _TestEntry {
  final String title;
  final int timestamp;

  _TestEntry(this.title, this.timestamp);

  Map<String, dynamic> toJson() => {'title': title, 'ts': timestamp};

  factory _TestEntry.fromJson(Map<String, dynamic> json) =>
      _TestEntry(json['title'] as String, json['ts'] as int);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('enqueue and flush successfully clears queue', () async {
    final sent = <List<_TestEntry>>[];
    final queue = ScrobbleQueue<_TestEntry>(
      logTag: '[Test]',
      queueKey: 'test_queue',
      maxQueueSize: 5,
      toJson: (e) => e.toJson(),
      fromJson: (json) => _TestEntry.fromJson(json),
      describeEntry: (e) => 'title=${e.title}',
      sendBatch: (entries) async {
        sent.add(entries);
      },
    );

    await queue.enqueue(_TestEntry('Song 1', 100));
    await queue.enqueue(_TestEntry('Song 2', 200));

    expect(sent, isEmpty);

    await queue.flush();

    expect(sent.length, 1);
    expect(sent.first.map((e) => e.title), ['Song 1', 'Song 2']);

    // Flushing an empty queue is a no-op
    await queue.flush();
    expect(sent.length, 1);
  });

  test('enqueue drops oldest entries when exceeding maxQueueSize', () async {
    final sent = <List<_TestEntry>>[];
    final queue = ScrobbleQueue<_TestEntry>(
      logTag: '[Test]',
      queueKey: 'test_overflow_queue',
      maxQueueSize: 3,
      toJson: (e) => e.toJson(),
      fromJson: (json) => _TestEntry.fromJson(json),
      describeEntry: (e) => 'title=${e.title}',
      sendBatch: (entries) async {
        sent.add(entries);
      },
    );

    await queue.enqueue(_TestEntry('Song 1', 100));
    await queue.enqueue(_TestEntry('Song 2', 200));
    await queue.enqueue(_TestEntry('Song 3', 300));
    await queue.enqueue(_TestEntry('Song 4', 400));

    await queue.flush();

    expect(sent.length, 1);
    expect(sent.first.map((e) => e.title), ['Song 2', 'Song 3', 'Song 4']);
  });

  test('flush retains queue on auth error', () async {
    var attempt = 0;
    final queue = ScrobbleQueue<_TestEntry>(
      logTag: '[Test]',
      queueKey: 'test_auth_error_queue',
      maxQueueSize: 5,
      toJson: (e) => e.toJson(),
      fromJson: (json) => _TestEntry.fromJson(json),
      describeEntry: (e) => 'title=${e.title}',
      sendBatch: (entries) async {
        attempt++;
        if (attempt == 1) {
          throw FormatException('auth expired');
        }
      },
      handleAuthError: (e) => e is FormatException,
    );

    await queue.enqueue(_TestEntry('Song 1', 100));

    // First flush throws auth error, which is caught and handled (queue retained)
    await queue.flush();

    // Second flush succeeds because attempt == 2
    await queue.flush();
    expect(attempt, 2);
  });
}
