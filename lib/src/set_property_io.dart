import 'package:media_kit/media_kit.dart';

Future<void> excludeAudioDecoders(Player player, Set<String> excluded) async {
  if (excluded.isEmpty || player.platform is! NativePlayer) return;
  final native = player.platform as NativePlayer;
  final count = int.parse(await native.getProperty('decoder-list/count'));
  final allowed = <String>[];
  var foundExcluded = false;
  for (var index = 0; index < count; index++) {
    final decoder = await native.getProperty('decoder-list/$index/driver');
    if (excluded.contains(decoder)) {
      foundExcluded = true;
    } else {
      allowed.add(decoder);
    }
  }
  if (!foundExcluded) return;
  final selection = [...allowed, '-'].join(',');
  await native.setProperty('ad', selection);
  if (await native.getProperty('ad') != selection) {
    throw StateError('Could not apply audio decoder exclusions');
  }
}

Future<void> setProperty(Player player, String key, dynamic value) async {
  if (player.platform is! NativePlayer) return;
  await (player.platform as NativePlayer).setProperty(key, value);
}

Future<bool?> isNativeEffectivelyPlaying(Player player) async {
  if (player.platform is! NativePlayer) return null;
  final native = player.platform as NativePlayer;
  final values = await Future.wait([
    native.getProperty('pause'),
    native.getProperty('core-idle'),
    native.getProperty('seeking'),
    native.getProperty('paused-for-cache'),
    native.getProperty('eof-reached'),
  ]);

  bool flag(String name, String value) {
    switch (value.trim().toLowerCase()) {
      case 'yes':
      case 'true':
      case '1':
        return true;
      case 'no':
      case 'false':
      case '0':
        return false;
      default:
        throw StateError('Unexpected libmpv flag $name=$value');
    }
  }

  final paused = flag('pause', values[0]);
  final coreIdle = flag('core-idle', values[1]);
  final seeking = flag('seeking', values[2]);
  final pausedForCache = flag('paused-for-cache', values[3]);
  final eofReached = flag('eof-reached', values[4]);
  return !paused && !coreIdle && !seeking && !pausedForCache && !eofReached;
}
