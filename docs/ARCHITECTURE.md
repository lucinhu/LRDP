# LRDP architecture

Flutter owns profiles, credentials, navigation and rendering. A Dart worker
isolate owns each `lrdp_session`. The stable C ABI in `native/include/lrdp.h`
isolates Dart from FreeRDP ABI changes. A WinPR thread owns all FreeRDP calls;
bounded queues serialize input and clipboard data. The native frame store retains
only bounded BGRA snapshots. Linux, Android and Windows have Flutter texture
backends; Apple currently retains the backpressured Dart image path.
Only video tickets and metadata cross the native video platform channel. FreeRDP objects
and session addresses never cross isolate boundaries.

FreeRDP is a pinned Git submodule in `third_party/FreeRDP`. Build options and
channel callbacks live in LRDP. Do not patch the submodule. Upgrade the pointer,
build the bridge and rerun protocol tests. Default builds compile the pinned
source; system libraries are an explicit development option.

Profiles contain no passwords. Secrets use OS secure storage, with no plaintext
fallback. Untrusted certificates stop the connection and expose a SHA-256
fingerprint for explicit approval; acceptance applies only to that fingerprint.
TLS/NLA are enabled; legacy RDP security is disabled. Disabling NLA retains TLS.
Clipboard text is controlled per profile and limited to 1 MiB. No shell command is
constructed from user input. Sessions and secrets are excluded from exports.

GDI publishes BGRA snapshots. Linux uploads these directly from native memory to
a Flutter GL texture; Android uses a SurfaceProducer with a private EGL context.
Windows converts BGRA to RGBA in bounded native buffers for Flutter's pixel
buffer texture. Dart receives dimensions and counters only. Apple native backends, hardware H.264 decoding, RD Gateway,
multi-monitor and persistent mobile background services still need implementation
and device testing. These are not represented as supported features in the UI.

The Windows renderer uses no session pointer. A native ticker observes retained
frame generations and marks the registered texture; it sleeps when every view
is hidden, failed or closed. The raster callback converts only new frames, with
at most three allocated RGBA slots and two outstanding buffer leases. A damage
rectangle is patched in place when the previous slot is still unleased,
otherwise the previous complete frame is copied into a free slot first; first
frames, frame size changes and history gaps reallocate and convert the whole
frame. Channel exchange uses SSE2 4-pixel or 64-bit-word 2-pixel iterations on
little-endian targets, with a scalar fallback. Flutter's
release callback keeps each returned buffer immutable until upload completes.
Disposal retains the reader through asynchronous texture unregistration, and an
outstanding buffer lease can outlive both the session and plugin registration.
Initial/failed frames use a transparent placeholder until Dart can fall back to
CPU images. This path still converts and uploads pixels; it does not implement
Direct3D shared textures or hardware H.264 decoding. Platform verification scope
is recorded separately in `VERIFICATION.md`.

File transfer uses FreeRDP's unmodified RDPDR/drive channel. It defaults off.
A session redirects only its managed exchange directory or one explicitly chosen
desktop directory as `\\tsclient\LRDP`. Profiles imported from RDP files never
enable local filesystem access. Each managed directory has a path-safe encoded
profile identifier. Uploads stream through a staging file; same-name files receive
a numerical suffix. The file panel rejects traversal and links outside its root.
Server-side access is handled by upstream's drive backend, rather than a second
LRDP filesystem protocol.

An explicit file-picker action also offers local files through CLIPRDR
`FileGroupDescriptorW` and size/range requests when the server negotiates file
streams. Dart stages immutable private snapshots; the adapter pins read-only
regular-file handles, serializes names without paths, and reads at most 1 MiB
per request. Batches contain at most 32 files, 256 MiB per file and 512 MiB total.
The shared paste slot acknowledges descriptor delivery and Ctrl+V, not completion
of the remote filesystem copy. Replacing clipboard ownership revokes that list;
locking and huge-file capabilities are not advertised. Remote file clipboard
download and reading file-manager copy selections remain separate work.

