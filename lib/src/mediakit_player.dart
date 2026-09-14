import 'dart:async';

import 'package:flutter/services.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';

import 'set_property.dart';

/// An [AudioPlayerPlatform] which wraps `package:media_kit`'s [Player]
class MediaKitPlayer extends AudioPlayerPlatform {
  static const kErrorCode = 1;

  /// `package:media_kit`'s [Player]
  late final Player _player;

  /// The subscriptions that have to be disposed
  late final List<StreamSubscription> _streamSubscriptions;

  final _readyCompleter = Completer<void>();

  /// Completes when the player is ready
  Future<void> ready() => _configurationFuture ??= _configure();

  Future<void>? _configurationFuture;

  Future<void> _configure() async {
    await _readyCompleter.future;
    await excludeAudioDecoders(
      _player,
      JustAudioMediaKit.excludedAudioDecoders,
    );
  }

  static final _logger = Logger('MediaKitPlayer');

  final _eventController = StreamController<PlaybackEventMessage>.broadcast();
  final _dataController = StreamController<PlayerDataMessage>.broadcast();

  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  Duration _bufferedPosition = Duration.zero;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _mediaOpened = false;
  int? _errorCode;
  String? _errorMessage;
  Completer<Duration?>? _loadCompleter;
  bool _released = false;
  bool _failed = false;
  int _playbackSourceEpoch = 0;
  int _playbackControlEpoch = 0;
  Completer<AwaitPlaybackStartResponse>? _playbackStartCompleter;
  int? _playbackStartSourceEpoch;
  int? _playbackStartControlEpoch;
  int? _playbackStartIndex;
  String? _playbackStartAttemptId;
  bool _lastEffectivePlaying = false;
  bool _playbackEvaluationRunning = false;
  bool _playbackEvaluationPending = false;
  Future<void>? _pendingSeek;
  Future<void>? _pendingOpen;
  Future<void>? _releaseFuture;

  /// The index that's currently playing
  int _currentIndex = 0;

  /// [LoadRequest.initialPosition] or [seek] request before [Player.play] was called and/or finished loading.
  Duration? _setPosition;

  Media? get _currentMedia {
    final playlist = _player.state.playlist;
    final index = playlist.index;
    if (index < 0 || index >= playlist.medias.length) return null;
    return playlist.medias[index];
  }

  void _completePlaybackStart(
    PlaybackStartStatusMessage status, {
    String? errorMessage,
  }) {
    final completer = _playbackStartCompleter;
    if (completer == null) return;
    _playbackStartCompleter = null;
    _playbackStartSourceEpoch = null;
    _playbackStartControlEpoch = null;
    _playbackStartIndex = null;
    _playbackStartAttemptId = null;
    if (!completer.isCompleted) {
      completer.complete(
        AwaitPlaybackStartResponse(status: status, errorMessage: errorMessage),
      );
    }
  }

  void _advancePlaybackSourceEpoch() {
    _playbackSourceEpoch++;
    _playbackControlEpoch++;
    _completePlaybackStart(PlaybackStartStatusMessage.superseded);
    _emitEffectivePlaying(false);
  }

  void _advancePlaybackControlEpoch() {
    _playbackControlEpoch++;
    _completePlaybackStart(PlaybackStartStatusMessage.superseded);
  }

  void _emitEffectivePlaying(bool effectivePlaying) {
    if (_lastEffectivePlaying == effectivePlaying) return;
    _lastEffectivePlaying = effectivePlaying;
    _dataController.add(PlayerDataMessage(effectivePlaying: effectivePlaying));
  }

  void _schedulePlaybackEvaluation() {
    if (_released) return;
    _playbackEvaluationPending = true;
    if (_playbackEvaluationRunning) return;
    _playbackEvaluationRunning = true;
    unawaited(_drainPlaybackEvaluations());
  }

  Future<void> _drainPlaybackEvaluations() async {
    try {
      while (_playbackEvaluationPending && !_released) {
        _playbackEvaluationPending = false;
        await _evaluatePlaybackState();
      }
    } finally {
      _playbackEvaluationRunning = false;
      if (_playbackEvaluationPending && !_released) {
        _schedulePlaybackEvaluation();
      }
    }
  }

