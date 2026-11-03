#!/usr/bin/env python3
"""Run host-only Android video scheduling regressions with Python and JDK 11+.

Compiles the current Java plugin against small Android/Flutter queue stubs,
replacing only JNI declarations with a deterministic native-renderer mock.
The real Video implementation runs unchanged. This checks scheduling/state,
not Android runtime, SurfaceProducer, JNI ABI, EGL, pixels, or device behavior.
Run: python3 scripts/test_android_video_scheduler.py
All generated sources/classes live in an automatically removed temporary dir.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / ('packages/lrdp_native/android/src/main/java/'
                 'dev/lrdp/lrdp_native/LrdpNativePlugin.java')

# Deliberately manual loopers: tests can interrupt each status/draw/completion
# boundary with a lifecycle transition, without sleeps or real threads.
SOURCES = {
    'android/os/Looper.java': '''package android.os;
import java.util.ArrayDeque;
public class Looper {
  public static final Looper MAIN = new Looper();
  public final ArrayDeque<Runnable> queue = new ArrayDeque<>();
  public static Looper getMainLooper() { return MAIN; }
  public boolean runOne() {
    Runnable r = queue.poll();
    if (r == null) return false;
    r.run(); return true;
  }
}''',
    'android/os/Handler.java': '''package android.os;
public class Handler {
  public final Looper looper;
  public Handler(Looper l) { looper = l; }
  public boolean post(Runnable r) { looper.queue.add(r); return true; }
}''',
    'android/os/HandlerThread.java': '''package android.os;
public class HandlerThread {
  private final Looper looper = new Looper();
  public HandlerThread(String s) {} public void start() {}
  public Looper getLooper() { return looper; }
  public boolean quitSafely() { return true; }
}''',
    'android/os/Build.java': '''package android.os;
public class Build { public static class VERSION { public static int SDK_INT; } }''',
    'android/content/pm/ApplicationInfo.java': '''package android.content.pm;
public class ApplicationInfo {
  public static final int FLAG_DEBUGGABLE = 2;
  public int flags = FLAG_DEBUGGABLE;
}''',
    'android/content/Context.java': '''package android.content;
public class Context {
  public android.content.pm.ApplicationInfo getApplicationInfo() {
    return new android.content.pm.ApplicationInfo();
  }
}''',
    'android/util/Log.java': '''package android.util;
public class Log { public static int i(String tag, String value) { return 0; } }''',
    'android/view/Surface.java': '''package android.view;
public class Surface {
  public static final int FRAME_RATE_COMPATIBILITY_DEFAULT = 0;
  public static boolean failHint;
  public int hints;
  public void setFrameRate(float rate, int compatibility) {
    hints++;
    if (failHint) throw new RuntimeException("optional hint rejected");
  }
}''',
    'android/view/Choreographer.java': '''package android.view;
public class Choreographer {
  public interface FrameCallback { void doFrame(long t); }
  private static final Choreographer INSTANCE = new Choreographer();
  public static Choreographer getInstance() { return INSTANCE; }
  public void postFrameCallback(FrameCallback cb) {}
  public void removeFrameCallback(FrameCallback cb) {}
}''',
    'androidx/annotation/Keep.java': 'package androidx.annotation; public @interface Keep {}',
    'androidx/annotation/NonNull.java': 'package androidx.annotation; public @interface NonNull {}',
    'io/flutter/view/TextureRegistry.java': '''package io.flutter.view;
import android.view.Surface;
public interface TextureRegistry {
  SurfaceProducer createSurfaceProducer();
  interface SurfaceProducer {
    long id(); void setSize(int w, int h); Surface getSurface();
    void setCallback(Callback cb); void release();
    interface Callback { void onSurfaceCleanup(); void onSurfaceAvailable(); }
  }
}''',
    'io/flutter/embedding/engine/plugins/FlutterPlugin.java': '''package io.flutter.embedding.engine.plugins;
import io.flutter.view.TextureRegistry;
public interface FlutterPlugin {
  void onAttachedToEngine(FlutterPluginBinding b);
  void onDetachedFromEngine(FlutterPluginBinding b);
  class FlutterPluginBinding {
    private final TextureRegistry registry;
    public FlutterPluginBinding(TextureRegistry r) { registry = r; }
    public TextureRegistry getTextureRegistry() { return registry; }
    public Object getBinaryMessenger() { return null; }
    public android.content.Context getApplicationContext() { return new android.content.Context(); }
  }
}''',
    'io/flutter/plugin/common/MethodCall.java': '''package io.flutter.plugin.common;
import java.util.Map;
public class MethodCall {
  public final String method;
  private final Map<String, Object> arguments;
  public MethodCall(String m, Map<String, Object> args) { method = m; arguments = args; }
  @SuppressWarnings("unchecked") public <T> T argument(String s) { return (T) arguments.get(s); }
}''',
    'io/flutter/plugin/common/MethodChannel.java': '''package io.flutter.plugin.common;
public class MethodChannel {
  public MethodChannel(Object m, String name) {}
  public void setMethodCallHandler(MethodCallHandler h) {}
  public interface MethodCallHandler { void onMethodCall(MethodCall c, Result r); }
  public interface Result {
    void success(Object value); void error(String code, String message, Object details);
    void notImplemented();
  }
}''',
    'dev/lrdp/lrdp_native/Bridge.java': '''package dev.lrdp.lrdp_native;
import android.view.Surface;
public final class Bridge {
  static long generation, presented, uploads, nextGeneration, failure;
  static int width, height, failed;
  static void fresh() {
    generation = 1; presented = uploads = nextGeneration = 0;
    failure = Long.MIN_VALUE; width = 640; height = 480; failed = 0;
  }
  static long create(long ticket) { return 1; }
  static long[] status(long handle) { return new long[]{width, height, generation, uploads, failed}; }
  static long draw(long handle, Surface surface, int w, int h) {
    if (failure != Long.MIN_VALUE) return failure;
    if (nextGeneration > 0) { generation = nextGeneration; nextGeneration = 0; }
    if (presented != generation) uploads++;
    presented = generation;
    return presented;
  }
  static void reset(long handle, boolean detach) { presented = 0; }
  static void destroy(long handle) {}
  static long[] diagnostics() { return new long[7]; }
  static void testFailure(boolean enabled) {}
}''',
    'dev/lrdp/lrdp_native/IdleRegression.java': '''package dev.lrdp.lrdp_native;
import android.os.*;
import android.view.Surface;
import io.flutter.view.TextureRegistry;
import io.flutter.plugin.common.*;
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding;
import java.lang.reflect.*;
import java.util.*;

public final class IdleRegression {
  static int assertions;
  static void equal(long want, long got, String why) {
    assertions++;
    if (want != got) throw new AssertionError(why + ": expected " + want + ", got " + got);
  }
  static class Producer implements TextureRegistry.SurfaceProducer {
    int sizes, gets;
    Surface surface = new Surface(); Callback callback;
    public long id() { return 11; }
    public void setSize(int w, int h) { sizes++; }
    public Surface getSurface() { gets++; return surface; }
    public void setCallback(Callback c) { callback = c; }
    public void release() {}
  }
  static class Fixture {
    final LrdpNativePlugin plugin = new LrdpNativePlugin();
    final Producer producer = new Producer();
    final FlutterPluginBinding binding = new FlutterPluginBinding(() -> producer);
    final Looper gl;
    Object video; long now;
    Fixture(int api) throws Exception {
      Bridge.fresh(); Build.VERSION.SDK_INT = api; Surface.failHint = false;
      plugin.onAttachedToEngine(binding);
      // There is no liblrdp on this host classpath. JNI entry points below have
      // been replaced with Bridge, so enable the mock capability explicitly.
      Field loaded = plugin.getClass().getDeclaredField("loaded");
      loaded.setAccessible(true); loaded.set(plugin, true);
      Field g = plugin.getClass().getDeclaredField("gl");
      g.setAccessible(true); gl = ((Handler) g.get(plugin)).looper;
      call("create", Map.of("ticket", 1L));
      Field v = plugin.getClass().getDeclaredField("videos");
      v.setAccessible(true); video = ((Map<?, ?>) v.get(plugin)).get(11L);
      drain();
    }
    void step() throws Exception {
      now += 1000000000L;
      Method m = video.getClass().getDeclaredMethod("step", long.class);
      m.setAccessible(true); m.invoke(video, now);
    }
    void tick() throws Exception { step(); drain(); }
    void ticks(int n) throws Exception { for (int i = 0; i < n; i++) tick(); }
    void drain() {
      int guard = 0;
      while (true) {
        boolean a = gl.runOne(), b = Looper.MAIN.runOne();
        if (!a && !b) break;
        if (++guard > 100) throw new AssertionError("queue did not drain");
      }
    }
    Object call(String name, Map<String, Object> args) {
      Map<String, Object> all = new HashMap<>(args); all.putIfAbsent("id", 11L);
      Object[] out = {null};
      plugin.onMethodCall(new MethodCall(name, all), new MethodChannel.Result() {
        public void success(Object v) { out[0] = v; }
        public void error(String c, String m, Object d) { throw new AssertionError(c + ":" + m); }
        public void notImplemented() { throw new AssertionError("not implemented"); }
      });
      return out[0];
    }
    long count(String key) { return ((Number) ((Map<?, ?>) call("status", Map.of())).get(key)).longValue(); }
    void visibility(boolean v) { call("visible", Map.of("visible", v)); }
    void replace() {
      producer.callback.onSurfaceCleanup(); producer.surface = new Surface();
      producer.callback.onSurfaceAvailable();
    }
    void close() { plugin.onDetachedFromEngine(binding); drain(); }
  }
  static void staticFrames(int api) throws Exception {
    Fixture f = new Fixture(api); f.tick();
    long d = f.count("drawAttempts"), s = f.count("sizeChanges");
    int gets = f.producer.gets;
    f.ticks(300);
    equal(1, d, "first draw API" + api);
    equal(d, f.count("drawAttempts"), "static draws API" + api);
    equal(s, f.count("sizeChanges"), "static sizes API" + api);
    equal(gets, f.producer.gets, "static getSurface API" + api);
    Bridge.generation++; f.tick();
    equal(d + 1, f.count("drawAttempts"), "new generation API" + api);
    equal(s, f.count("sizeChanges"), "new generation same size API" + api);
    int hints = f.producer.surface.hints;
    gets = f.producer.gets; d = f.count("drawAttempts");
    f.call("frameRate", Map.of("frameRate", 30)); f.tick();
    equal(d, f.count("drawAttempts"), "fps hint does not draw API" + api);
    equal(gets + (api >= 30 ? 1 : 0), f.producer.gets, "fps hint surface API" + api);
    equal(hints + (api >= 30 ? 1 : 0), f.producer.surface.hints, "fps hint applied API" + api);
    Surface.failHint = true; f.call("frameRate", Map.of("frameRate", 24)); f.tick();
    gets = f.producer.gets; f.ticks(30);
    equal(gets, f.producer.gets, "rejected optional hints settle API" + api);
    equal(d, f.count("drawAttempts"), "rejected hint does not draw API" + api);
    Surface.failHint = false;
    f.visibility(false); f.ticks(5);
    equal(d, f.count("drawAttempts"), "hidden does not draw API" + api);
    f.visibility(true); f.tick();
    equal(d + 1, f.count("drawAttempts"), "visible re-presents API" + api);
    f.visibility(true); f.tick();
    equal(d + 1, f.count("drawAttempts"), "idempotent visible API" + api);
    f.replace(); f.tick();
    equal(d + 2, f.count("drawAttempts"), "surface replacement API" + api);
    equal(s, f.count("sizeChanges"), "surface replacement preserves dimensions API" + api);
    f.call("testRecreateSurface", Map.of()); f.tick();
    equal(d + 3, f.count("drawAttempts"), "debug recreation re-presents API" + api);
    equal(s + 2, f.count("sizeChanges"), "debug recreation dimensions API" + api);
    f.close();
  }
  static void asyncGenerationAndResize() throws Exception {
    Fixture f = new Fixture(26); Bridge.nextGeneration = 2; f.tick();
    equal(1, f.count("drawAttempts"), "raced draw count");
    equal(2, Bridge.presented, "draw really consumed g2");
    f.ticks(30);
    equal(1, f.count("drawAttempts"), "raced generation settles");
    Bridge.generation = 3; f.step(); f.gl.runOne(); Looper.MAIN.runOne();
    Bridge.width = 800; Bridge.height = 600; Bridge.nextGeneration = 4; f.drain();
    long sizes = f.count("sizeChanges"); f.tick();
    equal(sizes + 1, f.count("sizeChanges"), "raced resize not skipped despite equal generation");
    equal(3, f.count("drawAttempts"), "resize re-presents current generation");
    f.ticks(30);
    equal(3, f.count("drawAttempts"), "raced resize settles");
    Bridge.generation = (1L << 33) + 1; f.tick(); f.ticks(20);
    equal(Bridge.generation, Bridge.presented, "64-bit generation consumed");
    equal(4, f.count("drawAttempts"), "64-bit generation settles without narrowing"); f.close();
  }
  static void epochRaces() throws Exception {
    for (int phase = 0; phase < 3; phase++) {
      Fixture f = new Fixture(30); f.tick(); Bridge.generation++;
      f.step(); f.gl.runOne(); // status sampled, response waiting on main
      if (phase >= 1) Looper.MAIN.runOne(); // draw queued on GL
      if (phase >= 2) f.gl.runOne(); // draw completed, response waiting on main
      long before = f.count("drawAttempts"); f.replace(); f.drain();
      if (phase < 2) equal(before, f.count("drawAttempts"), "stale work ignored phase" + phase);
      f.tick();
      equal(before + 1, f.count("drawAttempts"), "replacement receives frame phase" + phase);
      f.ticks(20);
      equal(before + 1, f.count("drawAttempts"), "epoch settles phase" + phase); f.close();
    }
  }
  static void failures() throws Exception {
    Fixture f = new Fixture(26); Bridge.failure = 0; f.ticks(2);
    equal(2, f.count("drawAttempts"), "zero is not success");
    Bridge.failure = Long.MIN_VALUE; f.tick(); f.ticks(20);
    equal(3, f.count("drawAttempts"), "recovery settles"); f.close();
    f = new Fixture(26); Bridge.failure = -3; f.ticks(40);
    equal(30, f.count("drawAttempts"), "failure retry bound");
    f.replace(); f.visibility(false); f.visibility(true); f.ticks(5);
    equal(30, f.count("drawAttempts"), "failed state stays terminal"); f.close();
    f = new Fixture(26); Bridge.failed = 1; f.tick();
    equal(0, f.count("drawAttempts"), "native failure never draws"); f.close();
  }
  public static void main(String[] args) throws Exception {
    for (int api : new int[]{24, 26, 29, 30, 35}) staticFrames(api);
    asyncGenerationAndResize(); epochRaces(); failures();
    System.out.println("PASS " + assertions + " host mock assertions: API24/26/29/30/35 idle, "
        + "fps, size, visibility, surface epochs, g1/g2 race, zero/failure retries. "
        + "Android device validation is separate.");
  }
}''',
}

JNI_MOCKS = {
    'long nativeCreate(long ticket)': 'return Bridge.create(ticket);',
    'long[] nativeStatus(long handle)': 'return Bridge.status(handle);',
    'long nativeDraw(long handle, Surface surface, int width, int height)':
        'return Bridge.draw(handle, surface, width, height);',
    'void nativeReset(long handle, boolean detach)': 'Bridge.reset(handle, detach);',
    'void nativeDestroy(long handle)': 'Bridge.destroy(handle);',
    'long[] nativeDiagnostics()': 'return Bridge.diagnostics();',
    'void nativeTestFailure(boolean enabled)': 'Bridge.testFailure(enabled);',
}


def main():
    if not shutil.which('javac') or not shutil.which('java'):
        raise SystemExit('JDK 11+ (javac and java) is required; Gradle/Android SDK is not used.')
    plugin = PLUGIN.read_text()
    for signature, body in JNI_MOCKS.items():
        declaration = f'private static native {signature};'
        if plugin.count(declaration) != 1:
            raise RuntimeError(f'JNI mock must match exactly one declaration: {signature}')
        plugin = plugin.replace(declaration, f'private static {signature} {{ {body} }}')
    sources = dict(SOURCES)
    sources['dev/lrdp/lrdp_native/LrdpNativePlugin.java'] = plugin
    with tempfile.TemporaryDirectory(prefix='lrdp-android-scheduler-') as temporary:
        work = Path(temporary)
        paths = []
        for relative, content in sources.items():
            path = work / 'src' / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
            paths.append(str(path))
        classes = work / 'classes'
        classes.mkdir()
        subprocess.run(['javac', '--release', '11', '-Xlint:all', '-Werror',
                        '-d', str(classes), *paths], check=True, timeout=60)
        # Empty library path prevents accidentally loading a real liblrdp on
        # the host. The constructor's capability probe is intentionally mocked.
        subprocess.run(['java', f'-Djava.library.path={work}', '-cp', str(classes),
                        'dev.lrdp.lrdp_native.IdleRegression'], check=True, timeout=30)


if __name__ == '__main__':
    main()
