/* Android renderer: only retained frame-memory APIs run on this GL thread.
 * No FreeRDP call or session address is used by the platform plugin. */
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <android/log.h>
#include <android/native_window_jni.h>
#include <jni.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "lrdp.h"

typedef struct {
  lrdp_video* video;
  EGLDisplay display;
  EGLContext context;
  EGLConfig config;
  EGLSurface surface;
  ANativeWindow* window;
  jobject surface_ref; /* global ref to the Java Surface owning window/surface */
  GLuint program, texture;
  GLint position, uv;
  int32_t tex_width, tex_height, target_width, target_height;
  int es3; /* GLES3 row-length support for sub-rectangle uploads */
  uint64_t generation, uploads;
  int failed;
} android_video;
/* Per-renderer access is serialized on its GL handler. Atomic diagnostics
 * also permit an initial capability probe and independent Flutter engines. */
static _Atomic int objects, contexts, surfaces, textures, failures, presented, cleanup_failures;
#ifndef NDEBUG
static _Atomic int fail_uploads;
#endif
#define JNI_METHOD(name) Java_dev_lrdp_lrdp_1native_LrdpNativePlugin_##name
/* Per-frame EGL accounting. A binding and a surface creation happen once per
 * Java Surface instead of once per frame; make-current is the remaining call.
 * LRDP_ANDROID_GL_TRACE=1 (e.g. adb shell setprop wrap.<package>
 * LRDP_ANDROID_GL_TRACE=1 for a debuggable build) logs the counters to logcat
 * and never changes rendering behavior. */
static _Atomic unsigned long long window_binds, surface_creations, make_currents, drawn_frames;
static _Atomic int gl_trace = -1;
static int tracing(void) {
  int trace = gl_trace;
  if (trace < 0) {
    trace = getenv("LRDP_ANDROID_GL_TRACE") ? 1 : 0;
    gl_trace = trace;
  }
  return trace;
}
static void trace_log(const char* format, ...) {
  if (!tracing()) return;
  char message[192];
  va_list arguments;
  va_start(arguments, format);
  vsnprintf(message, sizeof(message), format, arguments);
  va_end(arguments);
  __android_log_print(ANDROID_LOG_INFO, "lrdp-video", "%s", message);
}
static void trace_counts(const char* event) {
  trace_log("%s frames=%llu windowBinds=%llu surfaceCreates=%llu makeCurrents=%llu", event,
            (unsigned long long)drawn_frames, (unsigned long long)window_binds,
            (unsigned long long)surface_creations, (unsigned long long)make_currents);
}

static GLuint shader(GLenum type, const char* source) {
  GLuint result = glCreateShader(type);
  glShaderSource(result, 1, &source, NULL);
  glCompileShader(result);
  GLint ok = 0;
  glGetShaderiv(result, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    glDeleteShader(result);
    return 0;
  }
  return result;
}
/* Release the cached EGLSurface, the single ANativeWindow acquisition and the
 * Java Surface reference. Every JNI entry point owns an env, and the renderer
 * runs these paths on its GL handler. */
static void drop_surface(android_video* self, JNIEnv* env) {
  if (self->surface != EGL_NO_SURFACE) {
    if (!eglMakeCurrent(self->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT))
      cleanup_failures++;
    if (eglDestroySurface(self->display, self->surface))
      surfaces--;
    else
      cleanup_failures++;
    self->surface = EGL_NO_SURFACE;
  }
  if (self->window) {
    ANativeWindow_release(self->window);
    self->window = NULL;
  }
  if (self->surface_ref) {
    (*env)->DeleteGlobalRef(env, self->surface_ref);
    self->surface_ref = NULL;
  }
}
/* Prefer an ES3 context: only GLES3 can skip rows and pixels, which is what
 * makes a sub-rectangle upload possible. ES2 devices keep re-uploading whole
 * frames. The renderer never shares Flutter's display, so its API is fixed. */