  Future<void> _evaluatePlaybackState() async {
    final sourceEpoch = _playbackSourceEpoch;
    final controlEpoch = _playbackControlEpoch;
    final index = _currentIndex;
    final attemptId = _playbackStartAttemptId;

    bool? nativeEffectivePlaying;
    try {
      nativeEffectivePlaying = await isNativeEffectivelyPlaying(_player);
    } catch (error) {
      if (_released ||
          sourceEpoch != _playbackSourceEpoch ||
          controlEpoch != _playbackControlEpoch ||
          index != _currentIndex) {
        return;
      }
      _emitEffectivePlaying(false);
      if (attemptId != null && attemptId == _playbackStartAttemptId) {
        _completePlaybackStart(
          PlaybackStartStatusMessage.failed,
          errorMessage: error.toString(),
        );
      }
      return;
    }

    if (_released ||
        sourceEpoch != _playbackSourceEpoch ||
        controlEpoch != _playbackControlEpoch ||
        index != _currentIndex) {
      return;
    }

    final effectivePlaying =
        nativeEffectivePlaying == true &&
        _playing &&
        _mediaOpened &&
        !_failed &&
        _processingState == ProcessingStateMessage.ready;
    _emitEffectivePlaying(effectivePlaying);

    if (attemptId == null || attemptId != _playbackStartAttemptId) return;
    if (_playbackStartSourceEpoch != _playbackSourceEpoch ||
        _playbackStartControlEpoch != _playbackControlEpoch ||
        _playbackStartIndex != _currentIndex) {
      _completePlaybackStart(PlaybackStartStatusMessage.superseded);
      return;
    }
    if (nativeEffectivePlaying == null) {
      _completePlaybackStart(PlaybackStartStatusMessage.unsupported);
      return;
    }
    if (_failed) {
      _completePlaybackStart(PlaybackStartStatusMessage.failed);
      return;
    }
    if (!_playing ||
        _processingState == ProcessingStateMessage.idle ||
        _processingState == ProcessingStateMessage.completed) {
      _completePlaybackStart(PlaybackStartStatusMessage.rejected);
      return;
    }
    if (effectivePlaying) {
      _completePlaybackStart(PlaybackStartStatusMessage.started);
    }
  }

