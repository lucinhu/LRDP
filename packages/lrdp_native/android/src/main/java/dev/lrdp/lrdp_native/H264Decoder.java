package dev.lrdp.lrdp_native;

import android.graphics.ImageFormat;
import android.graphics.Rect;
import android.media.Image;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.os.Build;
import android.os.SystemClock;
import androidx.annotation.Keep;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

/** Synchronous connection-thread decoder. No Surface or Android main-loop work. */
@Keep
public final class H264Decoder {
  private static final String AVC = "video/avc";
  private static final long DECODE_NANOS = 200_000_000L;
  // Live Java leases, plus cumulative Frames returned to JNI (not native copy acceptance).
  private static final AtomicLong activeDecoders = new AtomicLong();
  private static final AtomicLong activeImages = new AtomicLong();
  private static final AtomicLong decodedFrames = new AtomicLong();
  private static volatile String selectedCodec;
  private static volatile DecodeFailure lastFailure;

  private static final class DecodeFailure {
    final String stage, exceptionClass;
    final long elapsedUs, inputPTS, outputPTS;

    DecodeFailure(String stage, RuntimeException exception, long elapsedUs,
        long inputPTS, long outputPTS) {
      this.stage = stage;
      this.exceptionClass = exception == null ? null : exception.getClass().getName();
      this.elapsedUs = elapsedUs;
      this.inputPTS = inputPTS;
      this.outputPTS = outputPTS;
    }
  }
  private final List<MediaCodecInfo> candidates;
  private int candidate = -1;
  private MediaCodec codec;
  private boolean configured, failed, closed;
  private int width, height;
  private Image image;
  private int outputIndex = -1;
  private long failureAtNanos;

  // Optional registration: an older liblrdp may not export this entry point.
  public static native void nativeInitialize();

  private H264Decoder(List<MediaCodecInfo> candidates) {
    this.candidates = candidates;
  }

  // Neither symbol exists in a default/Release library. The C hook also rejects
  // changes while a native decoder is alive; only the Debug-app channel calls it.
  static native boolean nativeSetTestCodec(String name);
  private static native String nativeTestCodec();

  public static H264Decoder create() {
    return create(candidates(false, null));
  }

  public static H264Decoder createForTest(String name) {
    if (name == null)
      return null;
    try {
      // C owns the override, behind its compile-time test macro. No Java flag or
      // normal factory can turn this into a production software candidate.
      if (!name.equals(nativeTestCodec()))
        return null;
    } catch (LinkageError | RuntimeException ignored) {
      return null;
    }
    return create(candidates(true, name));
  }

  private static H264Decoder create(List<MediaCodecInfo> candidates) {
    H264Decoder decoder = new H264Decoder(candidates);
    return decoder.next() ? decoder : null;
  }

