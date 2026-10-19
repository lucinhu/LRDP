/* Android renderer: only retained frame-memory APIs run on this GL thread.
 * No FreeRDP call or session address is used by the platform plugin. */
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <android/native_window_jni.h>
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>

#include "lrdp.h"

typedef struct {
  lrdp_video* video;
  EGLDisplay display;
  EGLContext context;
  EGLConfig config;
  EGLSurface surface;
  ANativeWindow* window;
  GLuint program, texture;
  GLint position, uv;
  int32_t tex_width, tex_height, target_width, target_height;
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
static void drop_surface(android_video* self) {
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
}
static int initialize(android_video* self) {
  self->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (self->display == EGL_NO_DISPLAY || !eglInitialize(self->display, NULL, NULL)) return 0;
  const EGLint config[] = {EGL_SURFACE_TYPE,
                           EGL_WINDOW_BIT,
                           EGL_RENDERABLE_TYPE,
                           EGL_OPENGL_ES2_BIT,
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
  const EGLint context[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  EGLint count = 0;
  if (!eglChooseConfig(self->display, config, &self->config, 1, &count) || count != 1 ||
      !eglBindAPI(EGL_OPENGL_ES_API))
    return 0;
  self->context = eglCreateContext(self->display, self->config, EGL_NO_CONTEXT, context);
  if (self->context == EGL_NO_CONTEXT) return 0;
  contexts++;
  return 1;
}
static int prepare(android_video* self, ANativeWindow* window, int32_t width, int32_t height) {
  if (window != self->window) {
    drop_surface(self);
    self->window = window;
    ANativeWindow_acquire(window);
    self->generation = 0;
  }
  if (self->target_width != width || self->target_height != height) {
    self->target_width = width;
    self->target_height = height;
    self->generation = 0;
  }
  if (self->context == EGL_NO_CONTEXT && !initialize(self)) return -1;
  if (self->surface == EGL_NO_SURFACE) {
    self->surface = eglCreateWindowSurface(self->display, self->config, window, NULL);
    if (self->surface == EGL_NO_SURFACE) return 0;
    surfaces++;
  }
  if (!eglMakeCurrent(self->display, self->surface, self->surface, self->context)) return 0;
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
static int upload(const uint8_t* pixels, int32_t width, int32_t height, void* context) {
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
   * No CPU channel conversion or Java/Dart frame array is needed. */
  if (self->tex_width != width || self->tex_height != height) {
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
  } else
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
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
  ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
  if (!window) return 0;
  int ready = prepare(self, window, width, height);
  ANativeWindow_release(window);
  if (ready < 0) {
    self->failed = 1;
    failures++;
    return -1;
  }
  if (!ready) {
    drop_surface(self);
    return -3;
  }
  int result = lrdp_video_visit(self->video, upload, self, &self->generation);
  if (result == -1 && !self->failed) {
    drop_surface(self);
    return -3;
  }
  return result;
}
JNIEXPORT void JNICALL JNI_METHOD(nativeReset)(JNIEnv* env, jclass type, jlong handle,
                                               jboolean detach) {
  (void)env;
  (void)type;
  android_video* self = (android_video*)(intptr_t)handle;
  if (detach) drop_surface(self);
  self->generation = 0;
}
JNIEXPORT void JNICALL JNI_METHOD(nativeDestroy)(JNIEnv* env, jclass type, jlong handle) {
  (void)env;
  (void)type;
  android_video* self = (android_video*)(intptr_t)handle;
  /* GL deletion with no available surface is unnecessary: destroying our own
   * unshared context releases all its objects. Never eglTerminate the process
   * default display, which is also used by Flutter. */
  drop_surface(self);
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
