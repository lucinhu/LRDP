import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import '../models/connection_profile.dart';
import '../data/transfer_folder.dart';
import 'native_bindings.dart';
import 'rdp_cursor.dart';
import 'native_video.dart';
import 'frame_rate.dart';

enum SessionState {
  idle,
  connecting,
  connected,
  closed,
  failed,
  certificateRequired,
}

enum SessionEndReason {
  none,
  local,
  transport,
  authentication,
  certificate,
  remote,
  protocol,
  configuration,
}

class _WorkerConnection {
  final events = ReceivePort();
  final closed = Completer<void>();
  SendPort? commands;
  bool stopping = false;
  Future<void>? closing;
  void complete() {
    if (!closed.isCompleted) closed.complete();
  }

  Future<void> stop() => closing ??= _stop();
  Future<void> _stop() async {
    stopping = true;
    commands?.send(['stop']);
    // A late command port also receives stop, without killing its native owner.
    await closed.future;
    events.close();
  }
}

class RdpSession extends ChangeNotifier {
  RdpSession(this.profile, {this.protocolDirectory, this.workerLauncher});
  @visibleForTesting
  final Future<void> Function(Map<String, dynamic>)? workerLauncher;
  final ConnectionProfile profile;
  final String? protocolDirectory;
  SessionState state = SessionState.idle;
  SessionEndReason endReason = SessionEndReason.none;
  int errorCode = 0;
  String error = '', fingerprint = '', version = '';
  ui.Image? image;
  NativeVideo? _video;
  int _lastUploads = 0;
  int decodedFrames = 0;
  int get textureFrames => _video?.uploads ?? 0;
  int? get textureId =>
      _video != null && _video!.width > 0 && _video!.height > 0
      ? _video!.id
      : null;
  int get desktopWidth => textureId != null ? _video!.width : image?.width ?? 0;
  int get desktopHeight =>
      textureId != null ? _video!.height : image?.height ?? 0;
  bool get hasVideo => desktopWidth > 0 && desktopHeight > 0;
  RdpCursor cursor = const RdpCursor();
  DateTime? connectedAt;
  int frames = 0;
  int features = 0;
  bool get displayResizeSupported => features & 2 != 0;
  bool get clipboardSupported => features & 1 != 0;
  bool get unicodeInputSupported => features & 8 != 0;
  bool get hasDecodedAvc => features & 4 != 0;
  String? remoteClipboard;
  String? transferDirectory;
  _WorkerConnection? _worker;
  SendPort? get _commands =>
      _worker?.stopping == false ? _worker?.commands : null;
  bool _disposed = false, _decoding = false, _cursorDecoding = false;
  int _epoch = 0;
  bool _visible = true;
  int _frameRate = 60;
  int get targetFrameRate => _frameRate;
  void setFrameRate(int value) {
    value = value.clamp(1, 240);
    if (_frameRate == value) return;
    _frameRate = value;
    _commands?.send(['frameRate', value]);
    if (_video case final video?) unawaited(video.setFrameRate(value));
  }

  bool _audioAllowed = !Platform.isAndroid;
  String audioStatus = 'off';
  void setAudioAllowed(bool allowed) {
    if (_audioAllowed == allowed) return;
    _audioAllowed = allowed;
    _commands?.send(['audio', allowed]);
  }

  final _pastes = <int, Completer<bool>>{};
  int _pasteId = 0;
  String pasteError = '';
  bool get pasteInProgress => _pastes.isNotEmpty;
  void _cancelPastes() {
    if (_pastes.isEmpty) return;
    pasteError = '连接已结束，文字未确认发送';
    for (final pending in _pastes.values) {
      pending.complete(false);
    }
    _pastes.clear();
  }

  void setVisible(bool value) {
    if (_visible == value) return;
    _visible = value;
    _commands?.send(['visible', value]);
    if (_video case final video?) unawaited(video.setVisible(value));
  }

  void _releaseVideo() {
    final old = _video;
    _video = null;
    _lastUploads = 0;
    if (old != null) unawaited(old.dispose());
  }