static int create_context(android_video* self, EGLint renderable, const EGLint* attributes) {
  const EGLint config[] = {EGL_SURFACE_TYPE,
                           EGL_WINDOW_BIT,
                           EGL_RENDERABLE_TYPE,
                           renderable,
                           EGL_RED_SIZE,
                           8,
                           EGL_GREEN_SIZE,
                           8,
                           EGL_BLUE_SIZE,
                           8,
                           EGL_ALPHA_SIZE,
                           8,
                           EGL_DEPTH_SIZE,
                           0,
                           EGL_STENCIL_SIZE,
                           0,
                           EGL_NONE};
  EGLint count = 0;
  if (!eglChooseConfig(self->display, config, &self->config, 1, &count) || count != 1) return 0;
  self->context = eglCreateContext(self->display, self->config, EGL_NO_CONTEXT, attributes);
  return self->context != EGL_NO_CONTEXT;
}
static int initialize(android_video* self) {
  self->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (self->display == EGL_NO_DISPLAY || !eglInitialize(self->display, NULL, NULL)) return 0;
  if (!eglBindAPI(EGL_OPENGL_ES_API)) return 0;
  const EGLint es3_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  const EGLint es2_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  self->es3 = create_context(self, EGL_OPENGL_ES3_BIT, es3_attributes);
  if (!self->es3 && !create_context(self, EGL_OPENGL_ES2_BIT, es2_attributes)) return 0;
  contexts++;
  return 1;
}
/* Keep the ANativeWindow and its EGLSurface for as long as the Java Surface
 * object lives, instead of acquiring them again on every frame. A new object
 * identity (rotation, background/foreground, producer replacement) rebinds the
 * cache; the global reference is what stays valid after the JNI call returns. */
