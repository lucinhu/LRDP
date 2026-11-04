#include "h264_android.h"
#include "h264_image.h"
#include <jni.h>
#include <pthread.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/mem.h>

#define MAX_DIMENSION 8192
#define MAX_PACKET (16u * 1024u * 1024u)

typedef struct {
  JavaVM* vm;
  jclass decoder_class, frame_class;
  jmethodID create, next, decode, release_frame, close;
#ifdef LRDP_ANDROID_H264_TESTING
  jmethodID create_for_test;
#endif
  jfieldID planes[3], rows[3], pixels[3];
  jfieldID width, height, crop_left, crop_top;
} java_bridge;
static java_bridge bridge;
static pthread_mutex_t bridge_lock = PTHREAD_MUTEX_INITIALIZER;
#ifdef LRDP_ANDROID_H264_TESTING
/* Debug test APK only: no production environment or runtime override. Count
 * constructors too, so a test selector cannot race an in-progress create(). */
static char test_codec_name[256];
static size_t active_decoders;
static void test_decoder_finished(void) {
  pthread_mutex_lock(&bridge_lock);
  active_decoders--;
  pthread_mutex_unlock(&bridge_lock);
}
JNIEXPORT jboolean JNICALL
Java_dev_lrdp_lrdp_1native_H264Decoder_nativeSetTestCodec(JNIEnv* env, jclass klass, jstring name) {
  (void)klass;
  char selected[sizeof(test_codec_name)] = {0};
  if (name) {
    const char* text = (*env)->GetStringUTFChars(env, name, NULL);
    if (!text) {
      if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
      return JNI_FALSE;
    }
    const size_t length = strlen(text);
    if (!length || length >= sizeof(selected)) {
      (*env)->ReleaseStringUTFChars(env, name, text);
      return JNI_FALSE;
    }
    memcpy(selected, text, length + 1);
    (*env)->ReleaseStringUTFChars(env, name, text);
  }
  pthread_mutex_lock(&bridge_lock);
  const int allowed = bridge.vm && active_decoders == 0;
  if (allowed) memcpy(test_codec_name, selected, sizeof(selected));
  pthread_mutex_unlock(&bridge_lock);
  return allowed ? JNI_TRUE : JNI_FALSE;
}
JNIEXPORT jstring JNICALL
Java_dev_lrdp_lrdp_1native_H264Decoder_nativeTestCodec(JNIEnv* env, jclass klass) {
  (void)klass;
  char selected[sizeof(test_codec_name)];
  pthread_mutex_lock(&bridge_lock);
  memcpy(selected, test_codec_name, sizeof(selected));
  pthread_mutex_unlock(&bridge_lock);
  jstring result = selected[0] ? (*env)->NewStringUTF(env, selected) : NULL;
  if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return NULL; }
  return result;
}
#endif

struct lrdp_android_h264 {
  java_bridge java;
  jobject decoder;
  AVCodecParserContext* parser;
  AVCodecContext* parse_context; /* Parser state only; never opened or decoded. */
  AVFrame* image; /* Reusable owned I420; output retains its own buffer refs. */
  int64_t token;
};

typedef struct { JNIEnv* env; JavaVM* vm; int attached; } java_call;
static int exception(JNIEnv* env) {
  if (!(*env)->ExceptionCheck(env)) return 0;
  (*env)->ExceptionClear(env);
  return 1;
}
static int enter_java(JavaVM* vm, java_call* call) {
  memset(call, 0, sizeof(*call));
  if (!vm) return 0;
  call->vm = vm;
  const jint result = (*vm)->GetEnv(vm, (void**)&call->env, JNI_VERSION_1_6);
  if (result == JNI_EDETACHED) {
#ifdef __ANDROID__
    if ((*vm)->AttachCurrentThread(vm, &call->env, NULL) != JNI_OK) return 0;
#else
    if ((*vm)->AttachCurrentThread(vm, (void**)&call->env, NULL) != JNI_OK) return 0;
#endif
    call->attached = 1;
  } else if (result != JNI_OK) return 0;
  if ((*call->env)->PushLocalFrame(call->env, 16) < 0) {
    exception(call->env);
    if (call->attached) (*vm)->DetachCurrentThread(vm);
    call->env = NULL;
    return 0;
  }
  return 1;
}
static void leave_java(java_call* call) {
  if (!call->env) return;
  exception(call->env);
  (*call->env)->PopLocalFrame(call->env, NULL);
  /* Never detach a Java-owned thread, or another decoder's attachment. */
  if (call->attached) (*call->vm)->DetachCurrentThread(call->vm);
}