  MediaKitPlayer(super.id) {
    _player = Player(
      configuration: PlayerConfiguration(
        pitch: JustAudioMediaKit.pitch,
        protocolWhitelist: JustAudioMediaKit.protocolWhitelist,
        title: JustAudioMediaKit.title,
        bufferSize: JustAudioMediaKit.bufferSize,
        logLevel: JustAudioMediaKit.mpvLogLevel,
        ready: () => _readyCompleter.complete(),
      ),
    );

    if (JustAudioMediaKit.prefetchPlaylist) {
      setProperty(_player, 'prefetch-playlist', 'yes');
    }
    if (JustAudioMediaKit.tlsCertFile != null) {
      setProperty(_player, 'tls-cert-file', JustAudioMediaKit.tlsCertFile!);
    }
    if (JustAudioMediaKit.tlsKeyFile != null) {
      setProperty(_player, 'tls-key-file', JustAudioMediaKit.tlsKeyFile!);
    }

    _streamSubscriptions = [
      _player.stream.duration.listen((duration) {
        if (_released || _failed) return;
        if (_currentMedia?.extras?['overrideDuration'] != null) return;

        if (_setPosition != null && duration.inSeconds > 0) {
          final position = _setPosition!;
          _setPosition = null;
          _pendingSeek = _seekInitialPosition(position);
        }
        _updateDuration(duration);
        _updatePlaybackEvent();
        if (_playbackStartCompleter != null) {
          _schedulePlaybackEvaluation();
        }
      }),
      _player.stream.position.listen((position) {
        _position = position;
        final start = _currentMedia?.start;
        if (start != null) _position -= start;
        if (_position < Duration.zero) _position = Duration.zero;
        _updatePlaybackEvent();
        if (_playbackStartCompleter != null) {
          _schedulePlaybackEvaluation();
        }
      }),
      _player.stream.buffering.listen((isBuffering) {
        if (_released || _failed) return;
        final start = _currentMedia?.start;
        if (!isBuffering && start != null && _bufferedPosition <= start) {
          // Not ready yet, will be triggered by _player.stream.buffer
          return;
        }
        if (_processingState == ProcessingStateMessage.loading) {
          if (!isBuffering && _mediaOpened) {
            _processingState = ProcessingStateMessage.ready;
            if (_loadCompleter?.isCompleted != true) {
              _loadCompleter?.complete(_duration);
            }
          }
        } else if (_processingState != ProcessingStateMessage.completed ||
            isBuffering) {
          _processingState = isBuffering
              ? ProcessingStateMessage.buffering
              : ProcessingStateMessage.ready;
          if (_duration == null) {
            _updateDuration(_player.state.duration);
          }
        }
        _errorCode = null;
        _errorMessage = null;
        _updatePlaybackEvent();
        _schedulePlaybackEvaluation();
      }),
      _player.stream.buffer.listen((buffer) {
        if (_released || _failed) return;
        _bufferedPosition = buffer;
        // Detect ready for clipping audio source
        final start = _currentMedia?.start;
        if (!_player.state.buffering &&
            _mediaOpened &&
            start != null &&
            _bufferedPosition > start) {
          _processingState = ProcessingStateMessage.ready;
          if (_loadCompleter?.isCompleted != true) {
            _loadCompleter?.complete(_duration);
          }
        }
        _updatePlaybackEvent();
        if (_playbackStartCompleter != null) {
          _schedulePlaybackEvaluation();
        }
      }),
      _player.stream.playing.listen((_) {
        if (_released || _failed) return;
        _schedulePlaybackEvaluation();
      }),
      _player.stream.volume.listen((volume) {
        _dataController.add(PlayerDataMessage(volume: volume / 100.0));
      }),
      _player.stream.completed.listen((completed) {
        if (_released || _failed) return;
        _bufferedPosition = _position = Duration.zero;
        if (completed &&
            // is at the end of the [Playlist]
            _currentIndex == _player.state.playlist.medias.length - 1 &&
            // is not looping (technically this shouldn't be fired if the player is looping)
            _player.state.playlistMode == PlaylistMode.none) {
          _processingState = ProcessingStateMessage.completed;
        }
        _errorCode = null;
        _errorMessage = null;

        _updatePlaybackEvent();
        _schedulePlaybackEvaluation();
      }),
      _player.stream.error.listen((error) {
        final errorUri = RegExp(r'Failed to open (.*)\.').firstMatch(error)?[1];
        if (errorUri == null ||
            errorUri == _currentMedia?.uri ||
            _processingState == ProcessingStateMessage.loading) {
          _reportError(error);
        }
        _logger.severe('ERROR OCCURRED: $error');
      }),
      _player.stream.playlist.listen((playlist) {
        // mpv can emit an end sentinel after failing the last playlist entry.
        if (playlist.index < 0 || playlist.index >= playlist.medias.length) {
          return;
        }
        if (_currentIndex != playlist.index) {
          _bufferedPosition = _position = Duration.zero;
          _currentIndex = playlist.index;
        }
        _duration = _currentMedia?.extras?['overrideDuration'];
        _updatePlaybackEvent();
        _schedulePlaybackEvaluation();
      }),
      _player.stream.playlistMode.listen((playlistMode) {
        _dataController.add(
          PlayerDataMessage(loopMode: _playlistModeToLoopMode(playlistMode)),
        );
      }),
      _player.stream.pitch.listen((pitch) {
        _dataController.add(PlayerDataMessage(pitch: pitch));
      }),
      _player.stream.rate.listen((rate) {
        _dataController.add(PlayerDataMessage(speed: rate));
      }),
      _player.stream.log.listen((event) {
        // ignore: avoid_print
        print("MPV: [${event.level}] ${event.prefix}: ${event.text}");
      }),
    ];
  }

  Future<void> _seekInitialPosition(Duration position) async {
    try {
      await _player.seek(position);
    } catch (error) {
      _reportError(error.toString());
    }
  }

  void _reportError(String message) {
    if (_released || _failed) return;
    _failed = true;
    _emitEffectivePlaying(false);
    _completePlaybackStart(
      PlaybackStartStatusMessage.failed,
      errorMessage: message,
    );
    _mediaOpened = false;
    _setPosition = null;
    _processingState = ProcessingStateMessage.idle;
    _errorCode = kErrorCode;
    _errorMessage = message;
    final load = _loadCompleter;
    if (load != null && !load.isCompleted) {
      load.completeError(
        PlatformException(code: '$kErrorCode', message: message),
      );
    }
    _updatePlaybackEvent();
  }

  void _updateDuration(Duration duration) {
    final start = _currentMedia?.start;
    final end = _currentMedia?.end;
    if (end != null) duration = end;
    if (start != null) duration -= start;
    _duration = duration;
  }

  PlaylistMode _loopModeToPlaylistMode(LoopModeMessage loopMode) {
    return switch (loopMode) {
      LoopModeMessage.off => PlaylistMode.none,
      LoopModeMessage.one => PlaylistMode.single,
      LoopModeMessage.all => PlaylistMode.loop,
    };
  }