  private static List<MediaCodecInfo> candidates(boolean software, String name) {
    List<MediaCodecInfo> candidates = new ArrayList<>();
    // Older releases cannot reliably distinguish vendor software codecs from
    // hardware. Prefer the established CPU decoder rather than report a guess.
    if (Build.VERSION.SDK_INT < 29)
      return candidates;
    try {
      for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
        try {
          if (info.isEncoder() || (name != null && !name.equals(info.getName()))
              || (software ? !info.isSoftwareOnly() || info.isHardwareAccelerated()
                           : !info.isHardwareAccelerated() || info.isSoftwareOnly()))
            continue;
          for (String type : info.getSupportedTypes()) {
            if (AVC.equalsIgnoreCase(type)) {
              MediaCodecInfo.CodecCapabilities caps = info.getCapabilitiesForType(type);
              for (int color : caps.colorFormats) {
                if (color == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible) {
                  candidates.add(info);
                  break;
                }
              }
              break;
            }
          }
        } catch (RuntimeException ignored) { /* An unusable candidate is CPU fallback. */ }
      }
    } catch (RuntimeException ignored) { /* No usable list means CPU fallback. */ }
    return candidates;
  }

  private static List<Map<String, Object>> metadata(boolean software) {
    List<Map<String, Object>> values = new ArrayList<>();
    for (MediaCodecInfo info : candidates(software, null)) {
      Map<String, Object> value = new HashMap<>();
      value.put("name", info.getName());
      value.put("isHardwareAccelerated", !software);
      value.put("isSoftwareOnly", software);
      values.add(value);
    }
    return values;
  }

  private static void testStatus(Map<String, Object> value, boolean debug) {
    boolean enabled = false;
    String name = null;
    if (debug) {
      try { name = nativeTestCodec(); enabled = true; }
      catch (LinkageError | RuntimeException ignored) { /* Default library: unsupported. */ }
    }
    value.put("testHooksEnabled", enabled);
    value.put("testSoftwareCodec", name != null);
  }

  static Map<String, Object> capabilities(boolean debug) {
    Map<String, Object> value = new HashMap<>();
    value.put("api", Build.VERSION.SDK_INT);
    value.put("hardwareCandidates", metadata(false));
    value.put("softwareCandidates", metadata(true));
    testStatus(value, debug);
    return value; // Candidate metadata is not proof of a successfully decoded frame.
  }

  static Map<String, Object> diagnostics(boolean debug) {
    Map<String, Object> value = new HashMap<>();
    value.put("activeDecoders", activeDecoders.get());
    value.put("activeImages", activeImages.get());
    value.put("decodedFrames", decodedFrames.get());
    value.put("selectedCodec", selectedCodec);
    if (debug) {
      DecodeFailure failure = lastFailure;
      value.put("lastFailureStage", failure == null ? null : failure.stage);
      value.put("exceptionClass", failure == null ? null : failure.exceptionClass);
      value.put("elapsedUs", failure == null ? 0L : failure.elapsedUs);
      value.put("inputPTS", failure == null ? -1L : failure.inputPTS);
      value.put("outputPTS", failure == null ? -1L : failure.outputPTS);
    }
    testStatus(value, debug);
    return value;
  }

  /** Advance only after native requests failover; create() already selects the first codec. */
  public boolean next() {
    closeCodec();
    if (closed)
      return false;
    while (++candidate < candidates.size()) {
      try {
        String name = candidates.get(candidate).getName();
        codec = MediaCodec.createByCodecName(name);
        activeDecoders.incrementAndGet();
        selectedCodec = name;
        failed = false;
        return true;
      } catch (IOException | RuntimeException ignored) {
        closeCodec();
      }
    }
    return false;
  }

  private void configure(ByteBuffer packet, int w, int h) {
    MediaCodecInfo.CodecCapabilities caps =
        candidates.get(candidate).getCapabilitiesForType(AVC);
    MediaCodecInfo.VideoCapabilities video = caps.getVideoCapabilities();
    if (video == null || !video.isSizeSupported(w, h))
      throw new IllegalArgumentException("Unsupported AVC dimensions");
    MediaFormat format = MediaFormat.createVideoFormat(AVC, w, h);
    format.setInteger(MediaFormat.KEY_COLOR_FORMAT,
        MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible);
    if (Build.VERSION.SDK_INT >= 30
        && caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency))
      format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
    ByteBuffer sps = parameterSets(packet, 7), pps = parameterSets(packet, 8);
    if (sps != null)
      format.setByteBuffer("csd-0", sps);
    if (pps != null)
      format.setByteBuffer("csd-1", pps);
    codec.configure(format, null, null, 0);
    codec.start();
    width = w;
    height = h;
    configured = true;
  }

  private static int startCode(ByteBuffer packet, int from) {
    for (int i = from; i + 2 < packet.limit(); i++) {
      if (packet.get(i) == 0 && packet.get(i + 1) == 0
          && (packet.get(i + 2) == 1 || (i + 3 < packet.limit()
              && packet.get(i + 2) == 0 && packet.get(i + 3) == 1)))
        return i;
    }
    return -1;
  }

  /** Collect every SPS/PPS NAL, preserving the caller's packet position. */
  private static ByteBuffer parameterSets(ByteBuffer packet, int type) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    int start = startCode(packet, packet.position());
    while (start >= 0) {
      int nal = start + (packet.get(start + 2) == 1 ? 3 : 4);
      int next = startCode(packet, nal);
      int end = next < 0 ? packet.limit() : next;
      if (nal < end && (packet.get(nal) & 31) == type) {
        out.write(0); out.write(0); out.write(0); out.write(1);
        for (int i = nal; i < end; i++) out.write(packet.get(i));
      }
      start = next;
    }
    return out.size() == 0 ? null : ByteBuffer.wrap(out.toByteArray());
  }

  private static long remainingUs(long deadline) {
    return Math.max(0, (deadline - SystemClock.elapsedRealtimeNanos()) / 1000);
  }

  /** Return only the Image for this exact AU; a pending frame is never success. */
  public Frame decode(ByteBuffer packet, long token, int w, int h) {
    final long started = SystemClock.elapsedRealtimeNanos();
    final long deadline = started + DECODE_NANOS;
    String stage = "validate";
    RuntimeException failureException = null;
    long inputPTS = -1L, outputPTS = -1L;
    boolean returnedFrame = false;
    releaseFrame();
    try {
      if (closed || failed || codec == null || packet == null || !packet.isDirect()
          || !packet.hasRemaining() || token <= 0 || w <= 0 || h <= 0)
        return failure();
      stage = "size-change";
      if (configured && (width != w || height != h))
        return failure(); // Native replays the AU on its CPU decoder.
      if (!configured) {
        stage = "configure";
        configure(packet, w, h);
      }
      stage = "input-wait";
      int input = -1;
      while (input < 0) {
        long wait = remainingUs(deadline);
        if (wait == 0)
          return failure();
        input = codec.dequeueInputBuffer(wait);
      }
      if (remainingUs(deadline) == 0)
        return failure();
      stage = "input-buffer";
      ByteBuffer buffer = codec.getInputBuffer(input);
      if (buffer == null)
        return failure();
      buffer.clear();
      if (buffer.remaining() < packet.remaining())
        return failure();
      int size = packet.remaining();
      buffer.put(packet.duplicate());
      stage = "input-queue";
      codec.queueInputBuffer(input, 0, size, token, 0);
      inputPTS = token;
      MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
      while (true) {
        stage = "output-wait";
        long wait = remainingUs(deadline);
        if (wait == 0)
          return failure();
        int output = codec.dequeueOutputBuffer(info, wait);
        if (output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
          stage = "output-format";
          codec.getOutputFormat();
          continue;
        }
        if (output < 0)
          continue;
        outputIndex = output;
        outputPTS = info.presentationTimeUs;
        stage = "output-metadata";
        if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
          releaseFrame();
          if (failed) return failure();
          continue;
        }
        if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
            || info.presentationTimeUs > token)
          return failure();
        if (info.presentationTimeUs != token) {
          releaseFrame(); // Discard stale output without lending it to AVC444.
          if (failed) return failure();
          continue;
        }
        stage = "output-image";
        image = codec.getOutputImage(output);
        if (image != null)
          activeImages.incrementAndGet();
        if (image == null || image.getFormat() != ImageFormat.YUV_420_888)
          return failure();
        stage = "output-planes";
        Frame frame = new Frame(image);
        stage = "output-validate";
        if (frame.width != w || frame.height != h || remainingUs(deadline) == 0)
          return failure();
        decodedFrames.incrementAndGet();
        returnedFrame = true;
        return frame;
      }
    } catch (RuntimeException exception) {
      failureException = exception;
      return failure();
    } finally {
      if (!returnedFrame) {
        // Report time at failure, excluding stop/release; retain no packets or exceptions.
        lastFailure = new DecodeFailure(stage, failureException,
            Math.max(0L, (failureAtNanos - started) / 1000), inputPTS, outputPTS);
      }
    }
  }

  private Frame failure() {
    failureAtNanos = SystemClock.elapsedRealtimeNanos();
    closeCodec();
    failed = true;
    return null;
  }

  /** Native copies the slices before calling this; safe on every failure path. */
  public void releaseFrame() {
    Image old = image;
    int index = outputIndex;
    image = null;
    outputIndex = -1;
    if (old != null) {
      try { old.close(); } catch (RuntimeException ignored) { failed = true; }
      finally { activeImages.decrementAndGet(); }
    }
    if (codec != null && index >= 0) {
      try { codec.releaseOutputBuffer(index, false); }
      catch (RuntimeException ignored) { failed = true; }
    }
  }

  private void closeCodec() {
    releaseFrame();
    MediaCodec old = codec;
    codec = null;
    configured = false;
    if (old != null) {
      try { old.stop(); } catch (RuntimeException ignored) { /* May not have started. */ }
      try { old.release(); } catch (RuntimeException ignored) { /* Best effort after codec failure. */ }
      finally { activeDecoders.decrementAndGet(); }
    }
  }

  public void close() {
    closed = true;
    closeCodec();
  }

  @Keep
  public static final class Frame {
    public final ByteBuffer y, u, v;
    public final int yRowStride, uRowStride, vRowStride;
    public final int yPixelStride, uPixelStride, vPixelStride;
    public final int width, height, cropLeft, cropTop;

    private Frame(Image image) {
      Image.Plane[] planes = image.getPlanes();
      if (planes.length != 3)
        throw new IllegalArgumentException("Expected three YUV420 planes");
      y = planes[0].getBuffer().slice();
      u = planes[1].getBuffer().slice();
      v = planes[2].getBuffer().slice();
      if (!y.isDirect() || !u.isDirect() || !v.isDirect())
        throw new IllegalArgumentException("Expected direct YUV420 planes");
      yRowStride = planes[0].getRowStride();
      uRowStride = planes[1].getRowStride();
      vRowStride = planes[2].getRowStride();
      yPixelStride = planes[0].getPixelStride();
      uPixelStride = planes[1].getPixelStride();
      vPixelStride = planes[2].getPixelStride();
      Rect crop = image.getCropRect();
      cropLeft = crop.left;
      cropTop = crop.top;
      width = crop.width();
      height = crop.height();
    }
  }
}
