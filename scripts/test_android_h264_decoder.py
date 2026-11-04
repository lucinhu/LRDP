#!/usr/bin/env python3
"""Host Java regression for H264Decoder; requires Python and JDK 11+, no Gradle.

Compiles the production class unchanged with deterministic MediaCodec/Image
mocks and a monotonic virtual clock. A second run mocks ONLY the native test
symbols to exercise the software-test factory. This validates selection,
PTS/deadline and ownership logic, NOT device codec support, JNI, EGL or pixels.
All generated files live in an automatically removed temporary directory.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
DECODER = ROOT / ('packages/lrdp_native/android/src/main/java/'
                  'dev/lrdp/lrdp_native/H264Decoder.java')
SOURCES = {
    'androidx/annotation/Keep.java': 'package androidx.annotation; public @interface Keep {}',
    'android/os/Build.java': '''package android.os;
public class Build { public static class VERSION { public static int SDK_INT = 29; } }''',
    'android/os/SystemClock.java': '''package android.os;
public class SystemClock {
  public static long now;
  public static long elapsedRealtimeNanos() { return now; }
}''',
    'android/graphics/ImageFormat.java': '''package android.graphics;
public class ImageFormat { public static final int YUV_420_888 = 35; }''',
    'android/graphics/Rect.java': '''package android.graphics;
public class Rect {
  public int left, top, right, bottom;
  public Rect(int l, int t, int r, int b) { left=l; top=t; right=r; bottom=b; }
  public int width() { return right-left; } public int height() { return bottom-top; }
}''',
    'android/media/MediaFormat.java': '''package android.media;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;
public class MediaFormat {
  public static final String KEY_COLOR_FORMAT = "color-format", KEY_LOW_LATENCY = "low-latency";
  public final Map<String, Object> values = new HashMap<>();
  public static MediaFormat createVideoFormat(String mime, int w, int h) {
    MediaFormat f=new MediaFormat(); f.values.put("mime",mime); f.values.put("width",w);
    f.values.put("height",h); return f;
  }
  public void setInteger(String key, int v) { values.put(key,v); }
  public void setByteBuffer(String key, ByteBuffer v) { values.put(key,v); }
}''',
    'android/media/MediaCodecInfo.java': '''package android.media;
public class MediaCodecInfo {
  public final String name;
  public boolean encoder, hardware=true, software, avc=true, failCaps;
  public final CodecCapabilities caps = new CodecCapabilities();
  public MediaCodecInfo(String n) { name=n; }
  public String getName() { return name; }
  public boolean isEncoder() { return encoder; }
  public boolean isHardwareAccelerated() { return hardware; }
  public boolean isSoftwareOnly() { return software; }
  public String[] getSupportedTypes() { return new String[]{avc ? "video/avc" : "video/hevc"}; }
  public CodecCapabilities getCapabilitiesForType(String mime) {
    if (failCaps) throw new IllegalArgumentException("bad caps"); return caps;
  }
  public static class CodecCapabilities {
    public static final int COLOR_FormatYUV420Flexible = 0x7f420888;
    public static final String FEATURE_LowLatency = "low-latency";
    public boolean lowLatency;
    public boolean isFeatureSupported(String name) {
      if (android.os.Build.VERSION.SDK_INT<30) throw new AssertionError("API30 feature on old API");
      return lowLatency;
    }
    public int[] colorFormats = {COLOR_FormatYUV420Flexible};
    public final VideoCapabilities video = new VideoCapabilities();
    public VideoCapabilities getVideoCapabilities() { return video; }
  }
  public static class VideoCapabilities {
    public boolean supported=true;
    public boolean isSizeSupported(int w, int h) { return supported && w>0 && h>0; }
  }
}''',
    'android/media/MediaCodecList.java': '''package android.media;
public class MediaCodecList {
  public static final int REGULAR_CODECS = 0;
  public static MediaCodecInfo[] infos;
  public static int enumerations;
  public static boolean fail;
  public MediaCodecList(int kind) { enumerations++; }
  public MediaCodecInfo[] getCodecInfos() {
    if (fail) throw new IllegalStateException("list failure"); return infos;
  }
}''',
    'android/media/Image.java': '''package android.media;
import android.graphics.*;
import java.nio.ByteBuffer;
public class Image {
  public int closes, format=ImageFormat.YUV_420_888;
  public boolean closeFails;
  public Rect crop = new Rect(2,2,6,6);
  public Plane[] planes = {new Plane(1), new Plane(2), new Plane(2)};
  public int getFormat() { return format; }
  public Rect getCropRect() { return crop; }
  public Plane[] getPlanes() { return planes; }
  public void close() { closes++; if(closeFails) throw new IllegalStateException("close"); }
  public static class Plane {
    public ByteBuffer buffer=ByteBuffer.allocateDirect(40);
    private final int pixel;
    public Plane(int p) { pixel=p; buffer.put(3,(byte)23); buffer.position(3); buffer.limit(31); }
    public ByteBuffer getBuffer() { return buffer; }
    public int getRowStride() { return 8; }
    public int getPixelStride() { return pixel; }
  }
}''',
    'android/media/MediaCodec.java': '''package android.media;
import android.os.SystemClock;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.*;
public class MediaCodec {
  public static final int INFO_TRY_AGAIN_LATER=-1, INFO_OUTPUT_FORMAT_CHANGED=-2;
  public static final int BUFFER_FLAG_CODEC_CONFIG=2, BUFFER_FLAG_END_OF_STREAM=4;
  public static final Map<String, Plan> plans = new HashMap<>();
  public static final List<MediaCodec> instances = new ArrayList<>();
  public static class BufferInfo { public long presentationTimeUs; public int flags; }
  public static class Event {
    public final int index; public final long pts; public int flags; public long delayUs;
    public Image image = new Image();
    public Event(int index, long pts) { this.index=index; this.pts=pts; }
  }
  public static class Plan {
    public String failAt="";
    public long configureUs, inputUs;
    public boolean noOutput, nullInput, smallInput, stopFails, releaseOutputFails;
    public final ArrayDeque<Event> events = new ArrayDeque<>();
    public Image defaultImage = new Image();
  }
  public final String name;
  public final Plan plan;
  public MediaFormat format;
  public int starts, stops, releases, outputReleases, imageGets, queues;
  public long pts, inputTimeoutUs, outputTimeoutUs;
  public final Map<Integer, Event> outputs = new HashMap<>();
  private MediaCodec(String n, Plan p) { name=n; plan=p; }
  private void fail(String stage) { if(plan.failAt.equals(stage)) throw new IllegalStateException(stage); }
  public static MediaCodec createByCodecName(String name) throws IOException {
    Plan p=plans.computeIfAbsent(name, n -> new Plan());
    if(p.failAt.equals("create")) throw new IOException("create");
    MediaCodec c=new MediaCodec(name,p); instances.add(c); return c;
  }
  public void configure(MediaFormat f, Object surface, Object crypto, int flags) {
    if(surface!=null) throw new AssertionError("decoder must have no Surface");
    format=f; SystemClock.now+=plan.configureUs*1000; fail("configure");
  }
  public void start() { starts++; fail("start"); }
  public int dequeueInputBuffer(long timeout) {
    fail("input"); inputTimeoutUs=timeout;
    long elapsed=Math.min(timeout,plan.inputUs); plan.inputUs-=elapsed; SystemClock.now+=elapsed*1000;
    return plan.inputUs>0 ? -1 : 0;
  }
  public ByteBuffer getInputBuffer(int index) {
    fail("inputBuffer"); return plan.nullInput ? null : ByteBuffer.allocate(plan.smallInput ? 1 : 1024);
  }
  public void queueInputBuffer(int i, int offset, int size, long token, int flags) {
    queues++; pts=token; fail("queue");
  }
  public int dequeueOutputBuffer(BufferInfo info, long timeout) {
    fail("output"); outputTimeoutUs=timeout;
    Event e=plan.events.poll();
    if(e==null && plan.noOutput) { SystemClock.now+=timeout*1000; return -1; }
    if(e==null) { e=new Event(9,pts); e.image=plan.defaultImage; }
    SystemClock.now+=e.delayUs*1000;
    if(e.index<0) return e.index;
    info.presentationTimeUs=e.pts==Long.MIN_VALUE ? pts : e.pts; info.flags=e.flags;
    outputs.put(e.index,e); return e.index;
  }
  public MediaFormat getOutputFormat() { fail("format"); return format; }
  public Image getOutputImage(int index) { imageGets++; fail("image"); return outputs.get(index).image; }
  public void releaseOutputBuffer(int index, boolean render) {
    outputReleases++; outputs.remove(index);
    if(render) throw new AssertionError("must not render");
    if(plan.releaseOutputFails) throw new IllegalStateException("release output");
  }
  public void stop() { stops++; if(plan.stopFails) throw new IllegalStateException("stop"); }
  public void release() { releases++; outputs.clear(); }
}''',
    'dev/lrdp/lrdp_native/H264Regression.java': '''package dev.lrdp.lrdp_native;
import android.media.*;
import android.os.*;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
public class H264Regression {
  static int assertions;
  static void check(boolean ok, String why) { assertions++; if(!ok) throw new AssertionError(why); }
  static void equal(long want, long got, String why) { check(want==got,why+": "+want+" != "+got); }
  static MediaCodecInfo fresh(String...names) {
    equal(0,metric("activeDecoders"),"prior case leaves no codec lease");
    equal(0,metric("activeImages"),"prior case leaves no image lease");
    Build.VERSION.SDK_INT=29; SystemClock.now=0;
    MediaCodec.instances.clear(); MediaCodec.plans.clear();
    MediaCodecList.fail=false; MediaCodecList.enumerations=0;
    MediaCodecList.infos=Arrays.stream(names).map(MediaCodecInfo::new).toArray(MediaCodecInfo[]::new);
    return MediaCodecList.infos.length==0 ? null : MediaCodecList.infos[0];
  }
  static MediaCodec last() { return MediaCodec.instances.get(MediaCodec.instances.size()-1); }
  static ByteBuffer packet() {
    byte[] bytes={99,99,0,0,1,0x67,1,0,0,0,1,0x67,2,0,0,1,0x68,3,0,0,1,0x65,4};
    ByteBuffer b=ByteBuffer.allocateDirect(bytes.length); b.put(bytes); b.flip(); b.position(2); return b;
  }
  static H264Decoder.Frame decode(H264Decoder d) { return d.decode(packet(), 123,4,4); }
  static long metric(String name) { return ((Number)H264Decoder.diagnostics(false).get(name)).longValue(); }
  static void noResources(MediaCodec c, String why) {
    equal(1,c.releases,why+" codec released"); equal(0,c.outputs.size(),why+" no output lease");
  }
  static void selection() {
    for(int api:new int[]{24,26,28}) {
      fresh("vendor"); Build.VERSION.SDK_INT=api;
      check(H264Decoder.create()==null,"old API fallback");
      equal(0,MediaCodecList.enumerations,"old API avoids unverifiable hardware query");
    }
    fresh("encoder","software","unknown","both","wrongmime","noflex","badcaps","first","second");
    MediaCodecInfo[] a=MediaCodecList.infos;
    a[0].encoder=true; a[1].software=true; a[1].hardware=false; a[2].hardware=false;
    a[3].software=true; a[4].avc=false; a[5].caps.colorFormats=new int[]{1}; a[6].failCaps=true;
    H264Decoder d=H264Decoder.create(); check(d!=null,"hardware selected");
    check(last().name.equals("first"),"create selects first eligible, not second");
    MediaCodec c=last(); equal(0,c.starts,"configuration deferred");
    check(d.next(),"next candidate"); noResources(c,"advance");
    check(last().name.equals("second"),"next advances once"); c=last();
    check(!d.next(),"exhaustion"); noResources(c,"exhaustion"); d.close();
    fresh("first","second"); MediaCodec.Plan p=new MediaCodec.Plan(); p.failAt="create";
    MediaCodec.plans.put("first",p); d=H264Decoder.create();
    check(last().name.equals("second"),"creation failure skips candidate"); d.close();
    fresh(); check(H264Decoder.create()==null,"empty list fallback");
    fresh("soft").software=true; check(H264Decoder.create()==null,"software fallback");
    fresh("x"); MediaCodecList.fail=true; check(H264Decoder.create()==null,"list failure fallback");
  }
  static void exactFrameAndCsd() {
    fresh("a"); H264Decoder d=H264Decoder.create(); MediaCodec c=last();
    MediaCodec.Event changed=new MediaCodec.Event(-2,0);
    MediaCodec.Event config=new MediaCodec.Event(1,123); config.flags=MediaCodec.BUFFER_FLAG_CODEC_CONFIG;
    MediaCodec.Event stale=new MediaCodec.Event(2,122), current=new MediaCodec.Event(3,123);
    c.plan.events.addAll(Arrays.asList(changed,config,stale,current));
    ByteBuffer packet=packet(); int position=packet.position();
    H264Decoder.Frame f=d.decode(packet,123,4,4);
    check(f!=null,"exact token returns image after format/stale/config output");
    equal(position,packet.position(),"packet position unchanged");
    equal(123,c.pts,"unique JNI token passed unchanged as pts");
    equal(1,c.imageGets,"only exact current output acquires Image");
    equal(2,c.outputReleases,"stale/config output released");
    equal(0,current.image.closes,"current Image retained until native copy finishes");
    equal(0,f.y.position(),"plane slice position"); equal(28,f.y.capacity(),"plane remaining capacity");
    equal(23,f.y.get(0),"plane slice starts at position without crop applied twice");
    check(f.y.isDirect()&&f.u.isDirect()&&f.v.isDirect(),"direct planes");
    equal(8,f.yRowStride,"row stride"); equal(2,f.uPixelStride,"interleaved chroma stride");
    equal(4,f.width,"crop width"); equal(4,f.height,"crop height");
    equal(2,f.cropLeft,"crop left retained"); equal(2,f.cropTop,"crop top retained");
    equal(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
        (Integer)c.format.values.get(MediaFormat.KEY_COLOR_FORMAT),"flexible YUV requested");
    ByteBuffer sps=(ByteBuffer)c.format.values.get("csd-0"), pps=(ByteBuffer)c.format.values.get("csd-1");
    byte[] expected={0,0,0,1,0x67,1,0,0,0,1,0x67,2}, got=new byte[sps.remaining()]; sps.get(got);
    check(Arrays.equals(expected,got),"all SPS NALs collected with canonical start codes");
    equal(6,pps.remaining(),"PPS csd");
    d.releaseFrame(); d.releaseFrame();
    equal(1,current.image.closes,"Image closed once"); equal(3,c.outputReleases,"output released once");
    d.close(); d.close(); noResources(c,"normal close");
    check(decode(d)==null&&!d.next(),"closed decoder cannot restart");
  }
  static void deadlinesAndTokens() {
    fresh("a"); H264Decoder d=H264Decoder.create(); MediaCodec c=last();
    c.plan.configureUs=30000; c.plan.inputUs=110000; c.plan.noOutput=true;
    check(decode(d)==null,"timeout is failure, never pending success");
    equal(170000,c.inputTimeoutUs,"input uses budget left after configure");
    equal(60000,c.outputTimeoutUs,"output shares remaining input/configure budget");
    equal(200000000,SystemClock.now,"one total monotonic deadline"); noResources(c,"timeout");
    d.releaseFrame(); d.close(); noResources(c,"timeout repeated cleanup");
    fresh("a"); d=H264Decoder.create(); c=last(); c.plan.inputUs=300000;
    check(decode(d)==null,"input timeout"); equal(0,c.queues,"no enqueue after input deadline");
    equal(200000000,SystemClock.now,"bounded input wait"); noResources(c,"input timeout");
    fresh("a"); d=H264Decoder.create(); c=last();
    c.plan.events.add(new MediaCodec.Event(1,124));
    check(decode(d)==null,"future token cannot be borrowed");
    equal(0,c.imageGets,"future image not acquired"); equal(1,c.outputReleases,"future released");
    noResources(c,"future");
    fresh("a"); d=H264Decoder.create(); c=last(); c.plan.noOutput=true;
    c.plan.events.add(new MediaCodec.Event(1,122));
    check(decode(d)==null,"only old token then timeout is failure"); noResources(c,"stale timeout");
    fresh("a"); d=H264Decoder.create(); c=last();
    MediaCodec.Event late=new MediaCodec.Event(1,123); late.delayUs=201000;
    c.plan.events.add(late); check(decode(d)==null,"late exact Image is still timeout");
    equal(1,late.image.closes,"late image closed"); noResources(c,"late output");
  }
  static void failuresAndNext() {
    for(String stage:new String[]{"configure","start","input","inputBuffer","queue","output","image","format"}) {
      fresh("a","b"); H264Decoder d=H264Decoder.create(); MediaCodec c=last(); c.plan.failAt=stage;
      if(stage.equals("format")) c.plan.events.add(new MediaCodec.Event(-2,0));
      check(decode(d)==null,"controlled codec exception "+stage); noResources(c,stage);
      check(d.next(),"failure retains next candidate "+stage);
      check(decode(d)!=null,"next candidate recovers "+stage); d.close(); noResources(last(),"next "+stage);
    }
    fresh("a").caps.video.supported=false; H264Decoder d=H264Decoder.create(); MediaCodec c=last();
    check(decode(d)==null,"unsupported size"); equal(0,c.starts,"unsupported size not started"); noResources(c,"size");
    for(int kind=0;kind<7;kind++) {
      fresh("a"); d=H264Decoder.create(); c=last(); Image image=c.plan.defaultImage;
      if(kind==0)c.plan.defaultImage=null;
      if(kind==1)image.format=0;
      if(kind==2)image.planes=new Image.Plane[0];
      if(kind==3)image.planes[1].buffer=ByteBuffer.allocate(8);
      if(kind==4)image.crop.right=7;
      if(kind==5)c.plan.nullInput=true;
      if(kind==6)c.plan.smallInput=true;
      check(decode(d)==null,"invalid image/input failure "+kind); noResources(c,"invalid "+kind);
      if(kind>=1&&kind<=4)equal(1,image.closes,"invalid Image closed "+kind);
    }
    fresh("a"); d=H264Decoder.create(); c=last();
    check(decode(d)!=null,"frame before resize");
    check(d.decode(packet(),124,8,4)==null,"size change fails for CPU replay");
    equal(1,c.queues,"size change not fed into old codec");
    equal(1,c.plan.defaultImage.closes,"resize closes Image"); noResources(c,"resize");
    fresh("a"); d=H264Decoder.create(); c=last();
    check(decode(d)!=null,"frame before cleanup errors"); c.plan.defaultImage.closeFails=true;
    c.plan.releaseOutputFails=true; c.plan.stopFails=true;
    d.close(); noResources(c,"cleanup exceptions"); equal(1,c.outputReleases,"release attempted despite image close error");
    fresh("a"); d=H264Decoder.create(); c=last();
    check(d.decode(ByteBuffer.allocate(10),123,4,4)==null,"non-direct packet rejected"); noResources(c,"packet");
  }
  static void metadataAndCounters() {
    fresh("hard","soft"); MediaCodecList.infos[1].hardware=false; MediaCodecList.infos[1].software=true;
    Map<String,Object> caps=H264Decoder.capabilities(true);
    equal(29,((Number)caps.get("api")).longValue(),"reported API");
    equal(1,((List<?>)caps.get("hardwareCandidates")).size(),"hardware metadata count");
    equal(1,((List<?>)caps.get("softwareCandidates")).size(),"software metadata count");
    equal(0,MediaCodec.instances.size(),"query does not instantiate codec");
    check(Boolean.FALSE.equals(caps.get("testHooksEnabled")),"missing macro symbols are unsupported");
    check(H264Decoder.createForTest("soft")==null,"software test factory cannot bypass missing macro");
    H264Decoder d=H264Decoder.create(); long before=metric("decodedFrames");
    equal(1,metric("activeDecoders"),"codec lease count"); equal(0,metric("activeImages"),"no image before decode");
    check(decode(d)!=null,"counter test current image");
    equal(before+1,metric("decodedFrames"),"returned Frames counted");
    equal(1,metric("activeImages"),"retained image lease");
    check("hard".equals(H264Decoder.diagnostics(true).get("selectedCodec")),"selected codec metadata");
    d.releaseFrame(); equal(0,metric("activeImages"),"image counter clears after native copy");
    d.close(); equal(0,metric("activeDecoders"),"codec counter clears at stop");
    Build.VERSION.SDK_INT=26; caps=H264Decoder.capabilities(true);
    equal(0,((List<?>)caps.get("hardwareCandidates")).size(),"old API hardware metadata conservative");
    equal(0,((List<?>)caps.get("softwareCandidates")).size(),"old API software metadata conservative");
    for(int api:new int[]{29,30,35}) for(boolean supported:new boolean[]{false,true}) {
      MediaCodecInfo info=fresh("a"); Build.VERSION.SDK_INT=api; info.caps.lowLatency=supported;
      d=H264Decoder.create(); check(decode(d)!=null,"low latency config decode");
      check(last().format.values.containsKey(MediaFormat.KEY_LOW_LATENCY)==(api>=30&&supported),
          "low latency set only when API and capability allow"); d.close();
    }
  }
  static void failureDiagnostics() {
    fresh("a"); H264Decoder d=H264Decoder.create(); last().plan.noOutput=true;
    check(decode(d)==null,"diagnostic output timeout remains failure");
    Map<String,Object> failure=H264Decoder.diagnostics(true);
    check("output-wait".equals(failure.get("lastFailureStage")),"queued AU timeout stage");
    equal(200000,((Number)failure.get("elapsedUs")).longValue(),"failure elapsed before cleanup");
    equal(123,((Number)failure.get("inputPTS")).longValue(),"queued token diagnostic");
    equal(-1,((Number)failure.get("outputPTS")).longValue(),"no output sentinel");
    check(failure.get("exceptionClass")==null,"ordinary timeout has no exception");
    fresh("a"); d=H264Decoder.create(); last().plan.configureUs=201000;
    check(decode(d)==null,"configure budget not renewed for diagnostics");
    failure=H264Decoder.diagnostics(true);
    check("input-wait".equals(failure.get("lastFailureStage")),"configure consumed budget before queue");
    equal(-1,((Number)failure.get("inputPTS")).longValue(),"never queued token sentinel");
    equal(201000,((Number)failure.get("elapsedUs")).longValue(),"configure failure wall time");
    fresh("a"); d=H264Decoder.create(); last().plan.failAt="configure";
    check(decode(d)==null,"configure exception still closes codec");
    failure=H264Decoder.diagnostics(true);
    check("configure".equals(failure.get("lastFailureStage")),"configure exception stage");
    check("java.lang.IllegalStateException".equals(failure.get("exceptionClass")),"class only without message");
    fresh("a"); d=H264Decoder.create(); last().plan.events.add(new MediaCodec.Event(1,124));
    check(decode(d)==null,"future PTS diagnostic never becomes success");
    failure=H264Decoder.diagnostics(true);
    check("output-metadata".equals(failure.get("lastFailureStage")),"future PTS rejection stage");
    equal(124,((Number)failure.get("outputPTS")).longValue(),"observed output token diagnostic");
    for(String key:new String[]{"lastFailureStage","exceptionClass","elapsedUs","inputPTS","outputPTS"})
      check(!H264Decoder.diagnostics(false).containsKey(key),"Release omits debug failure field "+key);
  }
  public static void main(String[] args) {
    selection(); exactFrameAndCsd(); deadlinesAndTokens(); failuresAndNext(); metadataAndCounters(); failureDiagnostics();
    System.out.println("PASS "+assertions+" host mock H264 assertions: hardware/API filter, exact PTS, "
        +"shared 200ms deadline, direct planes/crop/CSD, candidate failover, cleanup. Device validation separate.");
  }
}''',
    'dev/lrdp/lrdp_native/TestHook.java': '''package dev.lrdp.lrdp_native;
// Native test-symbol mock only: does NOT validate the C macro or active-instance gate.
public class TestHook {
  static String name;
  static String get() { return name; }
  static boolean set(String value) { name=value; return true; }
}''',
    'dev/lrdp/lrdp_native/TestHooksRegression.java': '''package dev.lrdp.lrdp_native;
import android.media.*;
import android.os.Build;
import static dev.lrdp.lrdp_native.H264Regression.*;
public class TestHooksRegression {
  public static void main(String[] args) {
    fresh("hard","soft","both","unknown","encoder");
    MediaCodecInfo[] a=MediaCodecList.infos;
    a[1].hardware=false; a[1].software=true;
    a[2].software=true; a[3].hardware=false; a[4].hardware=false; a[4].software=true; a[4].encoder=true;
    check(H264Decoder.createForTest("soft")==null,"no C override, no software factory");
    H264Decoder.nativeSetTestCodec("soft");
    check(Boolean.TRUE.equals(H264Decoder.capabilities(true).get("testHooksEnabled")),"macro symbol visible");
    check(Boolean.TRUE.equals(H264Decoder.diagnostics(true).get("testSoftwareCodec")),"test selection reported");
    check(Boolean.FALSE.equals(H264Decoder.capabilities(false).get("testHooksEnabled")),"Release app hides test hooks");
    H264Decoder d=H264Decoder.create(); check(last().name.equals("hard"),"normal factory stays hardware under test override");
    d.close(); d=H264Decoder.createForTest("soft");
    check(d!=null&&last().name.equals("soft"),"test factory accepts exact C-selected software codec");
    check(decode(d)!=null,"software test frame follows same exact-token path"); d.close();
    check("soft".equals(TestHook.name),"capabilities/diagnostics reads did not clear override");
    for(String name:new String[]{"hard","both","unknown","encoder","missing"}) {
      H264Decoder.nativeSetTestCodec(name);
      check(H264Decoder.createForTest(name)==null,"strict software test metadata rejects "+name);
    }
    H264Decoder.nativeSetTestCodec("soft"); Build.VERSION.SDK_INT=28;
    check(H264Decoder.createForTest("soft")==null,"test factory also rejects old API");
    H264Decoder.nativeSetTestCodec(null);
    check(Boolean.FALSE.equals(H264Decoder.diagnostics(true).get("testSoftwareCodec")),"native override cleared");
    equal(0,metric("activeDecoders"),"test codecs released"); equal(0,metric("activeImages"),"test images released");
    System.out.println("PASS "+assertions+" host mock test-hook assertions; C macro/JNI gate and device execution separate.");
  }
}''',
}


def main():
    if not shutil.which('javac') or not shutil.which('java'):
        raise SystemExit('JDK 11+ (javac and java) is required; Gradle/Android SDK is not used.')
    sources = dict(SOURCES)
    sources['dev/lrdp/lrdp_native/H264Decoder.java'] = DECODER.read_text()
    with tempfile.TemporaryDirectory(prefix='lrdp-android-h264-') as temporary:
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
        subprocess.run(['java', '-cp', str(classes), 'dev.lrdp.lrdp_native.H264Regression'],
                       check=True, timeout=30)
        decoder = sources['dev/lrdp/lrdp_native/H264Decoder.java']
        replacements = {
            'private static native String nativeTestCodec();':
                'private static String nativeTestCodec() { return TestHook.get(); }',
            'static native boolean nativeSetTestCodec(String name);':
                'static boolean nativeSetTestCodec(String name) { return TestHook.set(name); }',
        }
        for declaration, body in replacements.items():
            if decoder.count(declaration) != 1:
                raise RuntimeError(f'Test-symbol mock must match exactly once: {declaration}')
            decoder = decoder.replace(declaration, body)
        decoder_path = work / 'src/dev/lrdp/lrdp_native/H264Decoder.java'
        decoder_path.write_text(decoder)
        subprocess.run(['javac', '--release', '11', '-Xlint:all', '-Werror',
                        '-cp', str(classes), '-d', str(classes), str(decoder_path)],
                       check=True, timeout=60)
        subprocess.run(['java', '-cp', str(classes), 'dev.lrdp.lrdp_native.TestHooksRegression'],
                       check=True, timeout=30)


if __name__ == '__main__':
    main()