Upstream CLIPRDR callbacks run on a channel thread. They copy bounded events into
a 63-entry / 32 MiB mailbox and wake the connection owner; only that owner sends
capabilities, acknowledgements, format data and file responses. Local publication
serials discard earlier queued remote format lists. Pending response barriers and
epochs still reject stale data, and teardown releases queued events after channel
threads have stopped. No FreeRDP source change is required.

The app initializes a private FreeRDP configuration directory before creating
sessions. Android's missing process home is initialized once from that real
private directory, matching upstream's Android bootstrap. Existing homes are
preserved. Test-only sessions use a private temporary directory and remove it
after joining their native thread.

## 手机交互

手机横竖屏使用底部导航与会话操作栏，表单和文件面板为全屏界面。
`RemoteSurface` 在变换后的画面外接收指针，先反算缩放和平移，再映射到远程像素；
触控板的相对移动同时除以基础比例和缩放倍数。两指手势区分页面滚动与画面缩放，
不复用单指点击；拖拽取消、焦点丢失、后台切换与销毁都会释放已按下的鼠标按钮。
`MobileKeyboard` 保留本地输入法组合区，点击发送时结束当前组合，将输入栏文字通过带确认的剪贴板粘贴发送；
没有剪贴板通道时使用 Unicode 按键。桌面文字对话框复用相同组件，失败不关闭输入栏。
键盘模拟模式把本机英文输入法的编辑变化转换为 Set 1 按键，组合提交不重复字母，
通过本地不可见前缀接收空栏退格；前缀不发送远端。切换模式保留当前文字草稿。
单次触屏点击先保留 300 ms，快速双击发送两次点击，第二次按住或移动则消耗第一次
轻点，只发送一次鼠标按住，避免远端把窗口拖拽解释为标题栏双击。
软键盘出现时按实际剩余布局高度收起快捷键，横屏还会收起会话标题栏。

`WorkspaceScreen` 为每个打开的逻辑会话保留 `RemoteViewMemory`。离开界面时
释放控件、焦点、计时器和按住状态，仅保留缩放倍数、远程画面中心和光标的归一化坐标，
以及触控板/触屏、单指平移模式。关闭或替换会话时清除这些数据；返回时键盘保持收起。
旋转、键盘布局和服务端分辨率变化后，用新的适应比例重建变换并限制画面边界。
先按原坐标释放拖拽，再调整光标比例。已处理的服务端位置序号随当前连接时间保存，
避免旧位置覆盖用户的本地移动；新连接仍接受新的服务端位置。

MouseRegion 的被动进入不改变光标；真实鼠标移动和按下才使用绝对位置。
Android 可能在手指按下前补发 touch 类型的 HoverEvent，必须按设备类型过滤，
否则会把触控板光标移到手指的绝对位置，造成下一次点击偏移。

## Reconnection and cancellation

The LRDP C ABI is version 5. Dart checks `lrdp_abi_version()` when loading the
bridge; old packaged libraries must be rebuilt with the application. Terminal
state exposes a stable reason and the upstream numeric error before disconnect
can reset it. Only explicit transport/DNS/connect errors and failed connected I/O
without another error cause permit retry. Certificate, authentication, explicit
server ErrorInfo, protocol errors and local cancellation do not. A server closing
TCP without ErrorInfo can be indistinguishable from a broken transport; that
case still has a maximum of five attempts.

`SessionRecovery` observes state transitions without storing credentials. It
starts only after a successful connection, uses 1/2/4/8/16 second delays, and
resets its budget only after 30 stable seconds. Manual reset, cancel and session
removal cancel pending timers. The manager retains credentials only for the
lifetime of its open session. Recovery creates a fresh authenticated connection;
upstream automatic reconnection cookies are not enabled. Remote session reuse
is controlled by the server.

Each Dart worker has its own completion signal and late command-port handler.
A monotonically increasing generation cancels stale connect requests and frame
decodes. Stop awaits the worker's native teardown; even a port arriving after
cancellation receives stop. No isolate is killed while it owns a native pointer.
New workers begin with empty input queues and no pending clipboard delivery.

Local stop rejects new input and discards unsent input. The network owner
tracks successfully sent scan codes (including extended flags), UTF-16 units
and the three mouse buttons. Before orderly disconnect it releases mouse
buttons at the last non-wheel position, then text/ordinary keys and modifiers.
Repeated downs need one release; already released keys receive no duplicate up.

