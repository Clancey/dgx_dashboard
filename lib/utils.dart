/// Log to the terminal with a timestamp.
void log(String message) {
  final now = DateTime.now();
  final time = [
    now.hour,
    now.minute,
    now.second,
  ].map((x) => x.toString().padLeft(2, '0')).join(':');
  print('$time: $message');
}