static int bind_surface(android_video* self, JNIEnv* env, jobject surface) {
  if (self->surface_ref && (*env)->IsSameObject(env, self->surface_ref, surface)) return 1;
  drop_surface(self, env);
  jobject reference = (*env)->NewGlobalRef(env, surface);
  if (!reference) return 0;
  ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
  if (!window) {
    (*env)->DeleteGlobalRef(env, reference);
    return 0;
  }
  window_binds++;
  self->surface_ref = reference;
  self->window = window;
  self->generation = 0; /* a new Surface starts from a whole-frame upload */
  trace_log("bound surface windowBinds=%llu", (unsigned long long)window_binds);
  return 1;
}
static int prepare(android_video* self, int32_t width, int32_t height) {
  if (self->target_width != width || self->target_height != height) {
    self->target_width = width;
    self->target_height = height;
    self->generation = 0;
  }
  if (self->context == EGL_NO_CONTEXT && !initialize(self)) return -1;
  if (!self->window) return 0;
  if (self->surface == EGL_NO_SURFACE) {
    self->surface = eglCreateWindowSurface(self->display, self->config, self->window, NULL);
    if (self->surface == EGL_NO_SURFACE) return 0;
    surface_creations++;
    surfaces++;
  }
  /* Flutter's own render thread keeps a separate context; rebind only when this
   * thread is not already current with exactly our context and surface. */
  if (eglGetCurrentContext() != self->context || eglGetCurrentSurface(EGL_DRAW) != self->surface) {
    if (!eglMakeCurrent(self->display, self->surface, self->surface, self->context)) return 0;
    make_currents++;
  }
  if (!self->program) {
    GLuint vertex = shader(GL_VERTEX_SHADER,
                           "attribute vec2 position;attribute vec2 uv;varying highp vec2 tex;"
                           "void main(){tex=uv;gl_Position=vec4(position,0.,1.);}");
    GLuint fragment = shader(GL_FRAGMENT_SHADER,
                             "precision highp float;varying highp vec2 tex;uniform sampler2D image;"
                             "void main(){gl_FragColor=texture2D(image,tex).bgra;}");
    if (!vertex || !fragment) {
      glDeleteShader(vertex);
      glDeleteShader(fragment);
      return -1;
    }
    self->program = glCreateProgram();
    glAttachShader(self->program, vertex);
    glAttachShader(self->program, fragment);
    glLinkProgram(self->program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint linked = 0;
    glGetProgramiv(self->program, GL_LINK_STATUS, &linked);
    if (!linked) return -1;
    self->position = glGetAttribLocation(self->program, "position");
    self->uv = glGetAttribLocation(self->program, "uv");
    glUseProgram(self->program);
    glUniform1i(glGetUniformLocation(self->program, "image"), 0);
    /* Confirm the requested backend: whole-frame uploads stay correct when a
     * driver reports an unexpected version. 11 bytes covers "OpenGL ES 3". */
    const char* version = (const char*)glGetString(GL_VERSION);
    self->es3 = self->es3 && version && strncmp(version, "OpenGL ES 3", 11) == 0;
    glGenTextures(1, &self->texture);
    if (!self->texture) return -1;
    textures++;
    glBindTexture(GL_TEXTURE_2D, self->texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  }
  return 1;
}
/* Upload pixels into the texture and present. damage==NULL means the whole
 * frame changed; a zero-size rectangle means nothing visible changed. Only the
 * damaged rectangle is transferred, so upload cost follows the changed area
 * rather than the client resolution. */
static int upload(const uint8_t* pixels, int32_t width, int32_t height,
                  const lrdp_video_rect* damage, void* context) {
  android_video* self = context;
#ifndef NDEBUG
  if (fail_uploads) {
    self->failed = 1;
    failures++;
    return 0;
  }
#endif
  glUseProgram(self->program);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, self->texture);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  /* Native BGRA bytes enter RGBA storage unchanged; the shader swaps R/B.
   * No CPU channel conversion or Java/Dart frame array is needed.
   * GLES3 row-length parameters address the pixels of the damage box inside
   * the frame; whole-frame uploads keep the default tightly packed rows. */
  const int have_texture =
      self->tex_width == width && self->tex_height == height && self->tex_width > 0;
  const int empty = damage != NULL && (damage->width <= 0 || damage->height <= 0);
  const int partial = !empty && damage != NULL && self->es3 && have_texture && damage->x >= 0 &&
                      damage->y >= 0 && damage->width <= width - damage->x &&
                      damage->height <= height - damage->y;
  if (partial) {
    glPixelStorei(GL_UNPACK_ROW_LENGTH, width);
    glPixelStorei(GL_UNPACK_SKIP_PIXELS, damage->x);
    glPixelStorei(GL_UNPACK_SKIP_ROWS, damage->y);
    glTexSubImage2D(GL_TEXTURE_2D, 0, damage->x, damage->y, damage->width, damage->height, GL_RGBA,
                    GL_UNSIGNED_BYTE, pixels);
    /* Restore before the draw: a failed upload must not leak the stride. */
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
    glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
  } else if (!empty || !have_texture) {
    if (self->es3) {
      glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
      glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
      glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
    }
    if (have_texture)
      glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    else
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
  }
  const GLfloat vertices[] = {-1, -1, 0, 1, 1, -1, 1, 1, -1, 1, 0, 0, 1, 1, 1, 0};
  glViewport(0, 0, self->target_width, self->target_height);
  glDisable(GL_BLEND);
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_SCISSOR_TEST);
  glVertexAttribPointer((GLuint)self->position, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat),
                        vertices);
  glVertexAttribPointer((GLuint)self->uv, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), vertices + 2);
  glEnableVertexAttribArray((GLuint)self->position);
  glEnableVertexAttribArray((GLuint)self->uv);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  if (glGetError() != GL_NO_ERROR) {
    self->failed = 1;
    failures++;
    return 0;
  }
  if (!eglSwapBuffers(self->display, self->surface)) return 0;
  self->tex_width = width;
  self->tex_height = height;
  self->uploads++;
  presented++;
  return 1;
}
JNIEXPORT jlong JNICALL JNI_METHOD(nativeCreate)(JNIEnv* env, jclass type, jlong ticket) {
  (void)env;
  (void)type;
  lrdp_video* video = lrdp_video_open((uint64_t)ticket);
  if (!video) return 0;
  android_video* self = calloc(1, sizeof(*self));
  if (!self) {
    lrdp_video_close(video);
    return 0;
  }
  self->video = video;
  self->display = EGL_NO_DISPLAY;
  self->context = EGL_NO_CONTEXT;
  self->surface = EGL_NO_SURFACE;
  objects++;
  return (jlong)(intptr_t)self;
}
JNIEXPORT jlongArray JNICALL JNI_METHOD(nativeStatus)(JNIEnv* env, jclass type, jlong handle) {
  (void)type;
  android_video* self = (android_video*)(intptr_t)handle;
  int32_t width = 0, height = 0;
  uint64_t generation = 0;
  lrdp_video_info(self->video, &width, &height, &generation);
  const jlong values[] = {width, height, (jlong)generation, (jlong)self->uploads, self->failed};
  jlongArray result = (*env)->NewLongArray(env, 5);
  if (result) (*env)->SetLongArrayRegion(env, result, 0, 5, values);
  return result;
}
JNIEXPORT jint JNICALL JNI_METHOD(nativeDraw)(JNIEnv* env, jclass type, jlong handle,
                                              jobject surface, jint width, jint height) {
  (void)type;
  android_video* self = (android_video*)(intptr_t)handle;
  if (self->failed || !surface || width < 1 || height < 1) return 0;
  if (!bind_surface(self, env, surface)) return 0;
  int ready = prepare(self, width, height);
  if (ready < 0) {
    self->failed = 1;
    failures++;
    return -1;
  }
  if (!ready) {
    drop_surface(self, env);
    return -3;
  }
  int result = lrdp_video_visit_damage(self->video, upload, self, &self->generation);
  if (result == -1 && !self->failed) {
    drop_surface(self, env);
    return -3;
  }
  if (result > 0) {
    unsigned long long frames = ++drawn_frames;
    if (frames % 120 == 0) trace_counts("frames");
  }
  return result;
}
JNIEXPORT void JNICALL JNI_METHOD(nativeReset)(JNIEnv* env, jclass type, jlong handle,
                                               jboolean detach) {
  (void)type;
  android_video* self = (android_video*)(intptr_t)handle;
  if (detach) drop_surface(self, env);
  self->generation = 0;
}
JNIEXPORT void JNICALL JNI_METHOD(nativeDestroy)(JNIEnv* env, jclass type, jlong handle) {
  (void)type;
  android_video* self = (android_video*)(intptr_t)handle;
  /* GL deletion with no available surface is unnecessary: destroying our own
   * unshared context releases all its objects. Never eglTerminate the process
   * default display, which is also used by Flutter. */
  drop_surface(self, env);
  trace_counts("destroy");
  if (self->context != EGL_NO_CONTEXT) {
    if (eglDestroyContext(self->display, self->context)) {
      contexts--;
      if (self->texture) textures--;
    } else
      cleanup_failures++;
  }
  lrdp_video_close(self->video);
  free(self);
  objects--;
}
JNIEXPORT jlongArray JNICALL JNI_METHOD(nativeDiagnostics)(JNIEnv* env, jclass type) {
  (void)type;
  const jlong values[] = {objects,  contexts,  surfaces,        textures,
                          failures, presented, cleanup_failures};
  jlongArray result = (*env)->NewLongArray(env, 7);
  if (result) (*env)->SetLongArrayRegion(env, result, 0, 7, values);
  return result;
}
JNIEXPORT void JNICALL JNI_METHOD(nativeTestFailure)(JNIEnv* env, jclass type, jboolean enabled) {
  (void)env;
  (void)type;
  (void)enabled;
#ifndef NDEBUG
  fail_uploads = enabled;
#endif
}
