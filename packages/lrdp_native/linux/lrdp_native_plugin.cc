#include "include/lrdp_native/lrdp_native_plugin.h"

#include <epoxy/egl.h>
#include <epoxy/gl.h>

#include "lrdp.h"

// One transparent fallback image per engine. It is intentionally owned by the
// engine's GL share group, so even a context-sharing failure can fall back
// without leaving a GPU object per failed connection. Engine teardown frees it.
struct FallbackImage {
  GMutex lock;
  gint references;
  GLuint name;
};
static FallbackImage* fallback_new() {
  auto* image = g_new0(FallbackImage, 1);
  g_mutex_init(&image->lock);
  image->references = 1;
  return image;
}
static FallbackImage* fallback_ref(FallbackImage* image) {
  g_atomic_int_inc(&image->references);
  return image;
}
static void fallback_unref(FallbackImage* image) {
  if (image && g_atomic_int_dec_and_test(&image->references)) {
    g_mutex_clear(&image->lock);
    g_free(image);
  }
}
static GLuint fallback_name(FallbackImage* image) {
  g_mutex_lock(&image->lock);
  if (!image->name) {
    GLint binding, alignment, buffer = 0, row_length = 0, skip_rows = 0, skip_pixels = 0;
    const gboolean rows = epoxy_is_desktop_gl() || epoxy_gl_version() >= 30;
    const gboolean pbo = epoxy_gl_version() >= (epoxy_is_desktop_gl() ? 21 : 30);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &binding);
    glGetIntegerv(GL_UNPACK_ALIGNMENT, &alignment);
    if (pbo) {
      glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &buffer);
      glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    }
    if (rows) {
      glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row_length);
      glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skip_rows);
      glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skip_pixels);
      glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
      glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
      glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
    }
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glGenTextures(1, &image->name);
    glBindTexture(GL_TEXTURE_2D, image->name);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    const uint8_t transparent[4] = {0, 0, 0, 0};
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, transparent);
    glBindTexture(GL_TEXTURE_2D, binding);
    glPixelStorei(GL_UNPACK_ALIGNMENT, alignment);
    if (pbo) glBindBuffer(GL_PIXEL_UNPACK_BUFFER, buffer);
    if (rows) {
      glPixelStorei(GL_UNPACK_ROW_LENGTH, row_length);
      glPixelStorei(GL_UNPACK_SKIP_ROWS, skip_rows);
      glPixelStorei(GL_UNPACK_SKIP_PIXELS, skip_pixels);
    }
  }
  GLuint name = image->name;
  g_mutex_unlock(&image->lock);
  return name;
}

G_DECLARE_FINAL_TYPE(LrdpTexture, lrdp_texture, LRDP, TEXTURE, FlTextureGL)
struct _LrdpTexture {
  FlTextureGL parent_instance;
  GMutex lock;
  lrdp_video* video;
  gint frame_rate;
  gint64 next_frame;
  FallbackImage* fallback;
  GLuint name;
  uint32_t width, height;
  uint64_t generation, announced, uploads;
  EGLDisplay display;
  EGLContext cleanup;
  gboolean visible, failed;
};
G_DEFINE_TYPE(LrdpTexture, lrdp_texture, fl_texture_gl_get_type())
static gint live_textures, live_contexts, live_gpu_names, cleanup_failures, upload_failures;