  Future<void> _attachVideo(int ticket, int epoch) async {
    if (!(Platform.isLinux || Platform.isAndroid || Platform.isWindows) ||
        Platform.environment['LRDP_DISABLE_TEXTURES'] == '1' ||
        const bool.fromEnvironment('LRDP_DISABLE_TEXTURES')) {
      return;
    }
    final video = await NativeVideo.create(
      ticket,
      frameRate: _frameRate,
      changed: (video) {
        if (_disposed || epoch != _epoch || !identical(_video, video)) return;
        frames += (video.uploads - _lastUploads).clamp(0, 1 << 30);
        _lastUploads = video.uploads;
        if (video.uploads > 0) {
          image?.dispose();
          image = null;
        }
        notifyListeners();
      },
      failed: (video) {
        if (_disposed || epoch != _epoch || !identical(_video, video)) return;
        _releaseVideo();
        _commands?.send(['video', false]);
        notifyListeners();
      },
    );
    if (video == null) return;
    if (_disposed || epoch != _epoch || !isActive) {
      await video.dispose();
      return;
    }
    _releaseVideo();
    _video = video;
    await video.setFrameRate(_frameRate);
    if (_disposed || epoch != _epoch || !identical(_video, video)) return;
    _commands?.send(['video', true]);
    await video.setVisible(_visible);
    if (!_disposed && epoch == _epoch) notifyListeners();
  }

  bool get isActive =>
      state == SessionState.connecting || state == SessionState.connected;

  Future<void> connect({
    required String password,
    String acceptedFingerprint = '',
  }) async {
    final epoch = ++_epoch;
    _releaseVideo();
    _cancelPastes();
    await _stopWorker();
    if (_disposed || epoch != _epoch) return;
    image?.dispose();
    image = null;
    cursor.image?.dispose();
    cursor.inversion?.dispose();
    cursor = const RdpCursor();
    remoteClipboard = null;
    connectedAt = null;
    state = SessionState.connecting;
    endReason = SessionEndReason.none;
    errorCode = features = 0;
    error = fingerprint = '';
    notifyListeners();
    if (_disposed || epoch != _epoch) return;
    final worker = _WorkerConnection();
    _worker = worker;
    worker.events.listen((dynamic event) {
      // Completion and late port delivery must survive cancellation/generation
      // changes, otherwise close() would wait forever for a discarded event.
      if (event is SendPort) {
        worker.commands = event;
        if (worker.stopping || _disposed || epoch != _epoch) {
          event.send(['stop']);
        } else {
          event.send(['visible', _visible]);
          event.send(['frameRate', _frameRate]);
          event.send(['audio', _audioAllowed]);
        }
        return;
      }
      if (event == null ||
          event is List ||
          (event is Map && event['type'] == 'done')) {
        worker.complete();
      }
      if (_disposed || epoch != _epoch) return;
      if (event is Map) {
        switch (event['type']) {
          case 'transfer':
            transferDirectory = event['path'] as String;
            notifyListeners();
          case 'state':
            state = SessionState.values[event['state'] as int];
            endReason =
                SessionEndReason.values[event['reason'] as int? ??
                    SessionEndReason.protocol.index];
            errorCode = event['code'] as int? ?? 0;
            error = event['error'] as String;
            fingerprint = event['fingerprint'] as String;
            version = event['version'] as String;
            if (!isActive) {
              _releaseVideo();
              _cancelPastes();
            }
            if (state == SessionState.connected) connectedAt = DateTime.now();
            notifyListeners();
          case 'cursor':
            _decodeCursor(event, epoch);
          case 'frame':
            _decode(event, epoch);
          case 'video':
            unawaited(_attachVideo(event['ticket'] as int, epoch));
          case 'clipboard':
            remoteClipboard = event['text'] as String;
            notifyListeners();
          case 'features':
            features = event['value'] as int;
            notifyListeners();
          case 'audioStatus':
            audioStatus = event['value'] as String;
            notifyListeners();
          case 'pasteResult':
            final pending = _pastes.remove(event['id'] as int);
            if (pending != null) {
              final ok = event['ok'] as bool;
              pasteError = ok ? '' : event['message'] as String;
              pending.complete(ok);
              notifyListeners();
            }
          case 'done':
            _releaseVideo();
            _cancelPastes();
        }
      } else if (event is List || (event == null && isActive)) {
        _releaseVideo();
        _cancelPastes();
        state = SessionState.failed;
        endReason = SessionEndReason.protocol;
        error = event is List ? '会话工作线程异常：${event.first}' : '会话工作线程意外退出';
        notifyListeners();
      }
    });
    final init = <String, dynamic>{
      'events': worker.events.sendPort,
      'profile': profile.toJson(),
      'directory': protocolDirectory,
      'password': password,
      'fingerprint': acceptedFingerprint,
      'visible': _visible,
      'audioAllowed': _audioAllowed,
    };
    try {
      if (workerLauncher case final launch?) {
        await launch(init);
      } else {
        await Isolate.spawn(
          _sessionWorker,
          init,
          onError: worker.events.sendPort,
          onExit: worker.events.sendPort,
        );
      }
    } catch (e) {
      worker.complete();
      if (!_disposed && epoch == _epoch) {
        state = SessionState.failed;
        endReason = SessionEndReason.configuration;
        error = '无法创建会话：$e';
        notifyListeners();
      }
    } finally {
      init.remove('password');
    }
  }