The public `rdpTransportIo.ConnectLayer` callback wraps upstream's nonblocking
TCP layer. Reads/writes and bounded waits check LRDP's cancellation deadline
on the network owner. Stop permits a 500 ms grace period for releases; blocked
output then fails, including teardown writes. Repeated stop does not extend
the deadline. No timer thread accesses transport internals or closes sockets.
The existing documented cross-thread `freerdp_abort_connect_context` is used
to cancel connection establishment; its abort event alone does not interrupt
an upstream output-buffer flush. A broken or non-reading peer cannot be
guaranteed to receive releases. Inputs are never replayed on a new connection.


On Android/iOS, `WorkspaceScreen` observes application lifecycle. Hidden sessions
stop delivering frames to Flutter. Retry countdowns and the stable-connection
budget reset timer pause outside `resumed`; healthy native sessions and an
already started attempt are not forcibly disconnected. On return, the remaining
retry delay continues. This policy does not provide a mobile foreground service
or persistence across OS process termination. Desktop recovery continues in the
background.

Certificate requests queue in the manager. No confirmation route is pushed while
the mobile app is backgrounded, only one prompt is visible, and cancelling a
prompt suppresses it until a new connection attempt. Disposal detaches sessions
before publishing close notifications to avoid rebuilding unmounted elements.

Live-session reuse compares all protocol and recovery settings plus an explicitly
provided password. Presentation metadata does not invalidate an existing session.
Saving and connecting with new transfer/display/security options or credentials
creates a session using those options; saving configuration alone does not
silently replace a live desktop.


## Quality presets and key combinations

A profile carries an additive `quality` preset: automatic, save bandwidth or
sharp text. It is stored as an index in the profile JSON (missing or unknown
values fall back to automatic), compared by live-session reuse, and sent to the
native side with the other start-time settings. The setting is applied before
`lrdp_start`: save bandwidth asks the server to drop wallpaper, themes, window
dragging and menu animations and disables font smoothing; sharp text keeps those
effects, enables font smoothing and forces the lossless GDI path by disabling
GfxH264. Color depth stays 32 bpp, and an invalid value is rejected. FreeRDP
turns the booleans into the performance flags sent in the Client Info PDU, so
changing a preset requires a new session. Imported `.rdp` files do not carry the
preset and load as automatic.

Measured against a real 1920x1080 KDE/KRdp session (2026-10-31, release native
library, idle desktop with animation): automatic and save bandwidth negotiated
GFX H.264, used 1.8-2.4 Mbit/s downlink and about half a CPU core (51% / 46% of
one core) for software decoding; sharp text switched to bitmap updates, used
19.7-21.8 Mbit/s and 17% CPU. H.264 frames cover the whole surface, so the frame
damage rectangle is the full frame on those two presets; sharp text produced
real partial rectangles averaging 92,514 of 2,073,600 pixels (about 0.37 MB per
frame instead of 8.29 MB). The preset labels therefore describe a bandwidth
versus decode-CPU tradeoff, not a claim that the default is cheapest overall.

The remote view more-sheet also exposes a sender-side "组合键" menu with task
manager, window switch, close, show desktop, explorer, run, lock and PrintScreen.
Each entry transmits one bounded chord while the session is connected; extended
scan codes use the existing `0x100 | code` convention. The menu verifies that
chords are sent, not that the remote desktop acted on them.


## Session info, diagnostics and configuration backup

The remote view more-sheet opens a read-only session info panel. The panel owns a
one-second sampling timer and repaints only its own rows; it never subscribes to
the session change notifier, so inspecting the session cannot make the remote
view rebuild per frame. The measured rate is the delta of `session.frames` on the
native texture path or `session.decodedFrames` on the CPU fallback divided by the
wall time between samples. Alongside it the panel lists connection state, remote
resolution, renderer, codec, the frame rate cap, uploaded/decoded counters, audio
state and negotiated clipboard capabilities.

