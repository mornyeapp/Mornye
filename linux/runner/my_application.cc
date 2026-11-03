#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

// Smallest window, in logical pixels, that the desktop layouts support.
static constexpr gint kMinimumWidth = 800;
static constexpr gint kMinimumHeight = 600;

// Gap, in logical pixels, between a new mini player and the screen corner.
static constexpr gint kMiniPlayerScreenInset = 16;

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;

  GtkWindow* window;
  // Answers lib/widgets/desktop/desktop_window.dart.
  FlMethodChannel* window_channel;
  FlMethodChannel* audio_channel;
  FlValue* pending_audio;
  gboolean audio_ready;
  GtkWidget* header_bar;
  gboolean borderless;

  // Whether the window shows the mini player, and what it restores.
  gboolean mini_player;
  gint restore_x;
  gint restore_y;
  gint restore_width;
  gint restore_height;
  gboolean restore_maximized;
  gboolean restore_decorated;

  // Where the mini player last sat, by its top-left corner.
  gboolean has_mini_player_origin;
  gint mini_player_x;
  gint mini_player_y;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void audio_method_call_cb(FlMethodChannel* /*channel*/,
                                FlMethodCall* call, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (strcmp(fl_method_call_get_name(call), "takePending") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  self->audio_ready = TRUE;
  fl_method_call_respond_success(call, self->pending_audio, nullptr);
  g_clear_pointer(&self->pending_audio, fl_value_unref);
  self->pending_audio = fl_value_new_list();
}

static const gchar* window_mode(MyApplication* self) {
  GdkWindow* window = gtk_widget_get_window(GTK_WIDGET(self->window));
  if (window != nullptr &&
      (gdk_window_get_state(window) & GDK_WINDOW_STATE_FULLSCREEN)) {
    return "fullscreen";
  }
  return self->borderless ? "borderless" : "windowed";
}

static void notify_window_mode(MyApplication* self) {
  if (self->window_channel == nullptr) return;
  const gchar* mode = window_mode(self);
  if (self->header_bar != nullptr) {
    gtk_widget_set_visible(self->header_bar,
                           !self->mini_player && !self->borderless &&
                               strcmp(mode, "fullscreen") != 0);
  }
  g_autoptr(FlValue) value = fl_value_new_string(mode);
  fl_method_channel_invoke_method(self->window_channel, "windowModeChanged",
                                  value, nullptr, nullptr, nullptr);
}

static gboolean window_state_cb(GtkWidget* widget, GdkEventWindowState* event,
                                gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  notify_window_mode(self);
  return FALSE;
}

static gboolean set_window_mode(MyApplication* self, const gchar* mode) {
  if (self->window == nullptr || self->mini_player || mode == nullptr)
    return FALSE;
  if (strcmp(mode, "fullscreen") == 0) {
    gtk_window_fullscreen(self->window);
  } else if (strcmp(mode, "borderless") == 0 || strcmp(mode, "windowed") == 0) {
    self->borderless = strcmp(mode, "borderless") == 0;
    gtk_window_unfullscreen(self->window);
    gtk_window_set_decorated(self->window, !self->borderless);
  } else {
    return FALSE;
  }
  notify_window_mode(self);
  return TRUE;
}

static void set_minimum_size(GtkWindow* window, gint width, gint height) {
  GdkGeometry geometry = {};
  geometry.min_width = width;
  geometry.min_height = height;
  gtk_window_set_geometry_hints(window, nullptr, &geometry, GDK_HINT_MIN_SIZE);
}

// Turns the window into a small undecorated panel of |width| x |height| that
// stays above other windows, or resizes the panel when it already shows. It
// keeps its top-left corner when it resizes and opens where it last sat
// (first at the top right of the screen). Wayland compositors decide the
// position and stacking themselves, so there it only shrinks.
static gboolean open_mini_player(MyApplication* self, gdouble width,
                                 gdouble height) {
  GtkWindow* window = self->window;
  if (window == nullptr) return FALSE;
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  if (gdk_window != nullptr &&
      (gdk_window_get_state(gdk_window) & GDK_WINDOW_STATE_FULLSCREEN)) {
    return FALSE;
  }
  const gint panel_width = static_cast<gint>(lround(width));
  const gint panel_height = static_cast<gint>(lround(height));

  gint x = 0;
  gint y = 0;
  const gboolean opening = !self->mini_player;
  if (opening) {
    self->restore_maximized = gtk_window_is_maximized(window);
    if (self->restore_maximized) {
      // The maximized size is not a size to come back to.
      self->restore_width = 1280;
      self->restore_height = 800;
      gtk_window_unmaximize(window);
    } else {
      gtk_window_get_size(window, &self->restore_width,
                          &self->restore_height);
    }
    gtk_window_get_position(window, &self->restore_x, &self->restore_y);
    self->mini_player = TRUE;
    self->restore_decorated = gtk_window_get_decorated(window);
    gtk_window_set_decorated(window, FALSE);
    if (self->header_bar != nullptr) gtk_widget_hide(self->header_bar);
    gtk_window_set_keep_above(window, TRUE);
  }
  set_minimum_size(window, panel_width, panel_height);
  gtk_window_resize(window, panel_width, panel_height);

  gboolean has_origin = TRUE;
  if (!opening) {
    gtk_window_get_position(window, &x, &y);
  } else if (self->has_mini_player_origin) {
    x = self->mini_player_x;
    y = self->mini_player_y;
  } else {
    has_origin = FALSE;
  }

  // Keep the whole panel on the screen it opens on.
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkMonitor* monitor =
      has_origin ? gdk_display_get_monitor_at_point(display, x, y)
      : gdk_window != nullptr
          ? gdk_display_get_monitor_at_window(display, gdk_window)
          : gdk_display_get_primary_monitor(display);
  if (monitor == nullptr) monitor = gdk_display_get_monitor(display, 0);
  if (monitor != nullptr) {
    GdkRectangle work;
    gdk_monitor_get_workarea(monitor, &work);
    if (!has_origin) {
      x = work.x + work.width - panel_width - kMiniPlayerScreenInset;
      y = work.y + kMiniPlayerScreenInset;
    }
    x = CLAMP(x, work.x, MAX(work.x, work.x + work.width - panel_width));
    y = CLAMP(y, work.y, MAX(work.y, work.y + work.height - panel_height));
  }
  gtk_window_move(window, x, y);
  return TRUE;
}

// Returns the window to the decorations, size and place it had before.
static void close_mini_player(MyApplication* self) {
  GtkWindow* window = self->window;
  if (!self->mini_player || window == nullptr) return;
  gtk_window_get_position(window, &self->mini_player_x, &self->mini_player_y);
  self->has_mini_player_origin = TRUE;
  self->mini_player = FALSE;
  gtk_window_set_keep_above(window, FALSE);
  gtk_window_set_decorated(window, self->restore_decorated);
  if (self->header_bar != nullptr && self->restore_decorated)
    gtk_widget_show(self->header_bar);
  set_minimum_size(window, kMinimumWidth, kMinimumHeight);
  gtk_window_resize(window, self->restore_width, self->restore_height);
  gtk_window_move(window, self->restore_x, self->restore_y);
  if (self->restore_maximized) gtk_window_maximize(window);
}

// Moves the window with the pointer, as dragging a title bar does.
static void start_window_drag(MyApplication* self) {
  GtkWindow* window = self->window;
  if (window == nullptr || strcmp(window_mode(self), "fullscreen") == 0) return;
  GdkSeat* seat =
      gdk_display_get_default_seat(gtk_widget_get_display(GTK_WIDGET(window)));
  GdkDevice* pointer = seat != nullptr ? gdk_seat_get_pointer(seat) : nullptr;
  if (pointer == nullptr) return;
  gint root_x = 0;
  gint root_y = 0;
  gdk_device_get_position(pointer, nullptr, &root_x, &root_y);
  gtk_window_begin_move_drag(window, GDK_BUTTON_PRIMARY, root_x, root_y,
                             GDK_CURRENT_TIME);
}

static gdouble number_argument(FlValue* arguments, const gchar* key,
                               gdouble fallback) {
  if (arguments == nullptr ||
      fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
    return fallback;
  }
  FlValue* value = fl_value_lookup_string(arguments, key);
  if (value == nullptr) return fallback;
  switch (fl_value_get_type(value)) {
    case FL_VALUE_TYPE_FLOAT:
      return fl_value_get_float(value);
    case FL_VALUE_TYPE_INT:
      return static_cast<gdouble>(fl_value_get_int(value));
    default:
      return fallback;
  }
}

static void window_method_call_cb(FlMethodChannel* channel,
                                  FlMethodCall* method_call,
                                  gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* arguments = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "openMiniPlayer") == 0) {
    g_autoptr(FlValue) opened = fl_value_new_bool(open_mini_player(
        self, number_argument(arguments, "width", 360),
        number_argument(arguments, "height", 140)));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(opened));
  } else if (strcmp(method, "closeMiniPlayer") == 0) {
    close_mini_player(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "startDrag") == 0) {
    start_window_drag(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "getWindowMode") == 0) {
    g_autoptr(FlValue) value = fl_value_new_string(window_mode(self));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  } else if (strcmp(method, "isFullScreen") == 0) {
    g_autoptr(FlValue) value =
        fl_value_new_bool(strcmp(window_mode(self), "fullscreen") == 0);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  } else if (strcmp(method, "setWindowMode") == 0) {
    FlValue* mode = arguments != nullptr &&
                            fl_value_get_type(arguments) == FL_VALUE_TYPE_MAP
                        ? fl_value_lookup_string(arguments, "mode")
                        : nullptr;
    g_autoptr(FlValue) accepted = fl_value_new_bool(set_window_mode(
        self, mode != nullptr && fl_value_get_type(mode) == FL_VALUE_TYPE_STRING
                  ? fl_value_get_string(mode)
                  : nullptr));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(accepted));
  } else if (strcmp(method, "minimizeWindow") == 0) {
    gtk_window_iconify(self->window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "zoomWindow") == 0 ||
             strcmp(method, "titleBarDoubleClick") == 0) {
    if (gtk_window_is_maximized(self->window)) {
      gtk_window_unmaximize(self->window);
    } else if (strcmp(window_mode(self), "fullscreen") != 0) {
      gtk_window_maximize(self->window);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "closeWindow") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    gtk_window_close(self->window);
    return;
  } else if (strcmp(method, "startResize") == 0) {
    if (self->borderless && !self->mini_player) {
      FlValue* edge = arguments != nullptr &&
                              fl_value_get_type(arguments) == FL_VALUE_TYPE_MAP
                          ? fl_value_lookup_string(arguments, "edge")
                          : nullptr;
      const gboolean left =
          edge != nullptr && fl_value_get_type(edge) == FL_VALUE_TYPE_STRING &&
          strcmp(fl_value_get_string(edge), "bottomLeft") == 0;
      GdkSeat* seat = gdk_display_get_default_seat(
          gtk_widget_get_display(GTK_WIDGET(self->window)));
      GdkDevice* pointer =
          seat != nullptr ? gdk_seat_get_pointer(seat) : nullptr;
      if (pointer != nullptr) {
        gint x = 0;
        gint y = 0;
        gdk_device_get_position(pointer, nullptr, &x, &y);
        gtk_window_begin_resize_drag(
            self->window,
            left ? GDK_WINDOW_EDGE_SOUTH_WEST : GDK_WINDOW_EDGE_SOUTH_EAST,
            GDK_BUTTON_PRIMARY, x, y, GDK_CURRENT_TIME);
      }
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

// Only the deb installs a desktop entry for mornye://, so the browser cannot
// hand an extension callback back to a zip or AppImage copy. Points the
// per-user handler at this copy unless the current one already starts it.
static void register_url_scheme() {
  // An AppImage runs from a new mount on every launch; its file stays put.
  const gchar* appimage = g_getenv("APPIMAGE");
  g_autofree gchar* self_path =
      appimage != nullptr ? g_strdup(appimage)
                          : g_file_read_link("/proc/self/exe", nullptr);
  if (self_path == nullptr) return;
  g_autofree gchar* self_real = realpath(self_path, nullptr);

  g_autoptr(GAppInfo) current =
      g_app_info_get_default_for_uri_scheme("mornye");
  if (current != nullptr && self_real != nullptr) {
    const char* executable = g_app_info_get_executable(current);
    g_autofree gchar* found =
        executable != nullptr ? g_find_program_in_path(executable) : nullptr;
    g_autofree gchar* found_real =
        found != nullptr ? realpath(found, nullptr) : nullptr;
    if (g_strcmp0(found_real, self_real) == 0) return;
  }

  // GIO appends " %u" and writes a hidden entry plus the mimeapps default.
  g_autofree gchar* commandline = g_shell_quote(self_path);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GAppInfo) handler = g_app_info_create_from_commandline(
      commandline, "Mornye", G_APP_INFO_CREATE_SUPPORTS_URIS, &error);
  if (handler == nullptr ||
      !g_app_info_set_as_default_for_type(handler, "x-scheme-handler/mornye",
                                          &error)) {
    g_warning("Could not register the mornye:// handler: %s",
              error != nullptr ? error->message : "unknown error");
  }
}

static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // Single instance: a second launch activates the running window.
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows != nullptr) {
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }

  register_url_scheme();

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Mornye");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
    self->header_bar = GTK_WIDGET(header_bar);
  } else {
    gtk_window_set_title(window, "Mornye");
  }

  gtk_window_set_default_size(window, 1280, 800);
  set_minimum_size(window, kMinimumWidth, kMinimumHeight);

  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (executable != nullptr) {
    g_autofree gchar* bundle_dir = g_path_get_dirname(executable);
    g_autofree gchar* icon_path =
        g_build_filename(bundle_dir, "data", "mornye.png", nullptr);
    gtk_window_set_icon_from_file(window, icon_path, nullptr);
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  self->window = window;
  g_signal_connect(window, "window-state-event", G_CALLBACK(window_state_cb),
                   self);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "com.zarz.mornye/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->window_channel, window_method_call_cb, self, nullptr);
  self->audio_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "com.zarz.mornye/open_audio", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->audio_channel, audio_method_call_cb, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  // The primary instance creates its window (and registers the plugins)
  // before GLib emits "command-line", so app_links sees the launch URL.
  if (!g_application_get_is_remote(application)) {
    g_application_activate(application);
  }
  *exit_status = 0;

  // Not handled here: GLib sends the command line to the primary instance,
  // which emits "command-line" there. app_links reads a forwarded
  // mornye:// URL from it; the handler below raises the window.
  return FALSE;
}

