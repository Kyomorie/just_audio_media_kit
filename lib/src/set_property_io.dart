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