The settings page offers a sanitized diagnostics report and a configuration
backup. Diagnostics are built from the release tag, OS and version, language,
profile count and display/update preferences only: the builder never receives
profile data, so addresses, accounts, passwords, certificate fingerprints and
update tokens cannot leak. The panel shows the text selectable and copies it to
the system clipboard.

Configuration backups use the `lrdp.profiles` v1 JSON envelope. Only
`ConnectionProfile.toJson()` is written, which excludes passwords and trusted
certificate fingerprints (both live in the platform vault keyed by profile id).
Decoding validates the format marker, version, non-empty profile array and per
entry parsing, and rejects a file that lists the same endpoint twice. Import
merges into the local store by host + port + username (host and username
case-insensitive), reports how many connections were imported and skipped, and
gives an accepted profile with a colliding id a fresh `<id>-import-N` id before
saving it through the store. Export and import use the platform file chooser;
the dialog itself is injectable for tests.

## RDP cursor pipeline

LRDP registers FreeRDP pointer New/Free/Set, system null/default and position
callbacks. The unmodified upstream pointer cache handles Color/New/Large/Cached
PDUs. Each session advertises 32 cache entries and accepts up to 384×384 pixels;
upstream negotiates the required multifragment capability.

ABI v3 adds `lrdp_cursor`: caller-owned metadata, generation and pixel snapshots.
Each bitmap contains premultiplied BGRA plus a separate white inversion mask.
Monochrome/color AND+XOR inversion is preserved as an actual background operation,
rather than replaced by a fixed contrasting pattern. Cached pointer storage and
the published latest snapshot have separate ownership and bounded dimensions.

The worker has independent cursor backpressure and does not transfer or decode a
new bitmap for a position-only update. The session owns decoded images and
invalidates late decodes with the connection generation. Frame and cursor buffers
never cross the FFI/isolate boundary as borrowed pointers.

`RemoteSurface` paints the normal cursor and difference mask as a foreground
painter on the same canvas as the desktop RawImage. Hotspots use the cursor's
actual display scale, including small-screen enlargement and viewport zoom.
A position serial applies server warps once; later shape-only updates preserve
local trackpad motion. Position-only updates also stay off the rebuild path: the
session publishes each accepted position through a dedicated `cursorMoved`
notifier, and only a new shape, kind or hotspot notifies the generic session
listeners. `RemoteSurface` re-syncs its pointer from that notifier, so a server
pointer move repaints only the cursor layer instead of rebuilding the workspace
and the remote surface.
Native system mouse cursors are hidden inside remote
control mode; server null/default requests hide the virtual pointer or restore
the local arrow. This is software composition; platform native cursor APIs and
relative mouse capture remain separate work.

## Confirmed text paste and AVC decode

ABI v4 adds `lrdp_paste` and a bounded status snapshot in `lrdp_read` field 3.
The worker owns one request identifier per paste. Native code advertises local
text only on an explicit write, waits for the server's format acknowledgement,
then transmits Ctrl+V on the connection thread. Success requires both Unicode
data delivery and shortcut transmission. A five-second timeout, cancellation,
negative acknowledgement or missing data retains the phone composer's text;
there is no automatic paste retry. The protocol has no acknowledgement ID, so
an unresolved advertisement remains a barrier to a later paste. This avoids
using a late acknowledgement to paste the wrong text. A disconnect completes
pending Dart callers and old worker results cannot affect a new session.

The FFmpeg build supplies static H.264 decoding, parsing and pixel conversion,
with no GPL/nonfree or hardware backends. LRDP advertises AVC only when the
linked build contains its decoder. The adapter wraps the upstream surface
callback without modifying it; feature bit 2 records a successful AVC surface
decode. Decode failures are protocol failures and do not start transport retry
loops. Frame transport still copies BGRA through Dart; textures and hardware
decoding remain future work. The source/rebuild distribution includes the exact
LGPL source tarball and full application code for relinking.

## Remote audio

A profile opts into remote playback; older profiles stay muted. The worker
passes the immutable preference to native configuration before start. The
connection thread registers rdpsnd before upstream's network-detection helper
can insert its null-device dependency, then restores the requested playback
flag. Microphone capture and the AUDIN channel remain disabled. Platform sinks
are selected by upstream's existing Pulse/WinMM/OpenSL ES/Apple backends, with
no upstream source changes. The configured 250 ms buffer balances ordinary
scheduler jitter; no hardware latency or A/V synchronization claim is made.

