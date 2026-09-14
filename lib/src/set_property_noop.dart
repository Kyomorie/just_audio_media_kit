import 'package:media_kit/media_kit.dart';

class NativeSeekSnapshot {
  const NativeSeekSnapshot({
    required this.seeking,
    required this.position,
    required this.index,
  });

  final bool seeking;
  final Duration position;
  final int index;
}

Future<void> excludeAudioDecoders(Player player, Set<String> excluded) async {}

Future<void> setProperty(Player player, String key, dynamic value) {
  // noop
  return Future.value();
}

Future<bool?> isNativeEffectivelyPlaying(Player player) async => null;

Future<NativeSeekSnapshot?> getNativeSeekSnapshot(Player player) async => null;
