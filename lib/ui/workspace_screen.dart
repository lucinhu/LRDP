import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/profile_store.dart';
import '../data/rdp_file.dart';
import '../data/transfer_folder.dart';
import '../models/connection_profile.dart';
import '../rdp/rdp_session.dart';
import '../rdp/session_audio_focus.dart';
import '../rdp/session_issue.dart';
import '../rdp/session_recovery.dart';
import 'profile_editor.dart';
import 'remote_view.dart';
import 'remote_view_memory.dart';
import 'theme.dart';
import 'transfer_dialog.dart';
import 'adaptive.dart';
import 'certificate_dialog.dart';
import 'login_dialog.dart';

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({
    super.key,
    required this.store,
    this.protocolDirectory,
    this.sessionFactory,
  });
  @visibleForTesting
  final RdpSession Function(ConnectionProfile, String?)? sessionFactory;
  final ProfileStore store;
  final String? protocolDirectory;
  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with WidgetsBindingObserver {
  final _search = TextEditingController(), _quick = TextEditingController();
  final _sessions = <String, RdpSession>{};
  final _viewMemories = <String, RemoteViewMemory>{};
  final _audioFocus = SessionAudioFocus();
  final _requestedProfiles = <String, ConnectionProfile>{};
  final _recoveries = <String, SessionRecovery>{};
  final _credentials = <String, ({String password, String fingerprint})>{};
  final _certificateDialogs = <String>{},
      _certificateOffered = <String>{},
      _recorded = <String>{};
  final _lastStates = <String, SessionState>{};
  final _opening = <String>{};
  final _deleting = <String>{};
  String _section = '全部连接';
  String get _sectionTitle =>
      _section.startsWith('group:') ? _section.substring(6) : _section;
  String? _active;
  String? _phoneGroup;
  bool _list = true, _fullscreen = false;
  ProfileStore get store => widget.store;

  AppLifecycleState? _lifecycle;
  bool _mobile = false;
  bool get _foreground =>
      !_mobile || _lifecycle == null || _lifecycle == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _mobile = {
      TargetPlatform.android,
      TargetPlatform.iOS,
    }.contains(Theme.of(context).platform);
    _updateAvailability();
  }

  void _updateAvailability() {
    for (final entry in _sessions.entries) {
      entry.value.setVisible(_foreground && entry.key == _active);
      _recoveries[entry.key]?.setForeground(_foreground);
    }
    _audioFocus.select(_sessions[_active], foreground: _foreground);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _updateAvailability();
    if (_foreground) _showNextCertificate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _audioFocus.dispose();
    _search.dispose();
    _quick.dispose();
    for (final recovery in _recoveries.values) {
      recovery.dispose();
    }
    // close() publishes its terminal state synchronously. Detach the manager
    // before teardown so it cannot rebuild an element that is being unmounted.
    final sessions = _sessions.values.toList();
    _sessions.clear();
    _viewMemories.clear();
    for (final s in sessions) {
      unawaited(s.close().then((_) => s.dispose()));
    }
    _credentials.clear();
    _requestedProfiles.clear();
    super.dispose();
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _edit({
    ConnectionProfile? profile,
    String? address,
    bool repairCredentials = false,
    String? notice,
  }) async {
    String password = '';
    try {
      if (profile != null && !repairCredentials) {
        password = await store.password(profile);
      }
    } catch (_) {
      _message('系统安全存储不可用，请重新输入密码');
    }
    if (!mounted) return;
    final result = await editProfile(
      context,
      profile: profile,
      password: password,
      address: address,
      focusPassword: repairCredentials,
      notice: notice,
    );
    if (result == null || !mounted) return;
    try {
      await store.save(result.profile, password: result.password);
      if (result.connect) {
        await _connect(result.profile, password: result.password);
      }
    } catch (e) {
      _message('保存失败：$e');
    }
  }

  Future<void> _connect(ConnectionProfile p, {String? password}) async {
    if (_deleting.contains(p.id) || !_opening.add(p.id)) return;
    try {
      await _openConnection(p, password: password);
    } finally {
      _opening.remove(p.id);
    }
  }

  Future<void> _openConnection(ConnectionProfile p, {String? password}) async {
    final requested = p;
    final existing = _sessions[p.id];
    final baseline = _requestedProfiles[p.id] ?? existing?.profile;
    final credentials = _credentials[p.id];
    if (existing != null &&
        existing.isActive &&
        (password == null
            ? (baseline?.hasSameSessionSettings(p) ?? false)
            : existing.profile.hasSameSessionSettings(p) &&
                  password == credentials?.password)) {
      if (password != null) _requestedProfiles[p.id] = requested;
      setState(() => _active = p.id);
      return;
    }
    String fingerprint = existing?.profile.address == p.address
        ? credentials?.fingerprint ?? ''
        : '';
    if (password == null &&
        existing != null &&
        baseline?.address == p.address &&
        baseline?.username == p.username &&
        baseline?.domain == p.domain) {
      p = p.copyWith(
        username: existing.profile.username,
        domain: existing.profile.domain,
      );
      password = credentials?.password;
    }
    try {
      password ??= await store.password(requested);
      if (fingerprint.isEmpty) fingerprint = await store.fingerprint(requested);
    } catch (_) {
      password ??= '';
      _message('安全存储暂不可用，本次可使用临时凭据');
    }
    if (!mounted ||
        _deleting.contains(p.id) ||
        (existing != null && _sessions[p.id] != existing)) {
      return;
    }
    if (password.isEmpty || p.username.isEmpty) {
      final login = await _login(p, password);
      if (login == null || !mounted || _deleting.contains(p.id)) return;
      p = p.copyWith(username: login.username, domain: login.domain);
      password = login.password;
    }
    await _launchSession(
      p,
      requested: requested,
      password: password,
      fingerprint: fingerprint,
      previous: existing,
    );
  }

  Future<void> _launchSession(
    ConnectionProfile p, {
    required ConnectionProfile requested,
    required String password,
    required String fingerprint,
    RdpSession? previous,
  }) async {
    if (!mounted ||
        _deleting.contains(p.id) ||
        (previous != null && _sessions[p.id] != previous)) {
      return;
    }
    if (previous != null) {
      _recoveries.remove(p.id)?.dispose();
      await previous.close();
      previous.dispose();
    }
    if (!mounted ||
        _deleting.contains(p.id) ||
        (previous != null && _sessions[p.id] != previous)) {
      return;
    }
    final session =
        widget.sessionFactory?.call(p, widget.protocolDirectory) ??
        RdpSession(p, protocolDirectory: widget.protocolDirectory);
    session.setVisible(_foreground);
    _sessions[p.id] = session;
    _viewMemories[p.id] = RemoteViewMemory();
    _requestedProfiles[p.id] = requested;
    _recoveries[p.id] = SessionRecovery(
      session,
      reconnect: () => _retry(session, automatic: true),
    )..setForeground(_foreground);
    _credentials[p.id] = (password: password, fingerprint: fingerprint);
    session.addListener(() => _sessionChanged(session));
    setState(() {
      _active = p.id;
      _recorded.remove(p.id);
    });
    await session.connect(password: password, acceptedFingerprint: fingerprint);
  }

  Future<LoginDetails?> _login(
    ConnectionProfile p,
    String password, {
    String? issue,
  }) => showDialog<LoginDetails>(
    context: context,
    builder: (_) => LoginDialog(profile: p, password: password, issue: issue),
  );

  Future<void> _repairLogin(RdpSession session) async {
    final id = session.profile.id;
    if (!_opening.add(id)) return;
    try {
      final issue = SessionIssue.from(session);
      final login = await _login(session.profile, '', issue: issue.message);
      if (login == null ||
          !mounted ||
          _deleting.contains(id) ||
          _sessions[id] != session) {
        return;
      }
      final pin = _credentials[id]?.fingerprint ?? '';
      await _launchSession(
        session.profile.copyWith(
          username: login.username,
          domain: login.domain,
        ),
        requested: _requestedProfiles[id] ?? session.profile,
        password: login.password,
        fingerprint: pin,
        previous: session,
      );
    } finally {
      _opening.remove(id);
    }
  }

  Future<void> _configureSession(RdpSession session) async {
    if (_sessions[session.profile.id] != session) return;
    final current =
        store.profiles.where((p) => p.id == session.profile.id).firstOrNull ??
        session.profile;
    final issue = SessionIssue.from(session);
    await _edit(
      profile: current,
      repairCredentials: issue.action == SessionAction.credentials,
      notice: issue.message,
    );
  }

  void _sessionChanged(RdpSession session) {
    if (!mounted || _sessions[session.profile.id] != session) return;
    _audioFocus.select(_sessions[_active], foreground: _foreground);
    if (session.state == SessionState.connected &&
        _recorded.add(session.profile.id)) {
      final current = store.profiles
          .where((p) => p.id == session.profile.id)
          .firstOrNull;
      if (current != null) {
        unawaited(
          store
              .update(current.copyWith(lastConnectedAt: DateTime.now()))
              .catchError((Object e) => _message('无法保存连接时间：$e')),
        );
      }
    }
    if (session.state != SessionState.certificateRequired) {
      _certificateOffered.remove(session.profile.id);
    }
    _showNextCertificate();
    if (_lastStates[session.profile.id] != session.state) {
      _lastStates[session.profile.id] = session.state;
      setState(() {});
    }
  }

  void _showNextCertificate() {
    if (!mounted || !_foreground || _certificateDialogs.isNotEmpty) return;
    final next = _sessions.values
        .where(
          (s) =>
              s.state == SessionState.certificateRequired &&
              !_deleting.contains(s.profile.id) &&
              !_certificateOffered.contains(s.profile.id),
        )
        .firstOrNull;
    if (next == null) return;
    _certificateOffered.add(next.profile.id);
    _certificateDialogs.add(next.profile.id);
    unawaited(
      _verifyCertificate(next).whenComplete(() {
        _certificateDialogs.remove(next.profile.id);
        if (mounted) _showNextCertificate();
      }),
    );
  }

  Future<void> _verifyCertificate(RdpSession session) async {
    final previous = _credentials[session.profile.id]?.fingerprint ?? '';
    final accepted = await showDialog<CertificateAcceptance>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CertificateDialog(
        address: session.profile.address,
        fingerprint: session.fingerprint,
        previousFingerprint: previous,
      ),
    );
    if (!mounted ||
        _sessions[session.profile.id] != session ||
        accepted == null) {
      return;
    }
    final credentials = _credentials[session.profile.id];
    if (credentials == null) return;
    if (accepted.remember) {
      try {
        await store.trust(session.profile, session.fingerprint);
      } catch (_) {
        _message('无法保存至系统安全存储，仅在本次会话中信任');
      }
    }
    if (!mounted || _sessions[session.profile.id] != session) return;
    _credentials[session.profile.id] = (
      password: credentials.password,
      fingerprint: session.fingerprint,
    );
    await _retry(session, certificateAccepted: true);
  }

  Future<void> _retry(
    RdpSession session, {
    bool automatic = false,
    bool certificateAccepted = false,
  }) async {
    if (!mounted ||
        _deleting.contains(session.profile.id) ||
        _sessions[session.profile.id] != session) {
      return;
    }
    if (!automatic &&
        !certificateAccepted &&
        SessionIssue.from(session).action == SessionAction.credentials) {
      await _repairLogin(session);
      return;
    }
    if (!automatic &&
        !certificateAccepted &&
        session.state == SessionState.certificateRequired) {
      _certificateOffered.remove(session.profile.id);
      _showNextCertificate();
      return;
    }
    final credentials = _credentials[session.profile.id];
    if (credentials == null) return;
    if (!automatic) _recoveries[session.profile.id]?.reset();
    _recorded.remove(session.profile.id);
    await session.connect(
      password: credentials.password,
      acceptedFingerprint: credentials.fingerprint,
    );
  }

  Future<void> _closeSession(String id) async {
    final s = _sessions[id];
    if (s == null) return;
    _recoveries.remove(id)?.dispose();
    _certificateOffered.remove(id);
    await s.close();
    if (!mounted || _sessions[id] != s) return;
    setState(() {
      _sessions.remove(id);
      _viewMemories.remove(id);
      _credentials.remove(id);
      _requestedProfiles.remove(id);
      _recorded.remove(id);
      if (_active == id) _active = _sessions.keys.lastOrNull;
      if (_active == null) _fullscreen = false;
    });
    s.dispose();
  }

  Future<void> _import() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'RDP 连接',
            extensions: ['rdp'],
            uniformTypeIdentifiers: ['public.data'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 1024 * 1024) {
        throw const FormatException('RDP 文件不能大于 1 MiB');
      }
      final p = RdpFile.decode(
        await file.readAsBytes(),
        name: file.name.replaceFirst(
          RegExp(r'\.rdp$', caseSensitive: false),
          '',
        ),
      );
      if (!mounted) return;
      final result = await editProfile(context, profile: p);
      if (result == null) return;
      await store.save(result.profile, password: result.password);
      if (result.connect) {
        await _connect(result.profile, password: result.password);
      }
    } catch (e) {
      _message('导入失败：$e');
    }
  }

  Future<void> _export(ConnectionProfile p) async {
    try {
      if ({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }.contains(Theme.of(context).platform)) {
        final text = RdpFile.encode(p);
        await Clipboard.setData(ClipboardData(text: text));
        _message('RDP 配置已复制，可粘贴保存为 .rdp 文件。配置不包含密码。');
        return;
      }
      final location = await getSaveLocation(
        suggestedName:
            '${p.name.replaceAll(RegExp(r'[^\w\u4e00-\u9fff-]'), '_')}.rdp',
        acceptedTypeGroups: [
          const XTypeGroup(label: 'RDP 连接', extensions: ['rdp']),
        ],
      );
      if (location == null) return;
      await XFile.fromData(
        utf8.encode(RdpFile.encode(p)),
        mimeType: 'application/x-rdp',
      ).saveTo(location.path);
      _message('已导出连接配置，文件不包含密码');
    } catch (e) {
      _message('导出失败：$e');
    }
  }

  Future<void> _delete(ConnectionProfile p) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「${p.name}」？'),
        content: const Text('同时移除此设备保存的密码与证书指纹。文件中转站中的文件会保留在本地。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除连接'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!_deleting.add(p.id)) return;
    try {
      await _closeSession(p.id);
      await store.remove(p);
    } catch (e) {
      _message('删除失败：$e');
    } finally {
      _deleting.remove(p.id);
    }
  }

  Future<void> _menu(String action, ConnectionProfile p) async {
    switch (action) {
      case 'edit':
        await _edit(profile: p);
      case 'export':
        await _export(p);
      case 'files':
        try {
          final root = widget.protocolDirectory;
          if (root == null) throw StateError('应用私有目录尚未准备好');
          final current = _sessions[p.id];
          final path =
              current?.transferDirectory ?? TransferFolder.pathFor(root, p);
          final directory = Directory(path);
          if (p.sharedDirectory.isNotEmpty &&
              !Platform.isAndroid &&
              !Platform.isIOS) {
            if (!await directory.exists()) throw StateError('指定的共享目录已不存在');
          } else {
            await directory.create(recursive: true);
          }
          if (!mounted) return;
          await showDialog<void>(
            context: context,
            builder: (_) => TransferDialog(
              directory: path,
              sharingEnabled: current?.profile.fileTransfer ?? p.fileTransfer,
              session: current,
            ),
          );
        } catch (e) {
          _message('无法打开文件中转站：$e');
        }
      case 'delete':
        await _delete(p);
      case 'favorite':
        try {
          await store.update(p.copyWith(favorite: !p.favorite));
        } catch (e) {
          _message('保存失败：$e');
        }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final wide = MediaQuery.sizeOf(context).width >= 980;
      final session = _active == null ? null : _sessions[_active];
      if (_phoneGroup != null &&
          !store.profiles.any((p) => p.group == _phoneGroup)) {
        _phoneGroup = null;
      }
      for (final entry in _sessions.entries) {
        entry.value.setVisible(_foreground && entry.key == _active);
      }
      _audioFocus.select(session, foreground: _foreground);
      final phone = phoneLayout(context);
      return PopScope(
        canPop: session == null,
        onPopInvokedWithResult: (popped, result) {
          if (!popped) {
            setState(() {
              _active = null;
              _fullscreen = false;
            });
          }
        },
        child: Scaffold(
          floatingActionButton: phone && session == null && _section != '设置'
              ? FloatingActionButton.extended(
                  onPressed: _edit,
                  icon: const Icon(Icons.add),
                  label: const Text('添加电脑'),
                )
              : null,
          bottomNavigationBar: phone && session == null
              ? NavigationBar(
                  height: 72,
                  selectedIndex: [
                    '全部连接',
                    '我的收藏',
                    '最近使用',
                    '设置',
                  ].indexOf(_section).clamp(0, 3),
                  onDestinationSelected: (index) => setState(() {
                    _section = ['全部连接', '我的收藏', '最近使用', '设置'][index];
                    _search.clear();
                  }),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.computer_outlined),
                      selectedIcon: Icon(Icons.computer),
                      label: '电脑',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.star_border_rounded),
                      selectedIcon: Icon(Icons.star_rounded),
                      label: '收藏',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.history),
                      label: '最近',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.settings_outlined),
                      selectedIcon: Icon(Icons.settings),
                      label: '设置',
                    ),
                  ],
                )
              : null,
          drawer: wide || phone
              ? null
              : Drawer(
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainer,
                  child: SafeArea(child: _sidebar(drawer: true)),
                ),
          body: SafeArea(
            child: Row(
              children: [
                if (wide && !_fullscreen)
                  SizedBox(width: 236, child: _sidebar()),
                Expanded(
                  child: Column(
                    children: [
                      if (phone &&
                          !(session != null &&
                              MediaQuery.viewInsetsOf(context).bottom > 0 &&
                              MediaQuery.sizeOf(context).height < 500))
                        _phoneHeader(session)
                      else if (!phone && !_fullscreen)
                        _topbar(wide),
                      if (!phone && _sessions.isNotEmpty && !_fullscreen)
                        _tabs(),
                      Expanded(
                        child: session == null
                            ? (_section == '设置' ? _settings() : _library())
                            : RemoteView(
                                key: ValueKey(session),
                                session: session,
                                memory: _viewMemories[session.profile.id],
                                recovery: _recoveries[session.profile.id],
                                active: true,
                                frameRateLimit: store.frameRateLimit,
                                fullscreen: _fullscreen,
                                toggleFullscreen: () =>
                                    setState(() => _fullscreen = !_fullscreen),
                                reconnect: () => _retry(session),
                                configure: () => _configureSession(session),
                                disconnect: () =>
                                    _closeSession(session.profile.id),
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _phoneHeader(RdpSession? session) => SizedBox(
    height: 56,
    child: Row(
      children: [
        if (session != null)
          IconButton(
            tooltip: '返回电脑列表（保持连接）',
            onPressed: () => setState(() {
              _active = null;
              _fullscreen = false;
            }),
            icon: const Icon(Icons.arrow_back),
          )
        else
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Brand(compact: true),
          ),
        Expanded(
          child: Text(
            session?.profile.name ??
                (_section == '全部连接' ? '我的电脑' : _sectionTitle),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        if (session == null)
          IconButton(
            onPressed: _import,
            tooltip: '导入 .rdp',
            icon: const Icon(Icons.file_download_outlined),
          ),
        if (_sessions.isNotEmpty)
          IconButton(
            tooltip: '切换会话',
            onPressed: _phoneSessions,
            icon: Badge(
              label: Text('${_sessions.length}'),
              child: const Icon(Icons.layers_outlined),
            ),
          ),
        const SizedBox(width: 8),
      ],
    ),
  );

  Future<void> _phoneSessions() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(
                '正在进行的会话',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            for (final entry in _sessions.entries)
              ListTile(
                minTileHeight: 72,
                leading: Icon(
                  Icons.computer,
                  color: entry.key == _active
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(
                  entry.value.profile.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  entry.value.profile.address,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: entry.key == _active
                    ? Icon(
                        Icons.check_circle,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.pop(context, entry.key),
              ),
          ],
        ),
      ),
    );
    if (selected != null && mounted && _sessions.containsKey(selected)) {
      setState(() => _active = selected);
    }
  }

  Widget _sidebar({bool drawer = false}) {
    final groups = store.profiles.map((p) => p.group).toSet().toList()..sort();
    return LayoutBuilder(
      builder: (context, bounds) => SingleChildScrollView(
        child: SizedBox(
          height: math.max(bounds.maxHeight, 650),
          child: Container(
            color: Theme.of(context).colorScheme.surfaceContainer,
            padding: const EdgeInsets.fromLTRB(20, 30, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 10),
                  child: Brand(),
                ),
                const SizedBox(height: 28),
                ...[
                  (Icons.grid_view_rounded, '全部连接', store.profiles.length),
                  (
                    Icons.star_border_rounded,
                    '我的收藏',
                    store.profiles.where((p) => p.favorite).length,
                  ),
                  (
                    Icons.history_rounded,
                    '最近使用',
                    store.profiles
                        .where((p) => p.lastConnectedAt != null)
                        .length,
                  ),
                ].map(
                  (item) =>
                      _nav(item.$1, item.$2, count: item.$3, drawer: drawer),
                ),
                const SizedBox(height: 30),
                Padding(
                  padding: EdgeInsets.only(left: 14),
                  child: Text(
                    '分组',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 11,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final group in groups)
                        _nav(
                          Icons.folder_outlined,
                          group,
                          target: 'group:$group',
                          drawer: drawer,
                          small: true,
                        ),
                      if (groups.isEmpty)
                        Padding(
                          padding: EdgeInsets.all(14),
                          child: Text(
                            '添加连接后，分组将在这里显示',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 12,
                              height: 1.8,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                _nav(Icons.tune_rounded, '设置', drawer: drawer),
                Padding(
                  padding: EdgeInsets.fromLTRB(14, 18, 0, 0),
                  child: Text(
                    'LRDP  /  0.1.0 PREVIEW',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 9,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _nav(
    IconData icon,
    String label, {
    int? count,
    bool drawer = false,
    bool small = false,
    String? target,
  }) {
    final selected = _section == (target ?? label) && _active == null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: selected
            ? Theme.of(context).colorScheme.primaryContainer
            : Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: () {
            setState(() {
              _section = target ?? label;
              _active = null;
            });
            if (drawer) Navigator.pop(context);
          },
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 14,
              vertical: small ? 11 : 14,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: small ? 17 : 19,
                  color: selected
                      ? Theme.of(context).colorScheme.onPrimaryContainer
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected
                          ? Theme.of(context).colorScheme.onPrimaryContainer
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                if (count != null)
                  Text(
                    '$count',
                    style: TextStyle(
                      color: selected
                          ? Theme.of(context).colorScheme.onPrimaryContainer
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _topbar(bool wide) => Container(
    height: 76,
    padding: EdgeInsets.symmetric(horizontal: wide ? 36 : 16),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
    ),
    child: Row(
      children: [
        if (!wide)
          Builder(
            builder: (context) => IconButton(
              onPressed: () => Scaffold.of(context).openDrawer(),
              icon: const Icon(Icons.menu_rounded),
              tooltip: '导航',
            ),
          ),
        Icon(
          _active == null
              ? Icons.space_dashboard_outlined
              : Icons.desktop_windows_outlined,
          size: 17,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(width: 10),
        Text(
          _active == null ? '连接管理' : '远程会话',
          style: const TextStyle(fontSize: 13),
        ),
        const Spacer(),
        PopupMenuButton<ThemeMode>(
          onSelected: (mode) => _saveSetting(() => store.setThemeMode(mode)),
          icon: Icon(switch (store.themeMode) {
            ThemeMode.system => Icons.brightness_auto_outlined,
            ThemeMode.light => Icons.light_mode_outlined,
            ThemeMode.dark => Icons.dark_mode_outlined,
          }),
          tooltip: '外观',
          itemBuilder: (_) => [
            for (final mode in ThemeMode.values)
              CheckedPopupMenuItem(
                value: mode,
                checked: store.themeMode == mode,
                child: Text(_themeLabel(mode)),
              ),
          ],
        ),
      ],
    ),
  );
  Widget _tabs() => Container(
    height: 48,
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
    ),
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _active = null),
          icon: const Icon(Icons.grid_view, size: 16),
          label: const Text('连接库'),
        ),
        for (final entry in _sessions.entries)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 5),
            child: Material(
              color: entry.key == _active
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _active = entry.key),
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    Icon(
                      Icons.circle,
                      size: 7,
                      color: entry.value.state == SessionState.connected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.orange,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      entry.value.profile.name,
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      onPressed: () => _closeSession(entry.key),
                      icon: const Icon(Icons.close, size: 14),
                      tooltip: '关闭会话',
                      constraints: const BoxConstraints(minWidth: 30),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _library() {
    final profiles = store.profiles.where((p) {
      final filter = switch (_section) {
        '我的收藏' => p.favorite,
        '最近使用' => p.lastConnectedAt != null,
        '全部连接' => true,
        _ => p.group == _sectionTitle,
      };
      return filter &&
          '${p.name} ${p.host} ${p.username} ${p.group}'.toLowerCase().contains(
            _search.text.trim().toLowerCase(),
          );
    }).toList();
    profiles.sort((a, b) {
      if (_section == '最近使用') {
        return (b.lastConnectedAt ?? DateTime(1970)).compareTo(
          a.lastConnectedAt ?? DateTime(1970),
        );
      }
      if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    if (phoneLayout(context)) return _phoneLibrary(profiles);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 650;
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                compact ? 20 : 36,
                32,
                compact ? 20 : 36,
                24,
              ),
              sliver: SliverList.list(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _sectionTitle,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                          ],
                        ),
                      ),
                      if (!compact)
                        FilledButton.icon(
                          onPressed: _edit,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('添加电脑'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _quickConnect(compact),
                  const SizedBox(height: 20),
                  if (store.loadError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        store.loadError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Row(
                    children: [
                      Text(
                        '$_sectionTitle ',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '${profiles.length}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.outline,
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _import,
                        icon: const Icon(
                          Icons.file_download_outlined,
                          size: 16,
                        ),
                        label: const Text('导入 .rdp'),
                      ),
                      if (!compact) ...[
                        const SizedBox(width: 12),
                        IconButton(
                          onPressed: () => setState(() => _list = !_list),
                          icon: Icon(
                            _list
                                ? Icons.grid_view_outlined
                                : Icons.view_list_outlined,
                            size: 19,
                          ),
                          tooltip: '切换显示方式',
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: '搜索名称、地址或用户名…',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _search.clear();
                                setState(() {});
                              },
                              icon: const Icon(Icons.close, size: 17),
                              tooltip: '清空搜索',
                            ),
                    ),
                  ),
                  const SizedBox(height: 22),
                ],
              ),
            ),
            if (profiles.isEmpty)
              SliverFillRemaining(hasScrollBody: false, child: _empty())
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 20 : 36,
                  0,
                  compact ? 20 : 36,
                  28,
                ),
                sliver: _list
                    ? SliverList.separated(
                        itemCount: profiles.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, i) =>
                            _profileCard(profiles[i], list: true),
                      )
                    : SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: constraints.maxWidth >= 1240
                              ? 4
                              : constraints.maxWidth >= 920
                              ? 3
                              : constraints.maxWidth >= 580
                              ? 2
                              : 1,
                          mainAxisExtent: 234,
                          crossAxisSpacing: 18,
                          mainAxisSpacing: 18,
                        ),
                        itemCount: profiles.length,
                        itemBuilder: (_, i) => _profileCard(profiles[i]),
                      ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(36, 10, 36, 28),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  runSpacing: 8,
                  children: [
                    Text(
                      '${store.profiles.length} 台电脑  ·  ${_sessions.values.where((s) => s.state == SessionState.connected).length} 个活动会话',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _quickConnect(bool compact) => Container(
    padding: EdgeInsets.all(compact ? 20 : 26),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.bolt_rounded,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
            SizedBox(width: 7),
            Text(
              '快速连接',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('quickAddress'),
                controller: _quick,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 14,
                ),
                onSubmitted: (value) => _edit(address: value),
                decoration: InputDecoration(
                  hintText: '主机名或 IP 地址:端口',
                  hintStyle: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  prefixIcon: Icon(
                    Icons.computer_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  fillColor: Theme.of(context).colorScheme.surface,
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: () => _edit(address: _quick.text),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('连接'),
                  if (!compact) ...[
                    const SizedBox(width: 15),
                    const Icon(Icons.arrow_forward_rounded, size: 17),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (compact) ...[
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: _edit,
            icon: const Icon(Icons.add),
            label: const Text('添加电脑'),
          ),
        ],
      ],
    ),
  );
  Widget _profileCard(ConnectionProfile p, {bool list = false}) {
    final live = _sessions[p.id]?.state == SessionState.connected;
    final color = [
      const Color(0xFFDFEADF),
      const Color(0xFFE4E8F1),
      const Color(0xFFEFE6DC),
    ][p.name.codeUnits.fold(0, (a, b) => a + b) % 3];
    final icon = Container(
      width: list ? 40 : 48,
      height: list ? 40 : 48,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Icon(
        Icons.desktop_windows_outlined,
        color: Color.lerp(ink, color, .2),
        size: list ? 22 : 26,
      ),
    );
    final menu = PopupMenuButton<String>(
      tooltip: '连接操作',
      onSelected: (action) => _menu(action, p),
      icon: const Icon(Icons.more_horiz, size: 20),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'edit', child: Text('编辑连接')),
        const PopupMenuItem(value: 'files', child: Text('文件中转站')),
        PopupMenuItem(
          value: 'favorite',
          child: Text(p.favorite ? '取消收藏' : '加入收藏'),
        ),
        PopupMenuItem(
          value: 'export',
          child: Text(
            {
                  TargetPlatform.android,
                  TargetPlatform.iOS,
                }.contains(Theme.of(context).platform)
                ? '复制 RDP 配置'
                : '导出 .rdp',
          ),
        ),
        const PopupMenuItem(value: 'delete', child: Text('删除连接')),
      ],
    );
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _connect(p),
        child: Padding(
          padding: EdgeInsets.all(list ? 16 : 22),
          child: list
              ? Row(
                  children: [
                    icon,
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            p.address,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (live)
                      Icon(
                        Icons.circle,
                        size: 8,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => _connect(p),
                      child: Text(live ? '打开会话' : '连接'),
                    ),
                    menu,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        icon,
                        const Spacer(),
                        if (p.favorite)
                          const Icon(
                            Icons.star_rounded,
                            size: 17,
                            color: Color(0xFFAD8D42),
                          ),
                        menu,
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      p.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            p.group,
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                        const Spacer(),
                        if (live) ...[
                          Icon(
                            Icons.circle,
                            size: 6,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 5),
                        ],
                        Text(
                          live
                              ? '已连接'
                              : p.lastConnectedAt == null
                              ? '尚未连接'
                              : _relativeTime(p.lastConnectedAt!),
                          style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Icon(
                          Icons.arrow_outward,
                          size: 15,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return '刚刚使用';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    return '${diff.inDays} 天前';
  }

  (String, String) get _emptyMessage {
    if (_search.text.isNotEmpty) {
      return ('没有找到匹配的电脑', '请修改名称、地址或用户名后重试');
    }
    return switch (_section) {
      '我的收藏' => ('暂无收藏', '在电脑菜单中选择“加入收藏”'),
      '最近使用' => ('暂无最近连接', '连接过的电脑会显示在这里'),
      _ when store.profiles.isEmpty => ('尚未添加电脑', '添加电脑，或导入 .rdp 连接文件'),
      _ => ('此分组暂无电脑', '添加电脑，或查看全部连接'),
    };
  }

  Widget _empty() => Center(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 74,
            height: 74,
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primaryContainer.withValues(alpha: .45),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(
              Icons.add_to_queue_rounded,
              color: Theme.of(context).colorScheme.primary,
              size: 32,
            ),
          ),
          const SizedBox(height: 20),
          Text(_emptyMessage.$1, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 9),
          Text(
            _emptyMessage.$2,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.outline,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 22),
          OutlinedButton.icon(
            onPressed: store.profiles.isEmpty
                ? _edit
                : () => setState(() {
                    _section = '全部连接';
                    _phoneGroup = null;
                    _search.clear();
                  }),
            icon: Icon(
              store.profiles.isEmpty ? Icons.add : Icons.computer_outlined,
              size: 18,
            ),
            label: Text(store.profiles.isEmpty ? '添加电脑' : '查看全部连接'),
          ),
        ],
      ),
    ),
  );
  Widget _phoneLibrary(List<ConnectionProfile> profiles) {
    final groups = store.profiles.map((p) => p.group).toSet().toList()..sort();
    final visible = profiles
        .where((p) => _phoneGroup == null || p.group == _phoneGroup)
        .toList();
    return CustomScrollView(
      key: const PageStorageKey('phoneConnections'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          sliver: SliverList.list(
            children: [
              TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: '搜索名称、地址或用户名…',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清空搜索',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _search.clear()),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _edit(address: _search.text.trim()),
                icon: const Icon(Icons.bolt_rounded),
                label: const Text('输入地址，快速连接'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              if (store.loadError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(store.loadError!),
                ),
            ],
          ),
        ),
        if (groups.length > 1)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 56,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: const Text('所有分组'),
                      selected: _phoneGroup == null,
                      onSelected: (_) => setState(() => _phoneGroup = null),
                    ),
                  ),
                  for (final group in groups)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(group),
                        selected: _phoneGroup == group,
                        onSelected: (selected) => setState(
                          () => _phoneGroup = selected ? group : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Text(
              '${visible.length} 台电脑 · 点按连接',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (visible.isEmpty)
          SliverFillRemaining(hasScrollBody: false, child: _empty())
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
            sliver: SliverList.separated(
              itemCount: visible.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _profileCard(visible[i], list: true),
            ),
          ),
      ],
    );
  }

  String _themeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
  };

  Future<void> _saveSetting(Future<void> Function() save) async {
    try {
      await save();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('设置未能保存，请检查存储空间后重试')));
      }
    }
  }

  Widget _settings() => ListView(
    padding: EdgeInsets.all(phoneLayout(context) ? 16 : 32),
    children: [
      Text('设置', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 28),
      Card(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: DropdownButtonFormField<ThemeMode>(
                key: ValueKey('theme-${store.themeMode.name}'),
                initialValue: store.themeMode,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '主题模式'),
                items: [
                  for (final mode in ThemeMode.values)
                    DropdownMenuItem(
                      value: mode,
                      child: Text(_themeLabel(mode)),
                    ),
                ],
                onChanged: (mode) {
                  if (mode != null) {
                    _saveSetting(() => store.setThemeMode(mode));
                  }
                },
              ),
            ),
            SwitchListTile.adaptive(
              value: store.useSystemColors,
              onChanged: (value) =>
                  _saveSetting(() => store.setSystemColors(value)),
              title: const Text('使用系统配色'),
              subtitle: const Text('采用系统主题色；不可用时使用默认配色'),
              secondary: const Icon(Icons.palette_outlined),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: DropdownButtonFormField<int>(
                key: ValueKey('frame-rate-${store.frameRateLimit}'),
                initialValue: store.frameRateLimit,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '画面帧率上限',
                  helperText: '实际帧率取决于远端、网络和屏幕刷新率。高帧率会增加耗电。',
                  helperMaxLines: 3,
                ),
                items: [
                  for (final rate in ProfileStore.frameRateOptions)
                    DropdownMenuItem(
                      value: rate,
                      child: Text(rate == 0 ? '自动（跟随屏幕）' : '$rate 帧/秒'),
                    ),
                ],
                onChanged: (rate) {
                  if (rate != null) {
                    _saveSetting(() => store.setFrameRateLimit(rate));
                  }
                },
              ),
            ),
            const Divider(height: 1),
            const ListTile(
              leading: Icon(Icons.enhanced_encryption_outlined),
              title: Text('凭据与信任'),
              subtitle: Text('密码和已确认的证书指纹存储在系统安全存储中。导出的 .rdp 文件不包含密码。'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '关于 LRDP',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              ),
              SizedBox(height: 12),
              Text(
                'LRDP 0.1.0 开发预览版',
                style: TextStyle(fontSize: 13, height: 1.9),
              ),
              SizedBox(height: 16),
              Text(
                '远程控制：点按左键，长按右键；可切换触控板模式或平移缩放画面。\n桌面键盘：Ctrl + Alt + Home 将键盘控制返回本地。',
                style: TextStyle(fontSize: 12, height: 1.8),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 20),
      OutlinedButton.icon(
        onPressed: () => showLicensePage(
          context: context,
          applicationName: 'LRDP',
          applicationVersion: '0.1.0',
        ),
        icon: const Icon(Icons.description_outlined),
        label: const Text('开源许可'),
      ),
    ],
  );
}