JNIEXPORT void JNICALL
Java_dev_lrdp_lrdp_1native_H264Decoder_nativeInitialize(JNIEnv* env, jclass klass) {
  pthread_mutex_lock(&bridge_lock);
  if (bridge.vm) { pthread_mutex_unlock(&bridge_lock); return; }
  java_bridge found = {0};
  jclass frame = NULL;
  if ((*env)->GetJavaVM(env, &found.vm) != JNI_OK) goto failed;
  found.decoder_class = (*env)->NewGlobalRef(env, klass);
  if (!found.decoder_class || exception(env)) goto failed;
  frame = (*env)->FindClass(env, "dev/lrdp/lrdp_native/H264Decoder$Frame");
  if (!frame || exception(env)) goto failed;
  found.frame_class = (*env)->NewGlobalRef(env, frame);
  if (!found.frame_class || exception(env)) goto failed;
#define METHOD(field, name, signature) do { \
  found.field = (*env)->GetMethodID(env, klass, name, signature); \
  if (!found.field || exception(env)) goto failed; \
} while (0)
  found.create = (*env)->GetStaticMethodID(env, klass, "create", "()Ldev/lrdp/lrdp_native/H264Decoder;");
  if (!found.create || exception(env)) goto failed;
#ifdef LRDP_ANDROID_H264_TESTING
  found.create_for_test = (*env)->GetStaticMethodID(env, klass, "createForTest",
    "(Ljava/lang/String;)Ldev/lrdp/lrdp_native/H264Decoder;");
  if (!found.create_for_test || exception(env)) goto failed;
#endif
  METHOD(next, "next", "()Z");
  METHOD(decode, "decode", "(Ljava/nio/ByteBuffer;JII)Ldev/lrdp/lrdp_native/H264Decoder$Frame;");
  METHOD(release_frame, "releaseFrame", "()V");
  METHOD(close, "close", "()V");
#undef METHOD
  const char* plane_names[] = {"y", "u", "v"};
  const char* row_names[] = {"yRowStride", "uRowStride", "vRowStride"};
  const char* pixel_names[] = {"yPixelStride", "uPixelStride", "vPixelStride"};
  for (int p = 0; p < 3; p++) {
    found.planes[p] = (*env)->GetFieldID(env, frame, plane_names[p], "Ljava/nio/ByteBuffer;");
    if (!found.planes[p] || exception(env)) goto failed;
    found.rows[p] = (*env)->GetFieldID(env, frame, row_names[p], "I");
    if (!found.rows[p] || exception(env)) goto failed;
    found.pixels[p] = (*env)->GetFieldID(env, frame, pixel_names[p], "I");
    if (!found.pixels[p] || exception(env)) goto failed;
  }
#define FIELD(field, name) do { \
  found.field = (*env)->GetFieldID(env, frame, name, "I"); \
  if (!found.field || exception(env)) goto failed; \
} while (0)
  FIELD(width, "width"); FIELD(height, "height");
  FIELD(crop_left, "cropLeft"); FIELD(crop_top, "cropTop");
#undef FIELD
  (*env)->DeleteLocalRef(env, frame);
  bridge = found; /* Publish only a complete, exception-free cache. */
  pthread_mutex_unlock(&bridge_lock);
  return;
failed:
  exception(env);
  if (frame) (*env)->DeleteLocalRef(env, frame);
  if (found.frame_class) (*env)->DeleteGlobalRef(env, found.frame_class);
  if (found.decoder_class) (*env)->DeleteGlobalRef(env, found.decoder_class);
  pthread_mutex_unlock(&bridge_lock);
}