The protocol test sends already encoded signed PCM to avoid the system fixture
server's optional PCM encoder affecting the expected bytes. A private Pulse
null sink and session bus keep all synthetic audio away from hardware. Capture
starts with observed silence before playback; short spectral windows distinguish
500 Hz left/1000 Hz right despite packet-boundary timing. Effective duration,
levels, cross-channel rejection, simultaneous drive redirection and a retained
RDP connection on mute/unsupported formats are checked independently of channel
negotiation. ASan instruments the LRDP adapter, not all upstream driver code.


ABI v5 adds `lrdp_audio_active` and read field 4 for playback state. Both static
and dynamic RDPSND plugins use LRDP's public-interface device proxy; each plugin
has its own backend/format/lock while a session hub owns playback permission.
Pause revokes permission immediately, clears pending PCM and wakes the connection
owner to release the device. A latched reset preserves pause even if resume is
requested before the owner runs. Device loss silences playback without failing RDP.

`SessionAudioFocus` grants only the selected active foreground session.
Android also needs native AudioManager focus. Token-specific requests, releases
and callbacks prevent an old asynchronous grant or coordinator disposal from
unmuting/releasing a newer owner. Temporary loss and duck requests pause; focus
gain resumes new data. Returning to the computer list pauses without reconnecting.
MainActivity abandons focus on pause/destroy, with a legacy API24/25 path.

OpenSL ES receives bounded PCM buffering and approximately 50 ms blocks. Initial
prebuffer targets 250 ms, awaiting data is capped at 500 ms with oldest-frame
drops, and estimated device submission stays bounded. PCM8 is converted to signed
PCM16. Short tails flush after input stops; fractional sample rates use a
microsecond clock to avoid accumulating millisecond rounding error.
No mobile foreground service, persistence through process death, long cached
process freeze recovery or physical output latency is claimed.


## Native video readers and Linux textures

Six additive exports retain base ABI v5 (28 exports total). The worker obtains
an opaque integer with `lrdp_video_ticket`; the platform opens it with
`lrdp_video_open`, reads metadata with `lrdp_video_info`, borrows immutable BGRA
bytes during `lrdp_video_visit` or `lrdp_video_visit_damage`, and releases its
reader with `lrdp_video_close`.
Only these plain frame-memory APIs may run outside the session's owning worker.
Retiring the session removes its ticket before dropping the owner reference;
existing readers retain the final frame, while opening a retired ticket fails.
The caller serializes closing its own reader against its reads/callbacks.

`lrdp_video_visit_damage` reports the bounding box, in frame pixels, of every
pixel changed since that reader's last successful upload; pixels outside it are
byte-identical to that upload. A NULL rectangle asks for the whole frame (first
upload, frame size change, or a gap the bounded history no longer covers) and a
zero-size rectangle means nothing visible changed. Renderers that cannot upload
a sub-rectangle keep using `lrdp_video_visit`, which always sees complete slots.

A three-slot pool permits at most two outstanding borrowed callbacks. The
producer always has a free slot and does not wait for GL work. Slots are reused
and resized within the existing 4096-pixel dimension limit. A rejected or busy
upload does not consume its generation. The producer refreshes only the union of
the rectangles changed since a slot last held a complete frame, keeping a
32-generation damage ring to describe skipped frames or a reused slot; beyond
that it copies the whole frame. This removes the per-frame GDI-to-native
full-frame copy and the per-frame full GPU upload on the common path, rather
than promising an end-to-end zero-copy or hardware-decoding pipeline.

The hybrid FFI/Linux plugin uses `FlTextureGL`, uploads BGRA into RGBA8 storage,
and preserves GL unpack/binding state. A damage rectangle becomes
`glTexSubImage2D` with `GL_UNPACK_ROW_LENGTH`/`SKIP_ROWS`/`SKIP_PIXELS`, while
per-frame immutable state (texture parameters, sampling) is set only when a
texture is created and `glGetError` is limited to recreation or
`LRDP_VIDEO_GL_CHECK=1`. Its 16 ms native timer announces changed
visible frames; the Dart channel polls metadata at a lower rate. Hidden views
freeze the texture and resume the latest snapshot. Cursor XOR remains the same
Flutter foreground compositor as the CPU path. A dedicated thread deletes each
session's GL texture in a separate shared EGL context without taking Flutter or
GTK contexts away from their threads.