  LoopModeMessage _playlistModeToLoopMode(PlaylistMode playlistMode) {
    return switch (playlistMode) {
      PlaylistMode.none => LoopModeMessage.off,
      PlaylistMode.single => LoopModeMessage.one,
      PlaylistMode.loop => LoopModeMessage.loop,
    };
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataController.stream;

  /// Updates the playback event
  void _updatePlaybackEvent() {
    if (_released) return;
    _eventController.add(
      PlaybackEventMessage(
        processingState: _processingState,
        updateTime: DateTime.now(),
        updatePosition: _position,
        bufferedPosition: _bufferedPosition,
        duration: _duration,
        icyMetadata: null,
        currentIndex: _currentIndex,
        androidAudioSessionId: null,
        errorCode: _errorCode,
        errorMessage: _errorMessage,
      ),
    );
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    if (_released) {
      throw PlatformException(code: 'abort', message: 'Player released');
    }
    _advancePlaybackSourceEpoch();
    _logger.finest('load(${request.toMap()})');
    _mediaOpened = false;
    final load = _loadCompleter = Completer<Duration?>();
    // Errors may arrive during open(), before we await this future below.
    load.future.ignore();
    _failed = false;
    _setPosition = null;
    _currentIndex = request.initialIndex ?? 0;
    _bufferedPosition = Duration.zero;
    _position = Duration.zero;
    _duration = null;
    _processingState = ProcessingStateMessage.loading;
    _errorCode = null;
    _errorMessage = null;
    _updatePlaybackEvent();

    if (request.audioSourceMessage is ConcatenatingAudioSourceMessage) {
      final audioSource =
          request.audioSourceMessage as ConcatenatingAudioSourceMessage;
      final playable = Playlist(
        audioSource.children.map(_convertAudioSourceIntoMediaKit).toList(),
        index: _currentIndex,
      );

      await (_pendingOpen = _player.open(playable, play: _playing));
    } else {
      final playable = _convertAudioSourceIntoMediaKit(
        request.audioSourceMessage,
      );
      _logger.finest('playable is ${playable.toString()}');
      await (_pendingOpen = _player.open(playable, play: _playing));
    }
    if (_released || _failed) return LoadResponse(duration: await load.future);
    _mediaOpened = true;

    if (request.initialPosition != null &&
        request.initialPosition! > Duration.zero) {
      _setPosition = _position = request.initialPosition!;
      if (_player.state.duration > Duration.zero) {
        _setPosition = null;
        await (_pendingSeek = _seekInitialPosition(request.initialPosition!));
      }
    }

    if (!_failed &&
        !_released &&
        !_player.state.buffering &&
        _player.state.duration > Duration.zero &&
        !load.isCompleted) {
      _updateDuration(_player.state.duration);
      _processingState = ProcessingStateMessage.ready;
      load.complete(_duration);
    }
    _updatePlaybackEvent();
    _schedulePlaybackEvaluation();
    final duration = await load.future;
    return LoadResponse(duration: duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    if (!_playing) {
      _advancePlaybackControlEpoch();
      _playing = true;
    }
    // just_audio may legitimately issue a duplicate native play request while
    // load/play activation races settle. Preserve the adapter's prior
    // idempotent native play dispatch, but keep the same control epoch so an
    // in-flight playback-start ack is not spuriously superseded.
    if (_mediaOpened) {
      await _player.play();
    }
    _schedulePlaybackEvaluation();
    return PlayResponse();
  }

  @override
  Future<AwaitPlaybackStartResponse> awaitPlaybackStart(
    AwaitPlaybackStartRequest request,
  ) {
    _completePlaybackStart(PlaybackStartStatusMessage.superseded);
    if (_released) {
      return Future.value(
        AwaitPlaybackStartResponse(
          status: PlaybackStartStatusMessage.failed,
          errorMessage: 'Player released',
        ),
      );
    }
    if (!_playing ||
        _processingState == ProcessingStateMessage.idle ||
        _processingState == ProcessingStateMessage.completed) {
      return Future.value(
        AwaitPlaybackStartResponse(status: PlaybackStartStatusMessage.rejected),
      );
    }
    final completer = Completer<AwaitPlaybackStartResponse>();
    _playbackStartCompleter = completer;
    _playbackStartSourceEpoch = _playbackSourceEpoch;
    _playbackStartControlEpoch = _playbackControlEpoch;
    _playbackStartIndex = _currentIndex;
    _playbackStartAttemptId = request.attemptId;
    _schedulePlaybackEvaluation();
    return completer.future;
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _advancePlaybackControlEpoch();
    _playing = false;
    if (_mediaOpened) {
      await _player.pause();
    }
    _schedulePlaybackEvaluation();
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) {
    return _player
        .setVolume(request.volume * 100.0)
        .then((value) => SetVolumeResponse());
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) {
    return _player.setRate(request.speed).then((_) => SetSpeedResponse());
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) =>
      _player.setPitch(request.pitch).then((_) => SetPitchResponse());

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    await _player.setPlaylistMode(_loopModeToPlaylistMode(request.loopMode));
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async {
    bool shuffling = request.shuffleMode != ShuffleModeMessage.none;
    await _player.setShuffle(shuffling);

    _dataController.add(
      PlayerDataMessage(
        shuffleMode: shuffling
            ? ShuffleModeMessage.all
            : ShuffleModeMessage.none,
      ),
    );
    return SetShuffleModeResponse();
  }

  @override
  Future<ConfirmedSeekResponse> seekConfirmed(
    ConfirmedSeekRequest request,
  ) async {
    _advancePlaybackControlEpoch();
    _emitEffectivePlaying(false);
    _logger.finest('seekConfirmed(${request.toMap()})');

    if (_released) {
      _schedulePlaybackEvaluation();
      return ConfirmedSeekResponse(
        status: SeekConfirmationStatusMessage.failed,
        errorMessage: 'Player released',
      );
    }
    if (_failed) {
      _schedulePlaybackEvaluation();
      return ConfirmedSeekResponse(
        status: SeekConfirmationStatusMessage.failed,
        errorMessage: _errorMessage,
      );
    }
    if (!_mediaOpened ||
        _processingState == ProcessingStateMessage.idle ||
        _processingState == ProcessingStateMessage.loading ||
        (request.position == null && request.index == null)) {
      _schedulePlaybackEvaluation();
      return ConfirmedSeekResponse(
        status: SeekConfirmationStatusMessage.rejected,
      );
    }

    final sourceEpoch = _playbackSourceEpoch;
    final controlEpoch = _playbackControlEpoch;
    final playlist = _player.state.playlist;
    final targetIndex = request.index ?? _currentIndex;
    if (targetIndex < 0 || targetIndex >= playlist.medias.length) {
      _schedulePlaybackEvaluation();
      return ConfirmedSeekResponse(
        status: SeekConfirmationStatusMessage.rejected,
      );
    }
    final targetStart = playlist.medias[targetIndex].start ?? Duration.zero;

    bool superseded() =>
        _released ||
        sourceEpoch != _playbackSourceEpoch ||
        controlEpoch != _playbackControlEpoch;

    try {
      if (request.index != null) {
        await _player.jump(targetIndex);
        if (!_playing) await _player.pause();
        if (superseded()) {
          _schedulePlaybackEvaluation();
          return ConfirmedSeekResponse(
            status: SeekConfirmationStatusMessage.superseded,
          );
        }
      }

      final requestedPosition = request.position;
      Duration? requestedNativePosition;
      if (requestedPosition != null) {
        final nativePosition = requestedPosition + targetStart;
        requestedNativePosition = nativePosition;
        _position = requestedPosition;
        if (_player.state.duration <= Duration.zero) {
          _schedulePlaybackEvaluation();
          return ConfirmedSeekResponse(
            status: SeekConfirmationStatusMessage.rejected,
          );
        }
        await (_pendingSeek = _player.seek(nativePosition));
      }

      const maxChecks = 100;
      const checkDelay = Duration(milliseconds: 25);
      const positionTolerance = Duration(milliseconds: 1500);
      for (var check = 0; check < maxChecks; check++) {
        if (superseded()) {
          _schedulePlaybackEvaluation();
          return ConfirmedSeekResponse(
            status: SeekConfirmationStatusMessage.superseded,
          );
        }
        if (_failed) {
          _schedulePlaybackEvaluation();
          return ConfirmedSeekResponse(
            status: SeekConfirmationStatusMessage.failed,
            errorMessage: _errorMessage,
          );
        }

        final snapshot = await getNativeSeekSnapshot(_player);
        if (snapshot == null) {
          _schedulePlaybackEvaluation();
          return ConfirmedSeekResponse(
            status: SeekConfirmationStatusMessage.unsupported,
          );
        }
        if (superseded()) {
          _schedulePlaybackEvaluation();
          return ConfirmedSeekResponse(
            status: SeekConfirmationStatusMessage.superseded,
          );
        }

        final nativeIndexMatches = snapshot.index == targetIndex;
        final nativePositionMatches =
            requestedNativePosition == null ||
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

      _schedulePlaybackEvaluation();
      return ConfirmedSeekResponse(
        status: SeekConfirmationStatusMessage.failed,
        errorMessage: 'Native seek could not be confirmed',
      );
    } catch (error) {
      _schedulePlaybackEvaluation();
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

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _advancePlaybackControlEpoch();
    _emitEffectivePlaying(false);
    _logger.finest('seek(${request.toMap()})');
    if (request.index != null) {
      await _player.jump(request.index!);
      if (!_playing) await _player.pause();
    }

    final position = request.position;
    if (position != null) {
      _position = position;

      final start = _currentMedia?.start;
      var nativePosition = position;
      if (start != null) nativePosition += start;
      if (_player.state.duration.inSeconds > 0) {
        await _player.seek(nativePosition);
      } else {
        _setPosition = nativePosition;
      }
    } else {
      _position = Duration.zero;
    }

    // reset position on seek
    _updatePlaybackEvent();
    _schedulePlaybackEvaluation();
    return SeekResponse();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
    ConcatenatingInsertAllRequest request,
  ) async {
    // _logger.fine('concatenatingInsertAll(${request.toMap()})');
    for (final source in request.children) {
      await _player.add(_convertAudioSourceIntoMediaKit(source));

      final length = _player.state.playlist.medias.length;

      if (length == 0 || length == 1) continue;

      if (request.index < (length - 1) && request.index >= 0) {
        await _player.move(length, request.index);
      }
    }

    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
    ConcatenatingRemoveRangeRequest request,
  ) async {
    for (var i = request.startIndex; i < request.endIndex; i++) {
      await _player.remove(request.startIndex);
    }

    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
    ConcatenatingMoveRequest request,
  ) {
    return _player
        .move(
          request.currentIndex,
          // not sure why, but apparently there's an underlying difference between just_audio's move implementation
          // and media_kit, so let's fix it
          request.currentIndex > request.newIndex
              ? request.newIndex
              : request.newIndex + 1,
        )
        .then((_) => ConcatenatingMoveResponse());
  }

  /// Release the resources used by this player.
  Future<void> release() => _releaseFuture ??= _release();

  Future<void> _release() async {
    _logger.info('releasing player resources');
    _advancePlaybackControlEpoch();
    _emitEffectivePlaying(false);
    _released = true;
    _mediaOpened = false;
    _setPosition = null;
    final load = _loadCompleter;
    if (load != null && !load.isCompleted) {
      load.completeError(
        PlatformException(code: 'abort', message: 'Player released'),
      );
    }
    // Stop callbacks before disposing native resources. A duration callback
    // can otherwise enqueue a seek on an already disposed native player.
    for (final StreamSubscription subscription in _streamSubscriptions) {
      await subscription.cancel();
    }
    _streamSubscriptions.clear();
    try {
      await _pendingOpen;
    } catch (_) {
      // The load caller owns open errors; disposal must still finish.
    }
    await _pendingSeek;
    await _player.dispose();
    unawaited(_eventController.close());
    unawaited(_dataController.close());
  }

  /// Converts an [AudioSourceMessage] into a [Media] for playback
  Media _convertAudioSourceIntoMediaKit(AudioSourceMessage audioSource) {
    switch (audioSource) {
      case final UriAudioSourceMessage uriSource:
        return Media(uriSource.uri, httpHeaders: audioSource.headers);

      // removed because it doesn't seem to be actually working.
      // Related media-kit issue: https://github.com/media-kit/media-kit/issues/28
      // case final SilenceAudioSourceMessage silenceSource:
      //   // from https://github.com/bleonard252/just_audio_mpv/blob/main/lib/src/mpv_player.dart#L137
      //   return Media(
      //     'av://lavfi:anullsrc=d=${silenceSource.duration.inMilliseconds}ms',
      //     extras: {'overrideDuration': silenceSource.duration},
      //   );

      case final ClippingAudioSourceMessage clippingSource:
        return Media(
          clippingSource.child.uri,
          start: clippingSource.start,
          end: clippingSource.end,
        );

      default:
        throw UnsupportedError(
          '${audioSource.runtimeType} is currently not supported',
        );
    }
  }
}