lrdp_android_h264* lrdp_android_h264_new(void) {
  java_bridge cached;
#ifdef LRDP_ANDROID_H264_TESTING
  char selected[sizeof(test_codec_name)];
#endif
  pthread_mutex_lock(&bridge_lock);
  cached = bridge;
#ifdef LRDP_ANDROID_H264_TESTING
  memcpy(selected, test_codec_name, sizeof(selected));
  active_decoders++;
#endif
  pthread_mutex_unlock(&bridge_lock);
  java_call call;
  if (!enter_java(cached.vm, &call)) {
#ifdef LRDP_ANDROID_H264_TESTING
    test_decoder_finished();
#endif
    return NULL;
  }
  JNIEnv* env = call.env;
  lrdp_android_h264* d = calloc(1, sizeof(*d));
  if (!d) {
    leave_java(&call);
#ifdef LRDP_ANDROID_H264_TESTING
    test_decoder_finished();
#endif
    return NULL;
  }
  d->java = cached;
  jobject object;
#ifdef LRDP_ANDROID_H264_TESTING
  if (selected[0]) {
    jstring name = (*env)->NewStringUTF(env, selected);
    if (!name || exception(env)) goto failed;
    object = (*env)->CallStaticObjectMethod(env, cached.decoder_class, cached.create_for_test, name);
  } else
#endif
    object = (*env)->CallStaticObjectMethod(env, cached.decoder_class, cached.create);
  if (exception(env) || !object) goto failed;
  d->decoder = (*env)->NewGlobalRef(env, object);
  if (!d->decoder || exception(env)) {
    (*env)->CallVoidMethod(env, object, cached.close);
    exception(env);
    goto failed;
  }
  d->parser = av_parser_init(AV_CODEC_ID_H264);
  d->parse_context = avcodec_alloc_context3(NULL);
  d->image = av_frame_alloc();
  if (!d->parser || !d->parse_context || !d->image) goto failed;
  d->parser->flags |= PARSER_FLAG_COMPLETE_FRAMES;
  d->parse_context->codec_id = AV_CODEC_ID_H264;
  d->parse_context->codec_type = AVMEDIA_TYPE_VIDEO;
  d->parse_context->max_pixels = (int64_t)MAX_DIMENSION * MAX_DIMENSION;
  leave_java(&call);
  return d;
failed:
  if (d->decoder) {
    (*env)->CallVoidMethod(env, d->decoder, cached.close);
    exception(env);
    (*env)->DeleteGlobalRef(env, d->decoder);
  }
  if (d->parser) av_parser_close(d->parser);
  avcodec_free_context(&d->parse_context);
  av_frame_free(&d->image);
  free(d);
  leave_java(&call);
#ifdef LRDP_ANDROID_H264_TESTING
  test_decoder_finished();
#endif
  return NULL;
}
void lrdp_android_h264_free(lrdp_android_h264* d) {
  if (!d) return;
  java_call call;
  if (enter_java(d->java.vm, &call)) {
    (*call.env)->CallVoidMethod(call.env, d->decoder, d->java.release_frame);
    exception(call.env);
    (*call.env)->CallVoidMethod(call.env, d->decoder, d->java.close);
    exception(call.env);
    (*call.env)->DeleteGlobalRef(call.env, d->decoder);
    leave_java(&call);
  }
  av_parser_close(d->parser);
  avcodec_free_context(&d->parse_context);
  av_frame_free(&d->image);
  free(d);
#ifdef LRDP_ANDROID_H264_TESTING
  test_decoder_finished();
#endif
}
int lrdp_android_h264_next(lrdp_android_h264* d) {
  if (!d) return 0;
  java_call call;
  if (!enter_java(d->java.vm, &call)) return 0;
  JNIEnv* env = call.env;
  (*env)->CallVoidMethod(env, d->decoder, d->java.release_frame);
  int failed = exception(env);
  jboolean selected = JNI_FALSE;
  if (!failed) selected = (*env)->CallBooleanMethod(env, d->decoder, d->java.next);
  failed |= exception(env);
  leave_java(&call);
  return !failed && selected == JNI_TRUE;
}