// A separate shared EGL context can delete textures on the platform thread.
// Never take Flutter's raster context away from its thread during disposal.
static gboolean prepare_cleanup(LrdpTexture* self) {
  self->display = eglGetCurrentDisplay();
  EGLContext current = eglGetCurrentContext();
  if (self->display == EGL_NO_DISPLAY || current == EGL_NO_CONTEXT) return FALSE;
  EGLint id = 0, type = 0, version = 0, count = 0;
  if (!eglQueryContext(self->display, current, EGL_CONFIG_ID, &id) ||
      !eglQueryContext(self->display, current, EGL_CONTEXT_CLIENT_TYPE, &type) ||
      !eglQueryContext(self->display, current, EGL_CONTEXT_CLIENT_VERSION, &version))
    return FALSE;
  EGLConfig config = nullptr;
  const EGLint renderable = type == EGL_OPENGL_API ? EGL_OPENGL_BIT
                            : version >= 3         ? EGL_OPENGL_ES3_BIT
                            : version == 2         ? EGL_OPENGL_ES2_BIT
                                                   : EGL_OPENGL_ES_BIT;
  const EGLint choose[] = {EGL_CONFIG_ID, id, EGL_RENDERABLE_TYPE, renderable, EGL_NONE};
  const EGLint es[] = {EGL_CONTEXT_CLIENT_VERSION, version, EGL_NONE};
  const EGLint gl[] = {EGL_NONE};
  if (!eglChooseConfig(self->display, choose, &config, 1, &count) || count != 1) return FALSE;
  EGLenum previous_api = eglQueryAPI();
  if (!eglBindAPI(type)) return FALSE;
  self->cleanup =
      eglCreateContext(self->display, config, current, type == EGL_OPENGL_ES_API ? es : gl);
  eglBindAPI(previous_api);
  if (self->cleanup != EGL_NO_CONTEXT) g_atomic_int_inc(&live_contexts);
  return self->cleanup != EGL_NO_CONTEXT;
}

static int upload(const uint8_t* pixels, int32_t width, int32_t height, void* context) {
  auto* self = LRDP_TEXTURE(context);
#ifndef NDEBUG
  if (g_getenv("LRDP_VIDEO_TEST_FAIL_UPLOAD")) return 0;
#endif
  // Upload BGRA directly into RGBA8 storage. Flutter/Skia owns sampling
  // swizzles, so texture parameters cannot be used for channel conversion.
  if (epoxy_gl_version() < (epoxy_is_desktop_gl() ? 33 : 30)) return 0;
  GLint binding, alignment, unpack_buffer, row_length, skip_rows, skip_pixels;
  glGetIntegerv(GL_TEXTURE_BINDING_2D, &binding);
  glGetIntegerv(GL_UNPACK_ALIGNMENT, &alignment);
  glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &unpack_buffer);
  glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row_length);
  glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skip_rows);
  glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skip_pixels);
  glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
  glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
  glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
  if (!self->name) {
    glGenTextures(1, &self->name);
    if (self->name) g_atomic_int_inc(&live_gpu_names);
  }
  glBindTexture(GL_TEXTURE_2D, self->name);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  if (self->width != static_cast<uint32_t>(width) ||
      self->height != static_cast<uint32_t>(height)) {
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_BGRA, GL_UNSIGNED_BYTE, pixels);
  } else {
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_BGRA, GL_UNSIGNED_BYTE, pixels);
  }
  GLenum error = glGetError();
  glBindTexture(GL_TEXTURE_2D, binding);
  glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpack_buffer);
  glPixelStorei(GL_UNPACK_ALIGNMENT, alignment);
  glPixelStorei(GL_UNPACK_ROW_LENGTH, row_length);
  glPixelStorei(GL_UNPACK_SKIP_ROWS, skip_rows);
  glPixelStorei(GL_UNPACK_SKIP_PIXELS, skip_pixels);
  if (error != GL_NO_ERROR) {
    if (g_getenv("LRDP_VIDEO_TRACE"))
      g_printerr("LRDP video upload error=%u GL=%s\n", error, glGetString(GL_VERSION));
    return 0;
  }
  self->width = width;
  self->height = height;
  self->uploads++;
  return 1;
}