A failed initial upload supplies a transparent 1x1 texture while Dart switches
back to the CPU path. One placeholder is shared per engine and freed with that
engine's GL share group, so repeated failures do not allocate one per session.
Per-session textures, contexts and native readers are released on close. Missing
plugins also retain CPU rendering; `LRDP_DISABLE_TEXTURES=1` explicitly selects it
on Linux. The upload-failure environment hook exists only in Debug builds.

Linux loads the already linked `liblrdp.so` by SONAME, and the plugin locates its
co-located core via `$ORIGIN`. ELF internal function binding keeps separate
loaded copies' registries independent. Without this, a bundle-path FFI load could
create a second core whose internal close call resolves into the first registry.
A two-copy subprocess regression verifies this loader boundary.


## Android Surface video

The hybrid Android FFI/plugin registration uses the same `dev.lrdp/video`
metadata channel as Linux. Texture ID zero is valid on Android. Java first
probes the JNI metadata interface, so a mismatched or missing renderer keeps
the CPU image path. The public C ABI remains v5 with 28 exports; seven private
Android JNI entrypoints adapt the platform renderer to retained frame readers.
Neither session pointers nor frame arrays cross Java or Dart.

A dedicated HandlerThread owns all readers, ANativeWindow references and EGL/GLES
objects. SurfaceProducer creation, dimensions, callbacks and release stay on the
Android main thread. Each session has at most one pending status task and one
draw; the pool supplies the latest immutable frame. Packed native BGRA bytes
enter a GLES2 RGBA texture unchanged; a high precision shader swaps R/B, avoiding
CPU color conversion. Damage rectangles use `glTexSubImage2D` with
`GL_UNPACK_ROW_LENGTH`/`SKIP_PIXELS`/`SKIP_ROWS` and the unpack state is restored
immediately, on an ES3 context when available and a whole-frame ES2 fallback
otherwise. The offscreen Surface is consumed by Flutter's texture
registry, rather than using a platform view that could intercept touch gestures.
The renderer caches one `ANativeWindow` acquisition and one `EGLSurface` for the
lifetime of the Java Surface object; rotation, background/foreground or producer
replacement rebinds them, and `eglMakeCurrent` is skipped when the same context
and draw surface are already current. A steady frame therefore costs one swap
instead of a window acquire, surface bind and context switch. The optional
`LRDP_ANDROID_GL_TRACE=1` logcat tag `lrdp-video` prints bounded frame,
window-bind, surface-creation and make-current counters.

Surface cleanup stops drawing, drops the old EGL surface, and keeps the reader.
Surface availability or foreground resume redraws even an unchanged final frame.
A terminal EGL/GL failure, or bounded repeated surface failures, returns to CPU
images. Main-thread disposal releases the SurfaceProducer first to wake a queued
swap; native teardown is queued after prior GL work. It never joins the GL thread
on main or terminates Android's process-wide EGL display. Cleanup diagnostics
check EGL release results, rather than merely decrementing allocation counters.

The Android ticker stops when every view is hidden, failed or closed. Dart
metadata timers also stop while hidden. GPU failures and surface recreation can
be injected only through a debuggable application's test channel; Release native
upload code excludes the failure branch. One informational `LRDP-video` log per
reader records the first successfully presented frame's dimensions, without
hostnames, credentials or pixel data; the main Release OS test uses it to prove
that its default renderer is active.

`--dart-define=LRDP_DISABLE_TEXTURES=true` builds a CPU compatibility client.
The older Android runtime suite explicitly selects that path because it samples
Dart images. Separate native/forced-failure system screenshots, default native
Workspace gestures and actual main Release OS input cover the production mode.
An emulator's GLES execution does not establish physical GPU speed, battery
improvement, hardware H.264 decoding or API24/device interoperability.