int lrdp_android_h264_decode(lrdp_android_h264* d, const uint8_t* data,
                             size_t size, AVFrame* output) {
  if (!d || !data || !size || size > MAX_PACKET || !output || d->token == INT64_MAX)
    return AVERROR(EINVAL);
  /* The public parser reads dimensions/SPS with padded input. It has no opened
   * codec and does not shadow-decode on the CPU. Java owns actual decoding. */
  uint8_t* padded = av_mallocz(size + AV_INPUT_BUFFER_PADDING_SIZE);
  if (!padded) return AVERROR(ENOMEM);
  memcpy(padded, data, size);
  uint8_t* parsed = NULL;
  int parsed_size = 0;
  const int consumed = av_parser_parse2(d->parser, d->parse_context, &parsed, &parsed_size,
    padded, (int)size, AV_NOPTS_VALUE, AV_NOPTS_VALUE, 0);
  const int width = d->parser->width, height = d->parser->height;
  if (consumed < 0 || consumed != (int)size || parsed_size <= 0 ||
      width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION) {
    av_free(padded);
    return AVERROR_INVALIDDATA;
  }
  java_call call;
  if (!enter_java(d->java.vm, &call)) { av_free(padded); return AVERROR_EXTERNAL; }
  JNIEnv* env = call.env;
  int result = AVERROR_INVALIDDATA;
  AVFrame* owned = d->image;
  jobject packet = (*env)->NewDirectByteBuffer(env, padded, (jlong)size);
  if (!packet || exception(env)) goto cleanup;
  jobject frame = (*env)->CallObjectMethod(env, d->decoder, d->java.decode, packet,
    (jlong)++d->token, (jint)width, (jint)height);
  if (exception(env) || !frame) goto cleanup;
  const jint frame_width = (*env)->GetIntField(env, frame, d->java.width);
  const jint frame_height = (*env)->GetIntField(env, frame, d->java.height);
  const jint crop_left = (*env)->GetIntField(env, frame, d->java.crop_left);
  const jint crop_top = (*env)->GetIntField(env, frame, d->java.crop_top);
  if (exception(env) || frame_width != width || frame_height != height ||
      crop_left < 0 || crop_top < 0) goto cleanup;
  lrdp_h264_image_plane planes[3] = {0};
  for (int p = 0; p < 3; p++) {
    jobject plane = (*env)->GetObjectField(env, frame, d->java.planes[p]);
    if (!plane || exception(env)) goto cleanup;
    void* address = (*env)->GetDirectBufferAddress(env, plane);
    jlong capacity = (*env)->GetDirectBufferCapacity(env, plane);
    jint row_stride = (*env)->GetIntField(env, frame, d->java.rows[p]);
    jint pixel_stride = (*env)->GetIntField(env, frame, d->java.pixels[p]);
    if (exception(env) || !address || capacity <= 0 || (uint64_t)capacity > SIZE_MAX ||
        row_stride <= 0 || pixel_stride <= 0) goto cleanup;
    planes[p] = (lrdp_h264_image_plane){address, (size_t)capacity,
                                      (size_t)row_stride, (size_t)pixel_stride};
  }
  if (owned->width != width || owned->height != height) av_frame_unref(owned);
  owned->format = AV_PIX_FMT_YUV420P;
  owned->width = width; owned->height = height;
  /* Usually output was unreferenced before the next decode, allowing reuse.
   * If a caller still owns a prior frame, make_writable preserves its pixels. */
  result = owned->data[0] ? av_frame_make_writable(owned) : av_frame_get_buffer(owned, 32);
  if (result < 0) goto cleanup;
  lrdp_h264_image_output destination[3];
  for (int p = 0; p < 3; p++) {
    const size_t rows = p ? ((size_t)height + 1) / 2 : (size_t)height;
    if (owned->linesize[p] <= 0 || (size_t)owned->linesize[p] > SIZE_MAX / rows) {
      result = AVERROR_INVALIDDATA; goto cleanup;
    }
    destination[p] = (lrdp_h264_image_output){owned->data[p],
      (size_t)owned->linesize[p] * rows, (size_t)owned->linesize[p]};
  }
  result = lrdp_h264_image_copy_i420(planes, (size_t)crop_left, (size_t)crop_top,
                                  (size_t)width, (size_t)height, destination) == 1 ?
    1 : AVERROR_INVALIDDATA;
cleanup:
  /* decode(null/exception/timeout/layout failure) may still hold an Image or
   * output index. Always release before dropping local buffers or detaching. */
  exception(env);
  (*env)->CallVoidMethod(env, d->decoder, d->java.release_frame);
  if (exception(env)) result = AVERROR_EXTERNAL;
  if (result == 1) {
    av_frame_unref(output);
    result = av_frame_ref(output, owned);
    if (result >= 0) result = 1;
  }
  leave_java(&call);
  av_free(padded);
  return result;
}
