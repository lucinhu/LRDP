import 'rdp_session.dart';

enum SessionAction { reconnect, credentials, settings, certificate }

/// User-facing outcomes for the pinned FreeRDP error classes. Numeric class
/// matching matters: ErrorInfo 0x0001000c is logoff, Connect 0x0002000c is TLS/NLA.
class SessionIssue {
  const SessionIssue(
    this.title,
    this.message, [
    this.action = SessionAction.reconnect,
  ]);
  final String title, message;
  final SessionAction action;
  String get actionLabel => switch (action) {
    SessionAction.credentials => '重新登录',
    SessionAction.settings => '检查连接设置',
    SessionAction.certificate => '核对证书指纹',
    SessionAction.reconnect => '重新连接',
  };
  factory SessionIssue.from(RdpSession session) {
    if (session.endReason == SessionEndReason.local) {
      return const SessionIssue('连接已结束', '已断开与远程电脑的连接。');
    }
    if (session.state == SessionState.certificateRequired) {
      return const SessionIssue(
        '等待确认远程电脑身份',
        '请通过可信渠道核对服务器的 SHA-256 指纹后再连接。',
        SessionAction.certificate,
      );
    }
    final code = session.errorCode;
    const auth = SessionAction.credentials;
    final known = switch (code) {
      0x00020004 || 0x00020005 => const SessionIssue(
        '找不到远程电脑',
        '请检查电脑地址、DNS 和当前网络，确认主机名没有输入错误。',
        SessionAction.settings,
      ),
      0x00020006 => const SessionIssue(
        '无法连接远程电脑',
        '请确认远程电脑已开机、已启用远程桌面，地址和端口可以访问。',
        SessionAction.settings,
      ),
      0x00020008 || 0x0002000c || 0x0002001e => const SessionIssue(
        '安全连接未建立',
        '请检查服务器的 TLS、证书及 NLA 配置，确认客户端与服务器支持相同的安全方式。',
        SessionAction.settings,
      ),
      0x00020009 ||
      0x00020014 ||
      0x00020015 => const SessionIssue('登录未成功', '用户名、域或密码未通过验证，请检查登录信息。', auth),
      0x00020018 => const SessionIssue(
        '账号已锁定',
        '请等待账号解锁或联系管理员，也可以使用其他账号登录。',
        auth,
      ),
      0x00020012 => const SessionIssue('账号已停用', '请联系管理员启用账号，或使用其他账号登录。', auth),
      0x00020019 => const SessionIssue(
        '账号已过期',
        '请联系管理员更新账号有效期，或使用其他账号登录。',
        auth,
      ),
      0x0002000e || 0x0002000f || 0x00020013 => const SessionIssue(
        '需要更新远程密码',
        '请先在远程系统或组织提供的入口更新密码，再用新密码登录。',
        auth,
      ),
      0x0002000a ||
      0x00020016 ||
      0x00020017 ||
      0x0002001a => const SessionIssue(
        '账号无法使用远程桌面',
        '该账号可能没有远程登录权限，或受到服务器策略限制。请联系管理员或换用其他账号。',
        auth,
      ),
      0x0002001b || 0x0001000a => const SessionIssue(
        '需要提供登录信息',
        '服务器需要新的登录凭据，请重新输入用户名、域和密码。',
        auth,
      ),
      0x00020011 => const SessionIssue(
        '无法联系域认证服务',
        '请确认远程电脑可以访问组织的域认证服务，或使用该电脑的本地账号。',
        auth,
      ),
      0x00010002 ||
      0x0001000c => const SessionIssue('远程会话已注销', '远程系统已结束此会话。需要继续工作时，请重新连接。'),
      0x00010003 => const SessionIssue('会话空闲时间已到', '服务器因长时间没有操作而结束会话，可以重新连接。'),
      0x00010004 => const SessionIssue('远程登录超时', '服务器等待登录的时间已到，请重新连接。'),
      0x00010005 => const SessionIssue(
        '会话被另一连接接管',
        '此账号已从其他客户端登录，当前连接已被服务器结束。',
      ),
      0x00010007 || 0x00010009 => const SessionIssue(
        '服务器拒绝此连接',
        '请确认该账号有远程登录权限，并检查服务器的连接策略。',
        auth,
      ),
      _ => null,
    };
    if (known != null) return known;
    return switch (session.endReason) {
      SessionEndReason.authentication => const SessionIssue(
        '登录未成功',
        '服务器未接受此登录信息。请重新输入或联系管理员。',
        auth,
      ),
      SessionEndReason.transport => const SessionIssue(
        '网络连接中断',
        '请检查网络及远程电脑的连接状态。',
      ),
      SessionEndReason.remote => const SessionIssue(
        '远程电脑已结束连接',
        '服务器主动结束了此会话。可以检查原因后重新连接。',
      ),
      SessionEndReason.configuration => const SessionIssue(
        '连接组件不可用',
        '请检查应用安装及连接配置，再尝试连接。',
        SessionAction.settings,
      ),
      SessionEndReason.certificate => const SessionIssue(
        '等待确认远程电脑身份',
        '请核对服务器证书指纹。',
        SessionAction.certificate,
      ),
      _ => const SessionIssue(
        '连接未能完成',
        '无法继续此连接。请检查连接配置，或查看技术详情。',
        SessionAction.settings,
      ),
    };
  }
}
