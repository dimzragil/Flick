import 'dart:io';

/// Writes [bytes] to [target] atomically: data goes to a temp file in the
/// same directory first, then renames over the target. A kill mid-write can
/// only leave a stray temp file — never a truncated target.
Future<void> atomicWriteBytes(File target, List<int> bytes) async {
  final dir = target.parent;
  final temp = File(
    '${dir.path}/.tmp_${DateTime.now().microsecondsSinceEpoch}_${target.path.hashCode}',
  );
  try {
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
  } catch (_) {
    // Best effort: don't leave the temp file behind.
    try {
      if (await temp.exists()) await temp.delete();
    } catch (_) {}
    rethrow;
  }
}
