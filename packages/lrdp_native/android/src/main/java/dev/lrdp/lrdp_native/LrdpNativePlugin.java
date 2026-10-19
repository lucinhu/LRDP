package dev.lrdp.lrdp_native;

import android.content.pm.ApplicationInfo;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.Build;
import android.util.Log;
import android.view.Surface;
import android.view.Choreographer;
import androidx.annotation.Keep;
import androidx.annotation.NonNull;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.view.TextureRegistry;
import java.util.HashMap;
import java.util.Map;

/**
 * Surface lifecycle stays on main; all retained native readers and EGL work
 * run on one GL handler. The network session and FreeRDP are never touched.
 */
@Keep
public final class LrdpNativePlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
  private final Handler main = new Handler(Looper.getMainLooper());
  private final Map<Long, Video> videos = new HashMap<>();
  private TextureRegistry registry;
  private MethodChannel channel;
  private HandlerThread thread;
  private Handler gl;
  private boolean attached, loaded, debug, tickScheduled;
  private final Choreographer.FrameCallback tick = new Choreographer.FrameCallback() {
    @Override
    public void doFrame(long frameTimeNanos) {
      tickScheduled = false;
      if (!attached)
        return;
      for (Video video : videos.values()) video.step(frameTimeNanos);
      scheduleTick();
    }
  };
  private void scheduleTick() {
    if (!attached || tickScheduled)
      return;
    for (Video video : videos.values()) {
      if (!video.closed && !video.failed && video.visible && video.available) {
        tickScheduled = true;
        Choreographer.getInstance().postFrameCallback(tick);
        return;
      }
    }
  }
  private static native long nativeCreate(long ticket);
  private static native long[] nativeStatus(long handle);
  private static native int nativeDraw(long handle, Surface surface, int width, int height);
  private static native void nativeReset(long handle, boolean detach);
  private static native void nativeDestroy(long handle);
  private static native long[] nativeDiagnostics();
  private static native void nativeTestFailure(boolean enabled);

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    registry = binding.getTextureRegistry();
    debug = (binding.getApplicationContext().getApplicationInfo().flags
                & ApplicationInfo.FLAG_DEBUGGABLE)
        != 0;
    try {
      System.loadLibrary("lrdp");
      long[] capability = nativeDiagnostics();
      loaded = capability != null && capability.length == 7;
    } catch (UnsatisfiedLinkError ignored) {
      loaded = false;
    }
    thread = new HandlerThread("lrdp-video");
    thread.start();
    gl = new Handler(thread.getLooper());
    channel = new MethodChannel(binding.getBinaryMessenger(), "dev.lrdp/video");
    channel.setMethodCallHandler(this);
    attached = true;
  }
  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    attached = false;
    Choreographer.getInstance().removeFrameCallback(tick);
    tickScheduled = false;
    channel.setMethodCallHandler(null);
    for (Video video : videos.values()) video.close();
    videos.clear();
    // close() abandons the Surface on main first, waking any queued EGL swap.
    // Native deletion is queued after pending draw work; never join GL on main.
    final HandlerThread retiring = thread;
    gl.post(retiring::quitSafely);
    channel = null;
    registry = null;
  }
  private final class Video implements TextureRegistry.SurfaceProducer.Callback {
    final TextureRegistry.SurfaceProducer producer;
    final long id;
    volatile boolean closed, visible = true, available = true;
    boolean queued, failed, loggedFirstFrame;
    long handle; // GL handler only.
    int width, height, retries;
    int frameRate = 60;
    long nextFrameNanos;
    long presentedGeneration = -1;
    Surface rateSurface;
    int surfaceFrameRate;
    int surfaceEpoch;
    Map<String, Object> status = new HashMap<>();
    Video(long ticket) {
      producer = registry.createSurfaceProducer();
      id = producer.id();
      try {
        producer.setSize(1, 1);
        producer.getSurface();
        producer.setCallback(this);
      } catch (RuntimeException exception) {
        try {
          producer.release();
        } catch (RuntimeException ignored) {
        }
        throw exception;
      }
      update(new long[] {0, 0, 0, 0, 0});
      gl.post(() -> {
        if (closed)
          return;
        handle = nativeCreate(ticket);
        if (handle == 0)
          main.post(() -> failed = true);
      });
    }
    void update(long[] data) {
      width = (int) data[0];
      height = (int) data[1];
      failed |= data[4] != 0;
      status.put("id", id);
      status.put("width", width);
      status.put("height", height);
      if (data[3] > 0 && !loggedFirstFrame) {
        loggedFirstFrame = true;
        Log.i("LRDP-video", "Native frame " + width + "x" + height);
      }
      status.put("generation", data[2]);
      status.put("uploads", data[3]);
      status.put("failed", failed);
      status.put("frameRate", frameRate);
    }
    void frameRate(int value) {
      frameRate = Math.max(1, Math.min(240, value));
      nextFrameNanos = 0;
      scheduleTick();
    }
    void step(long now) {
      if (queued || closed || !visible || !available || failed)
        return;
      if (now + 500000 < nextFrameNanos)
        return;
      long interval = 1000000000L / frameRate;
      if (nextFrameNanos == 0 || now - nextFrameNanos > interval)
        nextFrameNanos = now;
      nextFrameNanos += interval;
      queued = true;
      gl.post(() -> {
        if (closed || handle == 0) {
          main.post(() -> {
            queued = false;
            failed = true;
          });
          return;
        }
        final long[] info = nativeStatus(handle);
        main.post(() -> {
          if (closed)
            return;
          if (info == null) {
            queued = false;
            failed = true;
            return;
          }
          update(info);
          if (failed || !visible || !available || width < 1 || height < 1) {
            queued = false;
            return;
          }
          if (info[2] == presentedGeneration && surfaceFrameRate == frameRate) {
            queued = false;
            return;
          }
          try {
            producer.setSize(width, height);
            final Surface surface = producer.getSurface();
            if (Build.VERSION.SDK_INT >= 30 && (rateSurface != surface || surfaceFrameRate != frameRate)) {
              try {
                surface.setFrameRate(frameRate, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT);
              } catch (RuntimeException ignored) { /* Refresh hints are optional. */ }
              rateSurface = surface;
              surfaceFrameRate = frameRate;
            }
            final int w = width, h = height;
            final int epoch = surfaceEpoch;
            gl.post(() -> {
              if (closed || !visible || !available) {
                main.post(() -> queued = false);
                return;
              }
              final int result = nativeDraw(handle, surface, w, h);
              main.post(() -> {
                queued = false;
                if (closed || !visible || !available || epoch != surfaceEpoch)
                  return;
                if (result == -3 && ++retries >= 30)
                  failed = true;
                else if (result >= 0)
                  retries = 0;
                if (result > 0)
                  presentedGeneration = info[2];
              });
            });
          } catch (RuntimeException exception) {
            queued = false;
            failed = true;
          }
        });
      });
    }
    Map<String, Object> snapshot() {
      Map<String, Object> value = new HashMap<>(status);
      value.put("failed", failed);
      value.put("frameRate", frameRate);
      return value;
    }
    void visibility(boolean value) {
      visible = value;
      nextFrameNanos = 0;
      if (value)
        presentedGeneration = -1;
      if (value)
        surfaceEpoch++;
      if (value)
        scheduleTick();
      if (value)
        gl.post(() -> {
          if (!closed && handle != 0)
            nativeReset(handle, false);
        });
    }
    @Override
    public void onSurfaceCleanup() {
      available = false;
      rateSurface = null;
      presentedGeneration = -1;
      surfaceEpoch++;
      gl.post(() -> {
        if (!closed && handle != 0)
          nativeReset(handle, true);
      });
    }
    @Override
    public void onSurfaceAvailable() {
      available = true;
      presentedGeneration = -1;
      surfaceEpoch++;
      scheduleTick();
      gl.post(() -> {
        if (!closed && handle != 0)
          nativeReset(handle, false);
      });
    }
    void close() {
      if (closed)
        return;
      closed = true;
      try {
        producer.setCallback(null);
        producer.release();
      } catch (RuntimeException ignored) { /* Engine may already have released its Surface. */
      }
      gl.post(() -> {
        if (handle != 0) {
          nativeDestroy(handle);
          handle = 0;
        }
      });
    }
  }
  private void unavailable(MethodChannel.Result result) {
    result.error("video-unavailable", "Native video unavailable", null);
  }
  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    if (!loaded || !attached) {
      unavailable(result);
      return;
    }
    if (call.method.equals("diagnostics")) {
      final int registered = videos.size(), scheduled = tickScheduled ? 1 : 0;
      gl.post(() -> {
        long[] data = nativeDiagnostics();
        Map<String, Object> value = new HashMap<>();
        value.put("registered", registered);
        value.put("scheduledTicks", scheduled);
        String[] names = {"objects", "contexts", "surfaces", "gpuTextures", "uploadFailures",
            "presentedFrames", "cleanupFailures"};
        for (int i = 0; i < names.length; i++) value.put(names[i], data[i]);
        main.post(() -> result.success(value));
      });
      return;
    }
    if (call.method.equals("testFailUploads") && debug) {
      final boolean enabled = Boolean.TRUE.equals(call.argument("enabled"));
      gl.post(() -> {
        nativeTestFailure(enabled);
        main.post(() -> result.success(null));
      });
      return;
    }
    Number number = call.argument(call.method.equals("create") ? "ticket" : "id");
    if (number == null || number.longValue() < 0) {
      unavailable(result);
      return;
    }
    long id = number.longValue();
    if (call.method.equals("create")) {
      if (id == 0) {
        unavailable(result);
        return;
      }
      Video video = null;
      try {
        video = new Video(id);
        Number requestedRate = call.argument("frameRate");
        if (requestedRate != null)
          video.frameRate(requestedRate.intValue());
        videos.put(video.id, video);
        scheduleTick();
        result.success(video.snapshot());
      } catch (RuntimeException | UnsatisfiedLinkError exception) {
        if (video != null)
          video.close();
        unavailable(result);
      }
      return;
    }
    Video video = videos.get(id);
    if (call.method.equals("dispose")) {
      if (video != null) {
        videos.remove(id);
        video.close();
      }
      result.success(null);
      return;
    }
    if (video == null) {
      unavailable(result);
      return;
    }
    switch (call.method) {
      case "testRecreateSurface":
        if (!debug) {
          result.notImplemented();
          break;
        }
        video.producer.setSize(video.width + 1, video.height + 1);
        video.producer.getSurface();
        video.producer.setSize(Math.max(1, video.width), Math.max(1, video.height));
        video.producer.getSurface();
        gl.post(() -> {
          if (!video.closed && video.handle != 0)
            nativeReset(video.handle, true);
        });
        result.success(null);
        break;
      case "status":
        result.success(video.snapshot());
        break;
      case "visible":
        video.visibility(Boolean.TRUE.equals(call.argument("visible")));
        result.success(null);
        break;
      case "frameRate":
        Number rate = call.argument("frameRate");
        if (rate == null || rate.intValue() < 1 || rate.intValue() > 240) {
          result.error("invalid-rate", "Invalid frame rate", null);
        } else {
          video.frameRate(rate.intValue());
          result.success(null);
        }
        break;
      default:
        result.notImplemented();
    }
  }
}
