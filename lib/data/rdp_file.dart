import 'dart:convert';
import 'dart:typed_data';
import '../models/connection_profile.dart';

/// Imports portable fields only; Windows DPAPI password blobs are never read.
class RdpFile {
  static ConnectionProfile decode(Uint8List bytes, {String? name}) {
    if (bytes.length > 1024 * 1024) {
      throw const FormatException('RDP 文件不能大于 1 MiB');
    }
    String text;
    if (bytes.length >= 2 &&
        ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
            (bytes[0] == 0xfe && bytes[1] == 0xff))) {
      if (bytes.length.isOdd) throw const FormatException('UTF-16 文件长度不正确');
      final little = bytes[0] == 0xff;
      final data = ByteData.sublistView(bytes);
      text = String.fromCharCodes(
        List.generate(
          (bytes.length - 2) ~/ 2,
          (i) => data.getUint16(2 + i * 2, little ? Endian.little : Endian.big),
        ),
      );
    } else {
      text = utf8.decode(bytes).replaceFirst('\ufeff', '');
    }
    final values = <String, String>{};
    for (final line in const LineSplitter().convert(text)) {
      final match = RegExp(r'^([^:]+):[isb]:(.*)$').firstMatch(line.trim());
      if (match != null) values[match[1]!.toLowerCase()] = match[2]!;
    }
    final address = values['full address'];
    if (address == null) throw const FormatException('文件缺少 full address');
    final endpoint = Endpoint.parse(address);
    int dimension(String key, int fallback) {
      final n = int.tryParse(values[key] ?? '') ?? fallback;
      if (n < 200 || n > 4096) throw const FormatException('分辨率范围为 200–4096');
      return n;
    }

    return ConnectionProfile(
      id: ConnectionProfile.newId(),
      name: name ?? endpoint.host,
      host: endpoint.host,
      port: endpoint.port,
      username: values['username'] ?? '',
      domain: values['domain'] ?? '',
      width: dimension('desktopwidth', 1280),
      height: dimension('desktopheight', 800),
      automaticResolution:
          values['dynamic resolution'] == '1' ||
          (!values.containsKey('dynamic resolution') &&
              !values.containsKey('desktopwidth') &&
              !values.containsKey('desktopheight')),
      clipboard: values['redirectclipboard'] != '0',
      audio: values['audiomode'] == '0',
      nla: values['enablecredsspsupport'] != '0',
    );
  }

  static String encode(ConnectionProfile p) {
    String clean(String value) => value.replaceAll(RegExp(r'[\r\n]'), '');
    return [
      'full address:s:${p.address}',
      'username:s:${clean(p.username)}',
      'domain:s:${clean(p.domain)}',
      'desktopwidth:i:${p.width}',
      'desktopheight:i:${p.height}',
      'dynamic resolution:i:${p.automaticResolution ? 1 : 0}',
      'session bpp:i:32',
      'redirectclipboard:i:${p.clipboard ? 1 : 0}',
      'audiomode:i:${p.audio ? 0 : 2}',
      'enablecredsspsupport:i:${p.nla ? 1 : 0}',
      'authentication level:i:2',
      '',
    ].join('\r\n');
  }
}
