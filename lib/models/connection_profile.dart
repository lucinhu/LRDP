import 'dart:math';

class Endpoint {
  const Endpoint(this.host, this.port);
  final String host;
  final int port;

  static Endpoint parse(String input) {
    final value = input.trim();
    if (value.isEmpty ||
        value.contains('\u0000') ||
        RegExp(r'[\s/\\@?#]').hasMatch(value)) {
      throw const FormatException('请输入主机名或 IP，例如 192.168.1.10:3389');
    }
    String host = value;
    int port = 3389;
    if (value.startsWith('[')) {
      final match = RegExp(
        r'^\[([0-9a-fA-F:.%]+)\](?::(\d+))?$',
      ).firstMatch(value);
      if (match == null) throw const FormatException('IPv6 地址格式不正确');
      host = match[1]!;
      port = match[2] == null ? 3389 : int.parse(match[2]!);
    } else if (':'.allMatches(value).length == 1) {
      final parts = value.split(':');
      host = parts[0];
      port = int.tryParse(parts[1]) ?? 0;
    } else if (value.contains(':') &&
        !RegExp(r'^[0-9a-fA-F:.%]+$').hasMatch(value)) {
      throw const FormatException('IPv6 地址格式不正确');
    }
    if (host.isEmpty || port < 1 || port > 65535 || host.length > 253) {
      throw const FormatException('主机或端口不正确，端口范围为 1–65535');
    }
    return Endpoint(host, port);
  }

  String get address => '${host.contains(':') ? '[$host]' : host}:$port';
}

class ConnectionProfile {
  const ConnectionProfile({
    required this.id,
    required this.name,
    required this.host,
    this.port = 3389,
    this.username = '',
    this.domain = '',
    this.group = '个人',
    this.favorite = false,
    this.width = 1280,
    this.height = 800,
    this.clipboard = true,
    this.audio = false,
    this.autoReconnect = true,
    this.fileTransfer = false,
    this.sharedDirectory = '',
    this.nla = true,
    this.rememberPassword = false,
    this.lastConnectedAt,
  });

  final String id, name, host, username, domain, group;
  final String sharedDirectory;
  final int port, width, height;
  final bool favorite, clipboard, audio, nla, rememberPassword;
  final bool fileTransfer, autoReconnect;
  final DateTime? lastConnectedAt;
  String get address => Endpoint(host, port).address;

  /// Presentation metadata does not require reconnecting. Every option used by
  /// the worker/recovery controller does; credentials are compared by the owner.
  bool hasSameSessionSettings(ConnectionProfile other) =>
      (
        host,
        port,
        username,
        domain,
        width,
        height,
        clipboard,
        audio,
        autoReconnect,
        fileTransfer,
        sharedDirectory,
        nla,
      ) ==
      (
        other.host,
        other.port,
        other.username,
        other.domain,
        other.width,
        other.height,
        other.clipboard,
        other.audio,
        other.autoReconnect,
        other.fileTransfer,
        other.sharedDirectory,
        other.nla,
      );

  static String newId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  ConnectionProfile copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    String? domain,
    String? group,
    bool? favorite,
    int? width,
    int? height,
    bool? clipboard,
    bool? audio,
    bool? autoReconnect,
    bool? fileTransfer,
    String? sharedDirectory,
    bool? nla,
    bool? rememberPassword,
    DateTime? lastConnectedAt,
  }) => ConnectionProfile(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    username: username ?? this.username,
    domain: domain ?? this.domain,
    group: group ?? this.group,
    favorite: favorite ?? this.favorite,
    width: width ?? this.width,
    height: height ?? this.height,
    clipboard: clipboard ?? this.clipboard,
    audio: audio ?? this.audio,
    autoReconnect: autoReconnect ?? this.autoReconnect,
    fileTransfer: fileTransfer ?? this.fileTransfer,
    sharedDirectory: sharedDirectory ?? this.sharedDirectory,
    nla: nla ?? this.nla,
    rememberPassword: rememberPassword ?? this.rememberPassword,
    lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'domain': domain,
    'group': group,
    'favorite': favorite,
    'width': width,
    'height': height,
    'clipboard': clipboard,
    'audio': audio,
    'autoReconnect': autoReconnect,
    'fileTransfer': fileTransfer,
    'sharedDirectory': sharedDirectory,
    'nla': nla,
    'rememberPassword': rememberPassword,
    'lastConnectedAt': lastConnectedAt?.toIso8601String(),
  };

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) {
    final host = json['host'] as String;
    final port = json['port'] as int? ?? 3389;
    Endpoint.parse(Endpoint(host, port).address);
    final width = json['width'] as int? ?? 1280;
    final height = json['height'] as int? ?? 800;
    if (width < 200 || width > 4096 || height < 200 || height > 4096) {
      throw const FormatException('分辨率范围为 200–4096');
    }
    return ConnectionProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      host: host,
      port: port,
      username: json['username'] as String? ?? '',
      domain: json['domain'] as String? ?? '',
      group: json['group'] as String? ?? '个人',
      favorite: json['favorite'] as bool? ?? false,
      width: width,
      height: height,
      clipboard: json['clipboard'] as bool? ?? true,
      audio: json['audio'] as bool? ?? false,
      autoReconnect: json['autoReconnect'] as bool? ?? true,
      fileTransfer: json['fileTransfer'] as bool? ?? false,
      sharedDirectory: json['sharedDirectory'] as String? ?? '',
      nla: json['nla'] as bool? ?? true,
      rememberPassword: json['rememberPassword'] as bool? ?? false,
      lastConnectedAt: DateTime.tryParse(
        json['lastConnectedAt'] as String? ?? '',
      ),
    );
  }
}
