/* Independent GTK clipboard owner/consumer on a disposable X11 display. */
#include <gtk/gtk.h>
#include <stdio.h>
#include <string.h>
static const char* directory;
static gboolean requested;
static const guchar expected[] = {255,0,0,255,0,255,0,255,0,0,255,255,
  255,255,255,255,0,0,0,255,0,255,255,255};
static void received(GtkClipboard* clipboard, GdkPixbuf* image, gpointer ignored) {
  (void)clipboard; (void)ignored;
  gboolean ok = image && gdk_pixbuf_get_width(image)==3 && gdk_pixbuf_get_height(image)==2;
  if (ok) {
    const guchar* pixels=gdk_pixbuf_get_pixels(image);
    int channels=gdk_pixbuf_get_n_channels(image),stride=gdk_pixbuf_get_rowstride(image);
    for(int y=0;y<2;y++) for(int x=0;x<3;x++) for(int c=0;c<4;c++) {
      guchar actual=c<channels ? pixels[y*stride+x*channels+c] : 255;
      if(actual!=expected[(y*3+x)*4+c]) ok=FALSE;
    }
  }
  char* path=g_build_filename(directory,"verified.json",NULL);
  g_file_set_contents(path,ok ? "{\"passed\":true}" : "{\"passed\":false}",-1,NULL); g_free(path);
}
static gboolean poll(gpointer ignored) {
  (void)ignored;
  char* path=g_build_filename(directory,"written",NULL);
  if(!requested && g_file_test(path,G_FILE_TEST_EXISTS)) {
    requested=TRUE; gtk_clipboard_request_image(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD),received,NULL);
  }
  g_free(path); return G_SOURCE_CONTINUE;
}
int main(int argc,char** argv) {
  if(argc!=2) return 2;
  directory=argv[1]; gtk_init(&argc,&argv);
  GBytes* bytes=g_bytes_new_static(expected,sizeof(expected));
  GdkPixbuf* image=gdk_pixbuf_new_from_bytes(bytes,GDK_COLORSPACE_RGB,TRUE,8,3,2,12);
  gtk_clipboard_set_image(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD),image);
  g_object_unref(image); g_bytes_unref(bytes);
  char* path=g_build_filename(directory,"ready",NULL); g_file_set_contents(path,"ready",-1,NULL); g_free(path);
  g_timeout_add(20,poll,NULL); gtk_main(); return 0;
}
