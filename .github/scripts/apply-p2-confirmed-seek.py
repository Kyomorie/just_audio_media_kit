from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one match, found {count}')
    p.write_text(text.replace(old, new, 1))

io = 'lib/src/set_property_io.dart'
replace_once(
    io,
    '''import 'package:media_kit/media_kit.dart';

''',
    '''import 'package:media_kit/media_kit.dart';

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

bool _nativeFlag(String name, String value) {
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

''',
    'io header',
)
replace_once(
    io,
    '''  bool flag(String name, String value) {
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
''',
    '''  final paused = _nativeFlag('pause', values[0]);
  final coreIdle = _nativeFlag('core-idle', values[1]);
  final seeking = _nativeFlag('seeking', values[2]);
  final pausedForCache = _nativeFlag('paused-for-cache', values[3]);
  final eofReached = _nativeFlag('eof-reached', values[4]);
  return !paused && !coreIdle && !seeking && !pausedForCache && !eofReached;
}

Future<NativeSeekSnapshot?> getNativeSeekSnapshot(Player player) async {
  if (player.platform is! NativePlayer) return null;
  final native = player.platform as NativePlayer;
  final values = await Future.wait([
    native.getProperty('seeking'),
    native.getProperty('time-pos'),
    native.getProperty('playlist-pos'),
  ]);

  final positionSeconds = double.tryParse(values[1].trim());
  final index = int.tryParse(values[2].trim());
  if (positionSeconds == null || !positionSeconds.isFinite || index == null) {
    throw StateError(
      'Unexpected libmpv seek state seeking=${values[0]} time-pos=${values[1]} playlist-pos=${values[2]}',
    );
  }

  return NativeSeekSnapshot(
    seeking: _nativeFlag('seeking', values[0]),
    position: Duration(microseconds: (positionSeconds * Duration.microsecondsPerSecond).round()),
    index: index,
  );
}
''',
    'io native snapshot',
)

noop = 'lib/src/set_property_noop.dart'
replace_once(
    noop,
    '''import 'package:media_kit/media_kit.dart';

''',
    '''import 'package:media_kit/media_kit.dart';

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

''',
    'noop header',
)
p = Path(noop)
text = p.read_text()
text += '''\nFuture<NativeSeekSnapshot?> getNativeSeekSnapshot(Player player) async => null;\n'''
p.write_text(text)

player = 'lib/src/mediakit_player.dart'
marker = '''  @override
  Future<SeekResponse> seek(SeekRequest request) async {
'''
method = '''  @override
  Future<ConfirmedSeekResponse> seekConfirmed(
      ConfirmedSeekRequest request) async {
    _advancePlaybackControlEpoch();
    _emitEffectivePlaying(false);
    _logger.finest('seekConfirmed(${request.toMap()})');

    if (_released) {
      return ConfirmedSeekResponse(
        status: SeekConfirmationStatusMessage.failed,
        errorMessage: 'Player released',
      );
    }
    if (_failed) {
      return ConfirmedSeekResponse(
        status: SeekConfirmationStatusMessage.failed,
        errorMessage: _errorMessage,
      );
    }
    if (!_mediaOpened ||
        _processingState == ProcessingStateMessage.idle ||
        _processingState == ProcessingStateMessage.loading ||
        (request.position == null && request.index == null)) {
      return ConfirmedSeekResponse(
        status: SeekConfirmationStatusMessage.rejected,
      );
    }

    final sourceEpoch = _playbackSourceEpoch;
    final controlEpoch = _playbackControlEpoch;
    final playlist = _player.state.playlist;
    final targetIndex = request.index ?? _currentIndex;
    if (targetIndex < 0 || targetIndex >= playlist.medias.length) {
      return ConfirmedSeekResponse(
        status: SeekConfirmationStatusMessage.rejected,
      );
    }
    final targetStart = playlist.medias[targetIndex].start ?? Duration.zero;

    bool superseded() => _released ||
        sourceEpoch != _playbackSourceEpoch ||
        controlEpoch != _playbackControlEpoch;

    try {
      if (request.index != null) {
        await _player.jump(targetIndex);
        if (!_playing) await _player.pause();
        if (superseded()) {
          return ConfirmedSeekResponse(
            status: SeekConfirmationStatusMessage.superseded,
          );
        }
      }

      final requestedPosition = request.position;
      Duration? requestedNativePosition;
      if (requestedPosition != null) {
        requestedNativePosition = requestedPosition + targetStart;
        _position = requestedPosition;
        if (_player.state.duration <= Duration.zero) {
          return ConfirmedSeekResponse(
            status: SeekConfirmationStatusMessage.rejected,
          );
        }
        await (_pendingSeek = _player.seek(requestedNativePosition));
      }

      const maxChecks = 100;
      const checkDelay = Duration(milliseconds: 25);
      const positionTolerance = Duration(milliseconds: 1500);
      for (var check = 0; check < maxChecks; check++) {
        if (superseded()) {
          return ConfirmedSeekResponse(
            status: SeekConfirmationStatusMessage.superseded,
          );
        }
        if (_failed) {
          return ConfirmedSeekResponse(
            status: SeekConfirmationStatusMessage.failed,
            errorMessage: _errorMessage,
          );
        }

        final snapshot = await getNativeSeekSnapshot(_player);
        if (snapshot == null) {
          return ConfirmedSeekResponse(
            status: SeekConfirmationStatusMessage.unsupported,
          );
        }
        if (superseded()) {
          return ConfirmedSeekResponse(
            status: SeekConfirmationStatusMessage.superseded,
          );
        }

        final nativeIndexMatches = snapshot.index == targetIndex;
        final nativePositionMatches = requestedNativePosition == null ||
            (snapshot.position - requestedNativePosition).abs() <=
                positionTolerance;
        if (!snapshot.seeking && nativeIndexMatches && nativePositionMatches) {
          var actualPosition = snapshot.position - targetStart;
          if (actualPosition < Duration.zero) actualPosition = Duration.zero;
          _position = actualPosition;
          _currentIndex = snapshot.index;
          _updatePlaybackEvent();
          _schedulePlaybackEvaluation();
          return ConfirmedSeekResponse(
            status: SeekConfirmationStatusMessage.reached,
            actualPosition: actualPosition,
            actualIndex: snapshot.index,
          );
        }

        if (check + 1 < maxChecks) {
          await Future<void>.delayed(checkDelay);
        }
      }

      return ConfirmedSeekResponse(
        status: SeekConfirmationStatusMessage.failed,
        errorMessage: 'Native seek could not be confirmed',
      );
    } catch (error) {
      if (superseded()) {
        return ConfirmedSeekResponse(
          status: SeekConfirmationStatusMessage.superseded,
        );
      }
      return ConfirmedSeekResponse(
        status: SeekConfirmationStatusMessage.failed,
        errorMessage: error.toString(),
      );
    }
  }

'''
p = Path(player)
text = p.read_text()
if text.count(marker) != 1:
    raise SystemExit('seek insertion marker mismatch')
p.write_text(text.replace(marker, method + marker, 1))