  Future<void> _decode(Map<dynamic, dynamic> event, int epoch) async {
    if (_video != null) {
      _commands?.send(['ack']);
      return;
    }
    if (_decoding) {
      _commands?.send(['ack', false]);
      return;
    }
    _decoding = true;
    final bytes = (event['pixels'] as TransferableTypedData)
        .materialize()
        .asUint8List();
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: event['width'] as int,
        height: event['height'] as int,
        pixelFormat: ui.PixelFormat.bgra8888,
      );
      try {
        final codec = await descriptor.instantiateCodec();
        try {
          final frame = await codec.getNextFrame();
          if (_disposed || epoch != _epoch || _video != null) {
            frame.image.dispose();
            return;
          }
          final old = image;
          image = frame.image;
          frames++;
          decodedFrames++;
          notifyListeners();
          old?.dispose();
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
        buffer.dispose();
      }
    } catch (e) {
      if (!_disposed && epoch == _epoch) {
        error = '画面解码失败：$e';
        notifyListeners();
      }
    } finally {
      _decoding = false;
      if (epoch == _epoch) _commands?.send(['ack']);
    }
  }

  Future<ui.Image> _cursorImage(Uint8List bytes, int width, int height) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.bgra8888,
    );
    try {
      final codec = await descriptor.instantiateCodec();
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }

  Future<void> _decodeCursor(Map<dynamic, dynamic> event, int epoch) async {
    if (_cursorDecoding) {
      _commands?.send(['cursorAck', false]);
      return;
    }
    _cursorDecoding = true;
    ui.Image? normal, inversion;
    bool created = false;
    try {
      final info = (event['info'] as List).cast<int>();
      final kind = RdpCursorKind.values[info[0]];
      final pixels = event['pixels'] as TransferableTypedData?;
      if (kind == RdpCursorKind.bitmap) {
        if (pixels == null) {
          normal = cursor.image;
          inversion = cursor.inversion;
        } else {
          final bytes = pixels.materialize().asUint8List();
          final plane = info[1] * info[2] * 4;
          created = true;
          normal = await _cursorImage(
            Uint8List.sublistView(bytes, 0, plane),
            info[1],
            info[2],
          );
          bool inverted = false;
          for (var i = plane + 3; i < bytes.length; i += 4) {
            if (bytes[i] != 0) {
              inverted = true;
              break;
            }
          }
          if (inverted) {
            inversion = await _cursorImage(
              Uint8List.sublistView(bytes, plane),
              info[1],
              info[2],
            );
          }
        }
      }
      if (_disposed || epoch != _epoch) return;
      final old = cursor;
      cursor = RdpCursor(
        kind: kind,
        image: normal,
        inversion: inversion,
        hotX: info[3],
        hotY: info[4],
        x: info[5],
        y: info[6],
        positionSerial: info[7],
      );
      created = false;
      notifyListeners();
      if (!identical(old.image, normal)) old.image?.dispose();
      if (!identical(old.inversion, inversion)) old.inversion?.dispose();
    } catch (e) {
      if (!_disposed && epoch == _epoch) {
        error = '光标解码失败：$e';
        notifyListeners();
      }
    } finally {
      if (created) {
        normal?.dispose();
        inversion?.dispose();
      }
      _cursorDecoding = false;
      if (epoch == _epoch) _commands?.send(['cursorAck']);
    }
  }

  void input(int type, int a, [int b = 0, int c = 0]) =>
      _commands?.send(['input', type, a, b, c]);
  void mouse(int flags, int x, int y) => input(0, flags, x, y);
  void scan(int code, bool down) =>
      input(1, (down ? 0 : 0x8000) | (code > 0xff ? 0x0100 : 0), code & 0xff);
  void text(String text) {
    if (text.codeUnits.length > 16384) {
      throw const FormatException('每次最多发送 16384 个字符');
    }
    _commands?.send(['text', text]);
  }

  void clipboard(String text) => _commands?.send(['clipboard', text]);
  Future<bool> paste(String text) {
    if (state != SessionState.connected ||
        !clipboardSupported ||
        _commands == null) {
      pasteError = '远程剪贴板暂不可用，文字已保留';
      return Future.value(false);
    }
    if (text.isEmpty ||
        text.codeUnits.length > 16384 ||
        text.contains('\u0000')) {
      pasteError = '请发送不含空字符且不超过 16384 个字符的文字';
      return Future.value(false);
    }
    if (pasteInProgress) {
      pasteError = '上一段文字仍在发送，请稍候';
      return Future.value(false);
    }
    final id = ++_pasteId;
    final result = Completer<bool>();
    _pastes[id] = result;
    pasteError = '';
    _commands!.send(['paste', id, text]);
    notifyListeners();
    return result.future;
  }

  void resize(int width, int height) =>
      input(3, width.clamp(200, 4096), height.clamp(200, 4096));
  void chord(List<int> keys) {
    for (final key in keys) {
      scan(key, true);
    }
    for (final key in keys.reversed) {
      scan(key, false);
    }
  }

  Future<void> close() {
    ++_epoch;
    _releaseVideo();
    _cancelPastes();
    endReason = SessionEndReason.local;
    state = SessionState.closed;
    if (!_disposed) notifyListeners();
    return _stopWorker();
  }

  Future<void> _stopWorker() async {
    final worker = _worker;
    if (worker == null) return;
    await worker.stop();
    if (identical(_worker, worker)) _worker = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // The listener stays alive until the owning worker has freed native state.
    unawaited(close());
    image?.dispose();
    image = null;
    cursor.image?.dispose();
    cursor.inversion?.dispose();
    cursor = const RdpCursor();
    super.dispose();
  }
}