static gint my_application_command_line(GApplication* application,
                                        GApplicationCommandLine* command_line) {
  g_application_activate(application);
  MyApplication* self = MY_APPLICATION(application);
  gint count = 0;
  g_auto(GStrv) args =
      g_application_command_line_get_arguments(command_line, &count);
  g_autoptr(FlValue) files = fl_value_new_list();
  for (gint i = 1; i < count; ++i) {
    if (args[i][0] == '-') continue;
    g_autofree gchar* scheme = g_uri_parse_scheme(args[i]);
    if (scheme != nullptr && strcmp(scheme, "file") != 0) continue;
    g_autoptr(GFile) file =
        g_application_command_line_create_file_for_arg(command_line, args[i]);
    g_autofree gchar* path = g_file_get_path(file);
    if (path != nullptr) fl_value_append_take(files, fl_value_new_string(path));
  }
  if (fl_value_get_length(files) != 0) {
    if (self->audio_ready) {
      fl_method_channel_invoke_method(self->audio_channel, "open", files,
                                      nullptr, nullptr, nullptr);
    } else if (fl_value_get_length(self->pending_audio) < 32) {
      fl_value_append(self->pending_audio, files);
    }
  }
  return 0;
}

static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

static void my_application_shutdown(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_channel);
  g_clear_object(&self->audio_channel);
  g_clear_pointer(&self->pending_audio, fl_value_unref);
  self->window = nullptr;
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->pending_audio = fl_value_new_list();
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // Unique on the session bus: later launches (for example a mornye://
  // callback from the browser, `Exec=mornye %u`) forward their whole command
  // line to this process. URLs arrive as arguments, so "open" is not used.
  return MY_APPLICATION(g_object_new(
      my_application_get_type(), "application-id", APPLICATION_ID, "flags",
      G_APPLICATION_HANDLES_COMMAND_LINE, nullptr));
}
