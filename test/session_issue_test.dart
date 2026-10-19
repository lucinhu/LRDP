import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/rdp/session_issue.dart';

void main() {
  test(
    'error classes distinguish logoff from security negotiation and local close',
    () {
      final s = RdpSession(
        const ConnectionProfile(id: 'issue', name: 'Test', host: '192.0.2.1'),
      );
      s.state = SessionState.closed;
      s.endReason = SessionEndReason.remote;
      s.errorCode = 0x1000c;
      expect(SessionIssue.from(s).title, '远程会话已注销');
      s.state = SessionState.failed;
      s.endReason = SessionEndReason.protocol;
      s.errorCode = 0x2000c;
      expect(SessionIssue.from(s).title, '安全连接未建立');
      s.errorCode = 0x20015;
      s.endReason = SessionEndReason.local;
      expect(SessionIssue.from(s).action, SessionAction.reconnect);
      expect(SessionIssue.from(s).title, '连接已结束');
      s.dispose();
    },
  );
  test(
    'authentication, policy and network errors suggest the appropriate action',
    () {
      final s = RdpSession(
        const ConnectionProfile(id: 'issue', name: 'Test', host: '192.0.2.1'),
      );
      s.state = SessionState.failed;
      for (final code in [
        0x20009,
        0x20014,
        0x20015,
        0x20018,
        0x20012,
        0x20019,
        0x2000e,
        0x20013,
        0x20016,
        0x2001a,
        0x1000a,
      ]) {
        s.errorCode = code;
        expect(
          SessionIssue.from(s).action,
          SessionAction.credentials,
          reason: code.toRadixString(16),
        );
      }
      s.errorCode = 0x20018;
      expect(SessionIssue.from(s).title, '账号已锁定');
      s.errorCode = 0x20004;
      expect(SessionIssue.from(s).action, SessionAction.settings);
      s.errorCode = 0;
      s.endReason = SessionEndReason.transport;
      expect(SessionIssue.from(s).action, SessionAction.reconnect);
      s.state = SessionState.certificateRequired;
      s.errorCode = 0x20008;
      expect(SessionIssue.from(s).action, SessionAction.certificate);
      s.dispose();
    },
  );
}
