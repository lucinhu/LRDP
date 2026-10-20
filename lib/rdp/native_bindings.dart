import 'dart:ffi';
import 'dart:io';
import 'dart:convert';
import 'package:ffi/ffi.dart';

/// The small, versioned LRDP C ABI is intentionally separate from FreeRDP.
final class NativeSession extends Opaque {}

class NativeBindings {
  NativeBindings() : library = _open() {
    if (abiVersion() != 5) throw StateError('原生协议库版本不匹配，请重新构建 LRDP');
  }
  final DynamicLibrary library;
  static DynamicLibrary _open() {
    final override = Platform.environment['LRDP_NATIVE_LIBRARY'];
    if (override != null) return DynamicLibrary.open(override);
    if (Platform.isWindows) return DynamicLibrary.open('lrdp.dll');
    if (Platform.isIOS || Platform.isMacOS) {
      return DynamicLibrary.open('LRDP.framework/LRDP');
    }
    if (Platform.isLinux) {
      // The texture plugin may have already loaded the bridge by SONAME.
      // Reopening a copied bundle path can create a second library instance,
      // splitting native registries and WinPR process state.
      try {
        return DynamicLibrary.open('liblrdp.so');
      } on ArgumentError {
        // A headless test has no runner RPATH; use its adjacent bundle below.
      }
      final bundled = File(
        '${File(Platform.resolvedExecutable).parent.path}/lib/liblrdp.so',
      );
      if (bundled.existsSync()) return DynamicLibrary.open(bundled.path);
    }
    return DynamicLibrary.open('liblrdp.so');
  }

  late final abiVersion = library
      .lookupFunction<Int32 Function(), int Function()>('lrdp_abi_version');
  late final endReason = library
      .lookupFunction<
        Int32 Function(Pointer<NativeSession>),
        int Function(Pointer<NativeSession>)
      >('lrdp_end_reason');
  late final errorCode = library
      .lookupFunction<
        Uint32 Function(Pointer<NativeSession>),
        int Function(Pointer<NativeSession>)
      >('lrdp_error_code');
  late final version = library
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
        'lrdp_version',
      );
  late final initialize = library
      .lookupFunction<
        Int32 Function(Pointer<Utf8>),
        int Function(Pointer<Utf8>)
      >('lrdp_initialize');

  void prepareDirectory(String path) {
    final value = path.toNativeUtf8();
    try {
      if (initialize(value) != 1) throw StateError('无法初始化应用协议目录');
    } finally {
      calloc.free(value);
    }
  }

  late final create = library
      .lookupFunction<
        Pointer<NativeSession> Function(),
        Pointer<NativeSession> Function()
      >('lrdp_create');
  late final set = library
      .lookupFunction<
        Int32 Function(Pointer<NativeSession>, Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<NativeSession>, Pointer<Utf8>, Pointer<Utf8>)
      >('lrdp_set');
  late final start = library
      .lookupFunction<
        Int32 Function(Pointer<NativeSession>),
        int Function(Pointer<NativeSession>)
      >('lrdp_start');
  late final state = library
      .lookupFunction<
        Int32 Function(Pointer<NativeSession>),
        int Function(Pointer<NativeSession>)
      >('lrdp_state');
  late final features = library
      .lookupFunction<
        Int32 Function(Pointer<NativeSession>),
        int Function(Pointer<NativeSession>)
      >('lrdp_features');
  late final audioActive = library
      .lookupFunction<
        Int32 Function(Pointer<NativeSession>, Int32),
        int Function(Pointer<NativeSession>, int)
      >('lrdp_audio_active');
  late final read = library
      .lookupFunction<
        Int32 Function(Pointer<NativeSession>, Int32, Pointer<Utf8>, Size),
        int Function(Pointer<NativeSession>, int, Pointer<Utf8>, int)
      >('lrdp_read');
  late final frame = library
      .lookupFunction<
        Int32 Function(
          Pointer<NativeSession>,
          Pointer<Uint8>,
          Size,
          Pointer<Int32>,
          Pointer<Int32>,
          Pointer<Uint64>,
        ),
        int Function(
          Pointer<NativeSession>,
          Pointer<Uint8>,
          int,
          Pointer<Int32>,
          Pointer<Int32>,
          Pointer<Uint64>,
        )
      >('lrdp_frame');
  bool get supportsNativeVideo => library.providesSymbol('lrdp_video_ticket');
  late final videoTicket = library
      .lookupFunction<
        Uint64 Function(Pointer<NativeSession>),
        int Function(Pointer<NativeSession>)
      >('lrdp_video_ticket');
  late final cursor = library
      .lookupFunction<
        Int32 Function(
          Pointer<NativeSession>,
          Pointer<Uint8>,
          Size,
          Pointer<Int32>,
          Pointer<Uint64>,
        ),
        int Function(
          Pointer<NativeSession>,
          Pointer<Uint8>,
          int,
          Pointer<Int32>,
          Pointer<Uint64>,
        )
      >('lrdp_cursor');
  late final input = library
      .lookupFunction<
        Int32 Function(Pointer<NativeSession>, Int32, Int32, Int32, Int32),
        int Function(Pointer<NativeSession>, int, int, int, int)
      >('lrdp_input');
  late final clipboard = library
      .lookupFunction<
        Int32 Function(Pointer<NativeSession>, Pointer<Utf8>),
        int Function(Pointer<NativeSession>, Pointer<Utf8>)
      >('lrdp_clipboard');
  late final pasteImage = library
      .lookupFunction<
        Int32 Function(
          Pointer<NativeSession>,
          Pointer<Uint8>,
          Size,
          Pointer<Uint8>,
          Size,
        ),
        int Function(
          Pointer<NativeSession>,
          Pointer<Uint8>,
          int,
          Pointer<Uint8>,
          int,
        )
      >('lrdp_paste_image');
  late final pasteFiles = library
      .lookupFunction<
        Int32 Function(Pointer<NativeSession>, Pointer<Pointer<Utf8>>, Size),
        int Function(Pointer<NativeSession>, Pointer<Pointer<Utf8>>, int)
      >('lrdp_paste_files');
  late final readImage = library
      .lookupFunction<
        Int32 Function(
          Pointer<NativeSession>,
          Pointer<Uint8>,
          Size,
          Pointer<Int32>,
        ),
        int Function(
          Pointer<NativeSession>,
          Pointer<Uint8>,
          int,
          Pointer<Int32>,
        )
      >('lrdp_read_image');
  late final paste = library
      .lookupFunction<
        Int32 Function(Pointer<NativeSession>, Pointer<Utf8>),
        int Function(Pointer<NativeSession>, Pointer<Utf8>)
      >('lrdp_paste');
  late final stop = library
      .lookupFunction<
        Void Function(Pointer<NativeSession>),
        void Function(Pointer<NativeSession>)
      >('lrdp_stop');
  late final destroy = library
      .lookupFunction<
        Void Function(Pointer<NativeSession>),
        void Function(Pointer<NativeSession>)
      >('lrdp_destroy');

  void configure(Pointer<NativeSession> session, String key, String value) {
    if (value.contains('\u0000')) {
      throw FormatException('连接配置包含无效字符：$key');
    }
    final k = key.toNativeUtf8(), v = value.toNativeUtf8();
    try {
      if (set(session, k, v) != 1) throw StateError('不支持的连接配置：$key');
    } finally {
      if (key == 'password') {
        v
            .cast<Uint8>()
            .asTypedList(utf8.encode(value).length + 1)
            .fillRange(0, utf8.encode(value).length + 1, 0);
      }
      calloc.free(k);
      calloc.free(v);
    }
  }
}