void _sessionWorker(Map<String, dynamic> init) {
  final events = init['events'] as SendPort;
  final commands = ReceivePort();
  events.send(commands.sendPort);
  NativeBindings? api;
  Directory? scratchDirectory;
  Pointer<NativeSession> session = nullptr;
  Pointer<Uint8> pixels = nullptr;
  int capacity = 0;
  final width = calloc<Int32>(),
      height = calloc<Int32>(),
      generation = calloc<Uint64>();
  final cursorPixels = calloc<Uint8>(384 * 384 * 8);
  final cursorInfo = calloc<Int32>(9), cursorGeneration = calloc<Uint64>();
  var cursorInFlight = false, previousCursorShape = -1;
  final textBuffer = calloc<Uint8>(1024 * 1024 + 1).cast<Utf8>();
  Timer? timer;
  bool inFlight = false, finished = false, nativeVideo = false;
  var visible = init['visible'] as bool? ?? true;
  var frameRate = 60;
  final pacingClock = Stopwatch()..start();
  var nextPoll = 0;
  void Function(Timer)? tick;
  void schedulePolling() {
    timer?.cancel();
    nextPoll = 0;
    if (finished || tick == null) return;
    timer = Timer.periodic(
      visible
          ? FrameRatePolicy.interval(frameRate)
          : const Duration(milliseconds: 33),
      tick,
    );
  }

  var audioAllowed = init['audioAllowed'] as bool? ?? !Platform.isAndroid;
  var previousAudioStatus = '';
  int? pasteRequest;
  final unicode = Queue<(int, int)>();
  int previousState = -1, previousFeatures = -1;
  void finish() {
    if (finished) return;
    finished = true;
    if (pasteRequest case final id?) {
      events.send({
        'type': 'pasteResult',
        'id': id,
        'ok': false,
        'message': '连接已结束，文字未确认发送',
      });
      pasteRequest = null;
    }
    timer?.cancel();
    commands.close();
    if (session != nullptr) api?.destroy(session);
    try {
      scratchDirectory?.deleteSync(recursive: true);
    } on FileSystemException {
      /* OS cache cleanup can retry later. */
    }
    calloc.free(pixels);
    calloc.free(width);
    calloc.free(height);
    calloc.free(generation);
    calloc.free(textBuffer);
    calloc.free(cursorPixels);
    calloc.free(cursorInfo);
    calloc.free(cursorGeneration);
    events.send({'type': 'done'});
  }

  String read(int field) {
    final n = api!.read(session, field, textBuffer, 1024 * 1024 + 1);
    return n >= 0 ? textBuffer.toDartString(length: n) : '';
  }

  void guarded(void Function() action) {
    try {
      action();
    } catch (error) {
      events.send({
        'type': 'state',
        'state': SessionState.failed.index,
        'error': '会话处理失败：$error',
        'fingerprint': '',
        'version': '',
      });
      finish();
    }
  }

  try {
    api = NativeBindings();
    final configuredDirectory = init['directory'] as String?;
    final Directory directory;
    if (configuredDirectory == null) {
      scratchDirectory = Directory.systemTemp.createTempSync('lrdp-protocol-');
      directory = scratchDirectory;
    } else {
      directory = Directory(configuredDirectory)..createSync(recursive: true);
    }
    api.prepareDirectory(directory.path);
    session = api.create();
    if (session == nullptr) throw StateError('无法初始化 FreeRDP');
    final profile = ConnectionProfile.fromJson(
      init['profile'] as Map<String, dynamic>,
    );
    String drivePath = '';
    if (profile.fileTransfer) {
      final transfer = Directory(
        TransferFolder.pathFor(directory.path, profile),
      );
      if (profile.sharedDirectory.isNotEmpty &&
          !Platform.isAndroid &&
          !Platform.isIOS) {
        if (!transfer.existsSync()) throw StateError('共享目录已不存在，请重新选择');
      } else {
        transfer.createSync(recursive: true);
      }
      drivePath = transfer.resolveSymbolicLinksSync();
      events.send({'type': 'transfer', 'path': drivePath});
    }
    final config = {
      'host': profile.host,
      'port': '${profile.port}',
      'username': profile.username,
      'domain': profile.domain,
      'password': init.remove('password') as String,
      'width': '${profile.width}',
      'height': '${profile.height}',
      'clipboard': profile.clipboard ? '1' : '0',
      'audio': profile.audio ? '1' : '0',
      'nla': profile.nla ? '1' : '0',
      'fingerprint': init['fingerprint'] as String,
      'config_path': directory.path,
      'drive_path': drivePath,
    };
    for (final entry in config.entries) {
      api.configure(session, entry.key, entry.value);
    }
    config.clear();
    api.audioActive(session, visible && audioAllowed ? 1 : 0);
    if (api.start(session) != 1) throw StateError('无法启动 RDP 连接');
    if ((Platform.isLinux || Platform.isAndroid || Platform.isWindows) &&
        api.supportsNativeVideo) {
      events.send({'type': 'video', 'ticket': api.videoTicket(session)});
    }
    commands.listen(
      (dynamic msg) => guarded(() {
        if (finished || msg is! List) return;
        switch (msg[0]) {
          case 'stop':
            api!.stop(session);
            finish();
          case 'cursorAck':
            cursorInFlight = false;
            if (msg.length > 1 && msg[1] == false) {
              cursorGeneration.value = 0;
              previousCursorShape = -1;
            }
          case 'ack':
            inFlight = false;
            if (msg.length > 1 && msg[1] == false) generation.value = 0;
          case 'input':
            if (api!.input(
                      session,
                      msg[1] as int,
                      msg[2] as int,
                      msg[3] as int,
                      msg[4] as int,
                    ) ==
                    0 &&
                api.state(session) == SessionState.connected.index) {
              api.stop(session);
              events.send({
                'type': 'state',
                'state': SessionState.failed.index,
                'error': '输入队列已满，为避免按键卡住，请重新连接。',
                'fingerprint': '',
                'version': '',
              });
              finish();
            }
          case 'text':
            final value = msg[1] as String;
            if (value.length <= 16384 && unicode.length <= 32768) {
              for (final unit in value.codeUnits) {
                unicode.add((0, unit));
                unicode.add((0x8000, unit));
              }
            }
          case 'visible':
            final value = msg[1] as bool;
            if (visible != value) {
              visible = value;
              schedulePolling();
            }
            api!.audioActive(session, visible && audioAllowed ? 1 : 0);
          case 'frameRate':
            final value = (msg[1] as int).clamp(1, 240);
            if (value != frameRate) {
              frameRate = value;
              schedulePolling();
            }
          case 'video':
            nativeVideo = msg[1] as bool;
            if (nativeVideo && pixels != nullptr) {
              calloc.free(pixels);
              pixels = nullptr;
              capacity = 0;
            }
            if (!nativeVideo) generation.value = 0;
          case 'audio':
            audioAllowed = msg[1] as bool;
            api!.audioActive(session, visible && audioAllowed ? 1 : 0);
          case 'clipboard':
            final value = (msg[1] as String).toNativeUtf8();
            try {
              api!.clipboard(session, value);
            } finally {
              calloc.free(value);
            }
          case 'paste':
            final id = msg[1] as int;
            final value = (msg[2] as String).toNativeUtf8();
            try {
              if (pasteRequest == null && api!.paste(session, value) == 1) {
                pasteRequest = id;
              } else {
                events.send({
                  'type': 'pasteResult',
                  'id': id,
                  'ok': false,
                  'message': '远程剪贴板暂不可用，文字已保留',
                });
              }
            } finally {
              calloc.free(value);
            }
        }
      }),
    );
    tick = (_) => guarded(() {
      if (finished) return;
      // Dart timers may round 8.333 ms down to 8 ms. Keep a monotonic
      // deadline so 120 Hz does not become 125 Hz, and never queue catch-up
      // decodes after a slow frame or a foreground transition.
      if (visible) {
        final now = pacingClock.elapsedMicroseconds;
        if (now < nextPoll) return;
        final interval = FrameRatePolicy.interval(frameRate).inMicroseconds;
        if (nextPoll == 0 || now - nextPoll > interval) nextPoll = now;
        nextPoll += interval;
      }
      final state = api!.state(session);
      final audioStatus = read(4);
      if (audioStatus != previousAudioStatus) {
        previousAudioStatus = audioStatus;
        events.send({'type': 'audioStatus', 'value': audioStatus});
      }
      if (pasteRequest case final id?) {
        final status = read(3);
        if (status != 'pending') {
          pasteRequest = null;
          events.send({
            'type': 'pasteResult',
            'id': id,
            'ok': status == 'sent',
            'message': status == 'timeout'
                ? '远程端未及时确认粘贴，文字已保留。请检查远程输入框后再试'
                : '远程端未接受粘贴，文字已保留',
          });
        }
      }
      if (state != previousState) {
        previousState = state;
        events.send({
          'type': 'state',
          'state': state,
          'reason': api.endReason(session),
          'code': api.errorCode(session),
          'error': read(0),
          'fingerprint': read(1),
          'version': api.version().toDartString(),
        });
      }
      if (state >= SessionState.closed.index) {
        finish();
        return;
      }
      if (state != SessionState.connected.index) return;
      final features = api.features(session);
      if (features != previousFeatures) {
        previousFeatures = features;
        events.send({'type': 'features', 'value': features});
      }
      final clipboardSize = api.read(session, 2, textBuffer, 1024 * 1024 + 1);
      if (clipboardSize >= 0) {
        events.send({
          'type': 'clipboard',
          'text': textBuffer.toDartString(length: clipboardSize),
        });
      }
      for (var i = 0; i < 128 && unicode.isNotEmpty; i++) {
        final key = unicode.first;
        if (api.input(session, 2, key.$1, key.$2, 0) == 0) break;
        unicode.removeFirst();
      }
      if (!visible) return;
      if (!cursorInFlight) {
        final bytes = api.cursor(
          session,
          cursorPixels,
          384 * 384 * 8,
          cursorInfo,
          cursorGeneration,
        );
        if (bytes < 0) throw StateError('服务器光标超过支持范围');
        if (bytes > 0) {
          cursorInFlight = true;
          final shapeChanged = previousCursorShape != cursorInfo[8];
          events.send({
            'type': 'cursor',
            'info': cursorInfo.asTypedList(9).toList(),
            'pixels': cursorInfo[0] == 2 && shapeChanged
                ? TransferableTypedData.fromList([
                    cursorPixels.asTypedList(bytes),
                  ])
                : null,
          });
          previousCursorShape = cursorInfo[8];
        }
      }
      if (nativeVideo || inFlight) return;
      var size = api.frame(
        session,
        pixels,
        capacity,
        width,
        height,
        generation,
      );
      if (size < 0) {
        calloc.free(pixels);
        capacity = -size;
        pixels = calloc<Uint8>(capacity);
        size = api.frame(session, pixels, capacity, width, height, generation);
      }
      if (size > 0) {
        inFlight = true;
        events.send({
          'type': 'frame',
          'pixels': TransferableTypedData.fromList([pixels.asTypedList(size)]),
          'width': width.value,
          'height': height.value,
        });
      }
    });
    schedulePolling();
  } catch (e) {
    events.send({
      'type': 'state',
      'state': SessionState.failed.index,
      'reason': SessionEndReason.configuration.index,
      'error': 'RDP 引擎启动失败：$e',
      'fingerprint': '',
      'version': '',
    });
    finish();
  }
}
