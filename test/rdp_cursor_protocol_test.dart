import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import '../integration_test/cursor_scenario.dart';

void main() {
  testWidgets(
    'real TLS cursor planes, image decode, cache and remote position',
    (tester) async {
      await tester.runAsync(() async {
        final session = RdpSession(
          ConnectionProfile(
            id: 'cursor',
            name: 'Cursor fixture',
            host: '127.0.0.1',
            port: int.parse(Platform.environment['LRDP_CURSOR_PORT']!),
            nla: false,
          ),
        );
        try {
          await exerciseRdpCursor(
            session,
            Platform.environment['LRDP_CURSOR_PIN']!,
          );
        } finally {
          await session.close();
          session.dispose();
        }
      });
    },
    skip: Platform.environment['LRDP_CURSOR_PORT'] == null,
  );
}
