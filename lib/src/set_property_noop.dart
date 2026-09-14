import 'package:media_kit/media_kit.dart';

Future<void> excludeAudioDecoders(Player player, Set<String> excluded) async {}

Future<void> setProperty(Player player, String key, dynamic value) {
  // noop
  return Future.value();
}

Future<bool?> isNativeEffectivelyPlaying(Player player) async => null;
