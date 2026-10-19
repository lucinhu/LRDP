import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/data/rdp_file.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/key_mapping.dart';

void main() {
  test('audio is opt in, persists, imports and requires a new session', () {
    const p = ConnectionProfile(id: 'audio', name: 'Audio', host: '192.0.2.1');
    expect(p.audio, isFalse);
    final on = p.copyWith(audio: true);
    expect(ConnectionProfile.fromJson(on.toJson()).audio, isTrue);
    final legacy = on.toJson()..remove('audio');
    expect(ConnectionProfile.fromJson(legacy).audio, isFalse);
    expect(p.hasSameSessionSettings(on), isFalse);
    expect(on.hasSameSessionSettings(on.copyWith(name: 'Renamed')), isTrue);
    expect(
      RdpFile.decode(Uint8List.fromList(utf8.encode(RdpFile.encode(on)))).audio,
      isTrue,
    );
    expect(
      RdpFile.decode(Uint8List.fromList(utf8.encode(RdpFile.encode(p)))).audio,
      isFalse,
    );
    expect(
      RdpFile.decode(
        Uint8List.fromList(
          utf8.encode('full address:s:host\r\naudiomode:i:1\r\n'),
        ),
      ).audio,
      isFalse,
    );
  });
  test(
    'recovery preference preserves opt out and defaults older profiles on',
    () {
      const p = ConnectionProfile(id: 'retry', name: 'Test', host: '192.0.2.1');
      final disabled = p.copyWith(autoReconnect: false);
      expect(
        ConnectionProfile.fromJson(disabled.toJson()).autoReconnect,
        isFalse,
      );
      final legacy = p.toJson()..remove('autoReconnect');
      expect(ConnectionProfile.fromJson(legacy).autoReconnect, isTrue);
      expect(disabled.copyWith(name: 'Edited').autoReconnect, isFalse);
    },
  );
  test('addresses support DNS, custom ports and bracketed IPv6', () {
    expect(Endpoint.parse(' example.com ').address, 'example.com:3389');
    expect(Endpoint.parse('10.0.0.2:3390').port, 3390);
    expect(Endpoint.parse('[2001:db8::1]:3390').host, '2001:db8::1');
    expect(Endpoint.parse('::1').address, '[::1]:3389');
    for (final bad in [
      '',
      'host:0',
      'host:65536',
      'host:foo',
      'rdp://host',
      'host/path',
      'a\nb',
      'host@user',
      '[broken]:3389',
    ]) {
      expect(() => Endpoint.parse(bad), throwsFormatException, reason: bad);
    }
  });
  test(
    'RDP export/import roundtrip keeps portable settings and excludes secrets',
    () {
      const p = ConnectionProfile(
        id: 'x',
        name: 'Work',
        host: '2001:db8::1',
        port: 3391,
        username: 'alice',
        domain: 'EXAMPLE',
        width: 1920,
        height: 1080,
        clipboard: false,
        nla: true,
        rememberPassword: true,
      );
      final text = RdpFile.encode(p);
      final restored = RdpFile.decode(Uint8List.fromList(utf8.encode(text)));
      expect(restored.host, p.host);
      expect(restored.port, p.port);
      expect(restored.username, p.username);
      expect(restored.width, p.width);
      expect(restored.clipboard, false);
      expect(restored.rememberPassword, false);
      expect(text.toLowerCase(), isNot(contains('password')));
      expect(p.toJson().containsKey('password'), false);
    },
  );
  test('Windows UTF16LE files, colons and DPAPI blobs import safely', () {
    const text =
        'full address:s:host:3390\r\nusername:s:domain:user\r\npassword 51:b:secret\r\ndrivestoredirect:s:*\r\nredirectdrives:i:1\r\n';
    final units = text.codeUnits;
    final bytes = Uint8List(2 + units.length * 2)
      ..[0] = 0xff
      ..[1] = 0xfe;
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < units.length; i++) {
      data.setUint16(2 + i * 2, units[i], Endian.little);
    }
    final p = RdpFile.decode(bytes);
    expect(p.username, 'domain:user');
    expect(p.fileTransfer, false);
    expect(p.sharedDirectory, isEmpty);
    expect(p.port, 3390);
    expect(p.rememberPassword, false);
    expect(
      () => RdpFile.decode(Uint8List.fromList(utf8.encode('username:s:user'))),
      throwsFormatException,
    );
  });
  test('RDP injection via newline is removed on export', () {
    const p = ConnectionProfile(
      id: 'x',
      name: 'x',
      host: 'localhost',
      username: 'user\r\npassword:s:leak',
    );
    expect(
      RdpFile.encode(p).split('\r\n').where((s) => s.startsWith('password:')),
      isEmpty,
    );
  });
  test('keyboard extended scancodes distinguish arrows and keypad', () {
    expect(rdpScancode(PhysicalKeyboardKey.keyA), 0x1e);
    expect(rdpScancode(PhysicalKeyboardKey.arrowLeft), 0x14b);
    expect(rdpScancode(PhysicalKeyboardKey.numpad4), 0x4b);
    expect(rdpScancode(PhysicalKeyboardKey.controlRight), 0x11d);
    expect(rdpScancode(PhysicalKeyboardKey.enter), 0x1c);
  });
}
