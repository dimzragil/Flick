/// Converts a raw exception into a short, user-friendly message for UI display.
///
/// Strips Dart exception type prefixes ("StateError: ", "Exception: "),
/// drops stack traces, and caps the length so a SnackBar/dialog never shows
/// a wall of technical text.
String friendlyErrorMessage(Object error) {
  var message = error.toString();
  // Drop stack traces: keep only the first line.
  final newline = message.indexOf('\n');
  if (newline != -1) {
    message = message.substring(0, newline);
  }
  // Strip common Dart exception prefixes.
  for (final prefix in [
    'StateError: ',
    'Exception: ',
    'FormatException: ',
    'TidalException: ',
  ]) {
    if (message.startsWith(prefix)) {
      message = message.substring(prefix.length);
      break;
    }
  }
  message = message.trim();
  const maxLength = 160;
  if (message.length > maxLength) {
    message = '${message.substring(0, maxLength - 1)}…';
  }
  return message.isEmpty ? 'Unknown error' : message;
}