static gboolean populate(FlTextureGL* texture, uint32_t* target, uint32_t* name, uint32_t* width,
                         uint32_t* height, GError**) {
  auto* self = LRDP_TEXTURE(g_object_ref(texture));
  g_mutex_lock(&self->lock);
  if (!self->failed &&
      (!self->video || (self->cleanup == EGL_NO_CONTEXT && !prepare_cleanup(self)))) {
    self->failed = TRUE;
    g_atomic_int_inc(&upload_failures);
  }
  if (!self->failed) {
    int result = lrdp_video_visit(self->video, upload, self, &self->generation);
    if (result == -1) {
      self->failed = TRUE;
      g_atomic_int_inc(&upload_failures);
    }
  }
  // Some Flutter raster backends dereference a missing initial texture. Keep
  // a valid transparent image until Dart replaces this layer with CPU output.
  *target = GL_TEXTURE_2D;
  if (!self->failed && self->name && self->width && self->height) {
    *name = self->name;
    *width = self->width;
    *height = self->height;
  } else {
    *name = fallback_name(self->fallback);
    *width = *height = 1;
  }
  gboolean ok = *name != 0;
  g_mutex_unlock(&self->lock);
  g_object_unref(self);
  return ok;
}

static gpointer cleanup_gl(gpointer data) {
  auto* self = LRDP_TEXTURE(data);
  EGLint api = 0;
  if (eglQueryContext(self->display, self->cleanup, EGL_CONTEXT_CLIENT_TYPE, &api) &&
      eglBindAPI(api) &&
      eglMakeCurrent(self->display, EGL_NO_SURFACE, EGL_NO_SURFACE, self->cleanup)) {
    if (self->name) {
      glDeleteTextures(1, &self->name);
      if (glGetError() == GL_NO_ERROR)
        g_atomic_int_add(&live_gpu_names, -1);
      else
        g_atomic_int_inc(&cleanup_failures);
    }
    eglMakeCurrent(self->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  } else
    g_atomic_int_inc(&cleanup_failures);
  if (eglDestroyContext(self->display, self->cleanup))
    g_atomic_int_add(&live_contexts, -1);
  else
    g_atomic_int_inc(&cleanup_failures);
  return nullptr;
}
static void texture_dispose(GObject* object) {
  auto* self = LRDP_TEXTURE(object);
  g_mutex_lock(&self->lock);
  lrdp_video_close(self->video);
  self->video = nullptr;
  if (self->cleanup != EGL_NO_CONTEXT) {
    // A dedicated thread has no GTK/GLX or Flutter context to disturb. The
    // shared context deletes GPU objects without stealing a raster context.
    GThread* cleanup = g_thread_new("lrdp-gl-release", cleanup_gl, self);
    g_thread_join(cleanup);
    self->cleanup = EGL_NO_CONTEXT;
  }
  self->name = 0;
  g_mutex_unlock(&self->lock);
  G_OBJECT_CLASS(lrdp_texture_parent_class)->dispose(object);
}
static void texture_finalize(GObject* object) {
  fallback_unref(LRDP_TEXTURE(object)->fallback);
  g_mutex_clear(&LRDP_TEXTURE(object)->lock);
  g_atomic_int_add(&live_textures, -1);
  G_OBJECT_CLASS(lrdp_texture_parent_class)->finalize(object);
}
static void lrdp_texture_class_init(LrdpTextureClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = populate;
  G_OBJECT_CLASS(klass)->dispose = texture_dispose;
  G_OBJECT_CLASS(klass)->finalize = texture_finalize;
}
static void lrdp_texture_init(LrdpTexture* self) {
  g_atomic_int_inc(&live_textures);
  g_mutex_init(&self->lock);
  self->visible = TRUE;
  self->frame_rate = 60;
  self->display = EGL_NO_DISPLAY;
  self->cleanup = EGL_NO_CONTEXT;
}

G_DECLARE_FINAL_TYPE(LrdpNativePlugin, lrdp_native_plugin, LRDP, NATIVE_PLUGIN, GObject)
struct _LrdpNativePlugin {
  GObject parent_instance;
  FlTextureRegistrar* registrar;
  GHashTable* textures;
  FallbackImage* fallback;
  GtkWidget* view;
  guint tick;
};
G_DEFINE_TYPE(LrdpNativePlugin, lrdp_native_plugin, G_TYPE_OBJECT)

static FlValue* status(LrdpTexture* texture) {
  FlValue* result = fl_value_new_map();
  int32_t width = 0, height = 0;
  uint64_t generation = 0;
  g_mutex_lock(&texture->lock);
  if (texture->video) lrdp_video_info(texture->video, &width, &height, &generation);
  fl_value_set_string_take(result, "width", fl_value_new_int(width));
  fl_value_set_string_take(result, "height", fl_value_new_int(height));
  fl_value_set_string_take(result, "generation", fl_value_new_int(generation));
  fl_value_set_string_take(result, "uploads", fl_value_new_int(texture->uploads));
  fl_value_set_string_take(result, "failed", fl_value_new_bool(texture->failed));
  fl_value_set_string_take(result, "frameRate", fl_value_new_int(texture->frame_rate));
  g_mutex_unlock(&texture->lock);
  return result;
}
static gboolean poll_frames(GtkWidget*, GdkFrameClock* clock, gpointer data) {
  auto* self = LRDP_NATIVE_PLUGIN(data);
  const gint64 now = gdk_frame_clock_get_frame_time(clock);
  gboolean active = FALSE;
  GHashTableIter iter;
  gpointer value;
  g_hash_table_iter_init(&iter, self->textures);
  while (g_hash_table_iter_next(&iter, nullptr, &value)) {
    auto* texture = LRDP_TEXTURE(value);
    int32_t w, h;
    uint64_t generation;
    g_mutex_lock(&texture->lock);
    active |= texture->visible && !texture->failed;
    gboolean update = texture->visible && !texture->failed && texture->video &&
                      now + 500 >= texture->next_frame &&
                      lrdp_video_info(texture->video, &w, &h, &generation) &&
                      texture->announced != generation;
    if (update) {
      texture->announced = generation;
      const gint64 interval = 1000000 / texture->frame_rate;
      if (!texture->next_frame || now - texture->next_frame > interval)
        texture->next_frame = now;
      texture->next_frame += interval;
    }
    g_mutex_unlock(&texture->lock);
    if (update)
      fl_texture_registrar_mark_texture_frame_available(self->registrar, FL_TEXTURE(texture));
  }
  if (!active) self->tick = 0;
  return active ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
}
static void schedule_tick(LrdpNativePlugin* self) {
  if (!self->tick)
    self->tick = gtk_widget_add_tick_callback(self->view, poll_frames, self, nullptr);
}
static void respond(FlMethodCall* call, FlValue* value) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(call, response, nullptr);
}
static void error(FlMethodCall* call, const char* message) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_error_response_new("video-unavailable", message, nullptr));
  fl_method_call_respond(call, response, nullptr);
}
static void clipboard_read(GtkClipboard*, GtkSelectionData* selection, gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  const gint size = gtk_selection_data_get_length(selection);
  if (size <= 0) { respond(call, nullptr); return; }
  if (size > 16 * 1024 * 1024) { error(call, "Image exceeds 16 MiB"); return; }
  g_autoptr(FlValue) value = fl_value_new_map();
  fl_value_set_string_take(value, "kind", fl_value_new_int(1));
  fl_value_set_string_take(value, "bytes", fl_value_new_uint8_list(
      gtk_selection_data_get_data(selection), static_cast<size_t>(size)));
  respond(call, value);
}
static void clipboard_method(FlMethodChannel*, FlMethodCall* call, gpointer) {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  const char* name = fl_method_call_get_name(call);
  if (g_str_equal(name, "read")) {
    // Request encoded PNG; do not decode an unbounded image in GTK first.
    gtk_clipboard_request_contents(clipboard, gdk_atom_intern_static_string("image/png"),
                                   clipboard_read, g_object_ref(call));
    return;
  }
  if (!g_str_equal(name, "write")) {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
    return;
  }
  FlValue* args = fl_method_call_get_args(call);
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) { error(call, "Invalid image"); return; }
  FlValue *w = fl_value_lookup_string(args, "width"), *h = fl_value_lookup_string(args, "height"),
          *rgba = fl_value_lookup_string(args, "rgba");
  if (!w || !h || !rgba || fl_value_get_type(w) != FL_VALUE_TYPE_INT ||
      fl_value_get_type(h) != FL_VALUE_TYPE_INT || fl_value_get_type(rgba) != FL_VALUE_TYPE_UINT8_LIST) {
    error(call, "Invalid image"); return;
  }
  const gint64 width = fl_value_get_int(w), height = fl_value_get_int(h);
  if (width < 1 || height < 1 || width > 4096 || height > 4096 || width * height > 4194304 ||
      fl_value_get_length(rgba) != static_cast<size_t>(width * height * 4)) {
    error(call, "Invalid image dimensions"); return;
  }
  GBytes* bytes = g_bytes_new(fl_value_get_uint8_list(rgba), fl_value_get_length(rgba));
  GdkPixbuf* pixbuf = gdk_pixbuf_new_from_bytes(bytes, GDK_COLORSPACE_RGB, TRUE, 8,
                                               width, height, width * 4);
  g_bytes_unref(bytes);
  if (!pixbuf) { error(call, "Cannot create clipboard image"); return; }
  gtk_clipboard_set_image(clipboard, pixbuf);
  g_object_unref(pixbuf);
  respond(call, nullptr);
}
static void method(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* self = LRDP_NATIVE_PLUGIN(data);
  const char* name = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (g_str_equal(name, "fullscreen")) {
    GtkWidget* window = gtk_widget_get_toplevel(self->view);
    if (!GTK_IS_WINDOW(window) || !args || fl_value_get_type(args) != FL_VALUE_TYPE_BOOL) {
      error(call, "Invalid fullscreen request");
      return;
    }
    if (fl_value_get_bool(args)) gtk_window_fullscreen(GTK_WINDOW(window));
    else gtk_window_unfullscreen(GTK_WINDOW(window));
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    fl_method_call_respond(call, response, nullptr);
    return;
  }
  if (g_str_equal(name, "diagnostics")) {
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(result, "registered",
                             fl_value_new_int(g_hash_table_size(self->textures)));
    fl_value_set_string_take(result, "objects", fl_value_new_int(g_atomic_int_get(&live_textures)));
    fl_value_set_string_take(result, "contexts",
                             fl_value_new_int(g_atomic_int_get(&live_contexts)));
    fl_value_set_string_take(result, "gpuTextures",
                             fl_value_new_int(g_atomic_int_get(&live_gpu_names)));
    g_mutex_lock(&self->fallback->lock);
    fl_value_set_string_take(result, "sharedPlaceholder",
                             fl_value_new_int(self->fallback->name ? 1 : 0));
    g_mutex_unlock(&self->fallback->lock);
    fl_value_set_string_take(result, "uploadFailures",
                             fl_value_new_int(g_atomic_int_get(&upload_failures)));
    fl_value_set_string_take(result, "cleanupFailures",
                             fl_value_new_int(g_atomic_int_get(&cleanup_failures)));
    respond(call, result);
    return;
  }
  FlValue* number =
      fl_value_get_type(args) == FL_VALUE_TYPE_MAP
          ? fl_value_lookup_string(args, g_str_equal(name, "create") ? "ticket" : "id")
          : nullptr;
  if (!number || fl_value_get_type(number) != FL_VALUE_TYPE_INT || fl_value_get_int(number) <= 0) {
    error(call, "Invalid video handle");
    return;
  }
  int64_t id = fl_value_get_int(number);
  if (g_str_equal(name, "create")) {
    lrdp_video* video = lrdp_video_open(id);
    if (!video) {
      error(call, "Session has already ended");
      return;
    }
    auto* texture = LRDP_TEXTURE(g_object_new(lrdp_texture_get_type(), nullptr));
    texture->video = video;
    FlValue* rate = fl_value_lookup_string(args, "frameRate");
    if (rate && fl_value_get_type(rate) == FL_VALUE_TYPE_INT)
      texture->frame_rate = CLAMP(fl_value_get_int(rate), 1, 240);
    texture->fallback = fallback_ref(self->fallback);
    if (!fl_texture_registrar_register_texture(self->registrar, FL_TEXTURE(texture))) {
      g_object_unref(texture);
      error(call, "Texture registration failed");
      return;
    }
    id = fl_texture_get_id(FL_TEXTURE(texture));
    g_hash_table_insert(self->textures, GINT_TO_POINTER(id), texture);
    schedule_tick(self);
    g_autoptr(FlValue) result = status(texture);
    fl_value_set_string_take(result, "id", fl_value_new_int(id));
    respond(call, result);
    return;
  }
  auto* texture = LRDP_TEXTURE(g_hash_table_lookup(self->textures, GINT_TO_POINTER(id)));
  if (!texture) {
    error(call, "Texture is already closed");
    return;
  }
  if (g_str_equal(name, "status")) {
    g_autoptr(FlValue) result = status(texture);
    respond(call, result);
  } else if (g_str_equal(name, "visible")) {
    FlValue* visible = fl_value_lookup_string(args, "visible");
    if (!visible || fl_value_get_type(visible) != FL_VALUE_TYPE_BOOL) {
      error(call, "Invalid visibility");
      return;
    }
    g_mutex_lock(&texture->lock);
    texture->visible = fl_value_get_bool(visible);
    if (texture->visible) texture->announced = 0;
    texture->next_frame = 0;
    g_mutex_unlock(&texture->lock);
    if (texture->visible) schedule_tick(self);
    respond(call, nullptr);
  } else if (g_str_equal(name, "frameRate")) {
    FlValue* rate = fl_value_lookup_string(args, "frameRate");
    if (!rate || fl_value_get_type(rate) != FL_VALUE_TYPE_INT ||
        fl_value_get_int(rate) < 1 || fl_value_get_int(rate) > 240) {
      error(call, "Invalid frame rate");
      return;
    }
    g_mutex_lock(&texture->lock);
    texture->frame_rate = fl_value_get_int(rate);
    texture->next_frame = 0;
    g_mutex_unlock(&texture->lock);
    respond(call, nullptr);
  } else if (g_str_equal(name, "dispose")) {
    fl_texture_registrar_unregister_texture(self->registrar, FL_TEXTURE(texture));
    g_hash_table_remove(self->textures, GINT_TO_POINTER(id));
    respond(call, nullptr);
  } else {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
  }
}
static void plugin_dispose(GObject* object) {
  auto* self = LRDP_NATIVE_PLUGIN(object);
  if (self->tick) {
    gtk_widget_remove_tick_callback(self->view, self->tick);
    self->tick = 0;
  }
  if (self->textures) {
    GHashTableIter iter;
    gpointer value;
    g_hash_table_iter_init(&iter, self->textures);
    while (g_hash_table_iter_next(&iter, nullptr, &value))
      fl_texture_registrar_unregister_texture(self->registrar, FL_TEXTURE(value));
    g_clear_pointer(&self->textures, g_hash_table_unref);
  }
  g_clear_pointer(&self->fallback, fallback_unref);
  g_clear_object(&self->registrar);
  g_clear_object(&self->view);
  G_OBJECT_CLASS(lrdp_native_plugin_parent_class)->dispose(object);
}
static void lrdp_native_plugin_class_init(LrdpNativePluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = plugin_dispose;
}
static void lrdp_native_plugin_init(LrdpNativePlugin* self) {
  self->fallback = fallback_new();
  self->textures = g_hash_table_new_full(g_direct_hash, g_direct_equal, nullptr, g_object_unref);
}
void lrdp_native_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  auto* self = LRDP_NATIVE_PLUGIN(g_object_new(lrdp_native_plugin_get_type(), nullptr));
  self->registrar =
      FL_TEXTURE_REGISTRAR(g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar)));
  self->view = GTK_WIDGET(g_object_ref(fl_plugin_registrar_get_view(registrar)));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "dev.lrdp/video", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method, g_object_ref(self), g_object_unref);
  g_autoptr(FlMethodChannel) window_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "dev.lrdp/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(window_channel, method, g_object_ref(self), g_object_unref);
  g_autoptr(FlMethodChannel) clipboard_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "dev.lrdp/clipboard_image", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(clipboard_channel, clipboard_method, nullptr, nullptr);
  g_object_unref(self);
}
