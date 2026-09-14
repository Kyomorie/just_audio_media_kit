from pathlib import Path

path = Path('lib/src/mediakit_player.dart')
text = path.read_text()
old = '''        requestedNativePosition = requestedPosition + targetStart;
        _position = requestedPosition;
        if (_player.state.duration <= Duration.zero) {
          return ConfirmedSeekResponse(
            status: SeekConfirmationStatusMessage.rejected,
          );
        }
        await (_pendingSeek = _player.seek(requestedNativePosition));
'''
new = '''        final nativePosition = requestedPosition + targetStart;
        requestedNativePosition = nativePosition;
        _position = requestedPosition;
        if (_player.state.duration <= Duration.zero) {
          return ConfirmedSeekResponse(
            status: SeekConfirmationStatusMessage.rejected,
          );
        }
        await (_pendingSeek = _player.seek(nativePosition));
'''
if text.count(old) != 1:
    raise SystemExit(f'expected one confirmed-seek nullability block, found {text.count(old)}')
path.write_text(text.replace(old, new, 1))
