#include "include/ffmpeg_kit_flutter_new_audio/f_fmpeg_kit_flutter_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <json-glib/json-glib.h>

#include <dlfcn.h>
#include <stdint.h>
#include <string.h>

#include "ffmpeg_kit_library_loader.h"

#define METHOD_CHANNEL_NAME "flutter.arthenica.com/ffmpeg_kit"
#define EVENT_CHANNEL_NAME  "flutter.arthenica.com/ffmpeg_kit_event"

#define EVENT_LOG        "FFmpegKitLogCallbackEvent"
#define EVENT_STATISTICS "FFmpegKitStatisticsCallbackEvent"
#define EVENT_COMPLETE   "FFmpegKitCompleteCallbackEvent"

/* --- native ABI -------------------------------------------------------------
 * Mirrors windows/ffmpeg_kit_flutter_plugin.h. Every symbol is resolved with
 * dlsym() rather than linked, so a variant that ships extra codec libraries
 * still loads and a missing symbol degrades to a clean error instead of a
 * failure to start the application.
 */
typedef void     (*FnVoid)(void);
typedef void     (*FnVoidLong)(long);
typedef void     (*FnVoidInt)(int);
typedef void     (*FnVoidLongInt)(long, int);
typedef void     (*FnVoidStr)(const char*);
typedef void     (*FnVoidStrStr)(const char*, const char*);
typedef char*    (*FnStrVoid)(void);
typedef char*    (*FnStrLong)(long);
typedef char*    (*FnStrLongInt)(long, int);
typedef char*    (*FnStrInt)(int);
typedef char*    (*FnStrStr)(const char*);
typedef char*    (*FnStrPtrInt)(const char**, int);
typedef int      (*FnIntVoid)(void);
typedef int      (*FnIntLong)(long);
typedef int64_t  (*FnInt64Long)(long);
typedef long     (*FnLongLong)(long);
typedef void     (*FnFreePtr)(void*);
typedef int      (*FnIntStrStr)(const char*, const char*);

typedef void (*LogCallbackFn)(long, int, const char*);
typedef void (*StatisticsCallbackFn)(long, int, float, float, int64_t, double, double, double);
typedef void (*SessionCompleteCallbackFn)(long, int);

typedef void (*FnEnableLogCallback)(LogCallbackFn);
typedef void (*FnEnableStatisticsCallback)(StatisticsCallbackFn);
typedef void (*FnEnableSessionCompleteCallback)(SessionCompleteCallbackFn);

struct _FFmpegKitFlutterPlugin {
  GObject parent_instance;

  FlPluginRegistrar* registrar;
  FlMethodChannel* method_channel;
  FlEventChannel* event_channel;

  gboolean listening;
  gboolean logs_enabled;
  gboolean statistics_enabled;

  void* lib;

  FnStrPtrInt   create_ffmpeg_session;
  FnStrPtrInt   create_ffprobe_session;
  FnStrPtrInt   create_media_info_session;
  FnInt64Long   session_get_end_time;
  FnLongLong    session_get_duration;
  FnIntLong     session_get_state;
  FnIntLong     session_get_return_code;
  FnStrLong     session_get_fail_stack_trace;
  FnIntLong     session_there_are_async_messages;
  FnStrLong     session_get_command;
  FnStrLongInt  session_get_all_logs_as_string;
  FnStrLong     session_get_logs_json;
  FnStrLongInt  session_get_all_logs_json;
  FnStrLong     session_get_statistics_json;
  FnStrLongInt  session_get_all_statistics_json;
  FnVoidLong    ffmpeg_execute;
  FnVoidLong    ffprobe_execute;
  FnVoidLongInt media_info_execute;
  FnVoidLong    async_ffmpeg_execute;
  FnVoidLong    async_ffprobe_execute;
  FnVoidLongInt async_media_info_execute;
  FnVoid        cancel;
  FnVoidLong    cancel_session;
  FnVoid        enable_redirection;
  FnVoid        disable_redirection;
  FnIntVoid     get_log_level;
  FnVoidInt     set_log_level;
  FnStrVoid     get_ffmpeg_version;
  FnIntVoid     is_lts_build;
  FnStrVoid     get_build_date;
  FnVoidStrStr  set_environment_variable;
  FnVoidInt     ignore_signal;
  FnIntVoid     get_session_history_size;
  FnVoidInt     set_session_history_size;
  FnStrVoid     register_new_pipe;
  FnVoidStr     close_pipe;
  FnVoidStr     set_fontconfig_path;
  FnVoidStrStr  set_font_directory;
  FnVoidStrStr  set_font_directory_list;
  FnIntVoid     get_log_redirection_strategy;
  FnVoidInt     set_log_redirection_strategy;
  FnIntLong     messages_in_transmit;
  FnStrVoid     get_platform;
  FnIntStrStr   write_to_pipe;
  FnStrLong     get_session_json;
  FnStrVoid     get_last_session_json;
  FnStrVoid     get_last_completed_session_json;
  FnStrVoid     get_sessions_json;
  FnVoid        clear_sessions;
  FnStrInt      get_sessions_by_state_json;
  FnStrVoid     get_ffmpeg_sessions_json;
  FnStrVoid     get_ffprobe_sessions_json;
  FnStrVoid     get_media_info_sessions_json;
  FnStrLong     get_media_information_json;
  FnStrStr      mi_parser_from;
  FnStrStr      mi_parser_from_with_error;
  FnStrVoid     get_package_name;
  FnStrVoid     get_external_libraries_json;
  FnStrVoid     get_arch;
  FnEnableLogCallback             enable_log_callback;
  FnEnableStatisticsCallback      enable_statistics_callback;
  FnEnableSessionCompleteCallback enable_ffmpeg_complete_callback;
  FnEnableSessionCompleteCallback enable_ffprobe_complete_callback;
  FnEnableSessionCompleteCallback enable_media_info_complete_callback;
  FnFreePtr     native_free;
};

G_DEFINE_TYPE(FFmpegKitFlutterPlugin, f_fmpeg_kit_flutter_plugin, g_object_get_type())

#define FFMPEG_KIT_FLUTTER_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), f_fmpeg_kit_flutter_plugin_get_type(), \
                              FFmpegKitFlutterPlugin))

/* The native callbacks are process-global, but a process can host several
 * FlutterEngines (background isolates, multi-window). Registering per-instance
 * would let the last engine to attach steal every event, so callbacks are
 * registered exactly once and broadcast to every attached plugin that has a
 * live event sink - the same fix applied to the Android plugin for #163. */
static GMutex   plugins_mutex;
static GSList*  plugins = NULL;                 /* FFmpegKitFlutterPlugin*, unowned */
static gboolean global_callbacks_registered = FALSE;

/* --- JSON -> FlValue --------------------------------------------------------
 * The native layer hands back JSON strings; Dart expects real maps and lists.
 */
static FlValue* json_node_to_fl_value(JsonNode* node);

static FlValue* json_object_to_fl_value(JsonObject* object) {
  FlValue* map = fl_value_new_map();
  JsonObjectIter iter;
  const gchar* name;
  JsonNode* member;
  json_object_iter_init(&iter, object);
  while (json_object_iter_next(&iter, &name, &member)) {
    g_autoptr(FlValue) value = json_node_to_fl_value(member);
    fl_value_set_string_take(map, name, fl_value_ref(value));
  }
  return map;
}

static FlValue* json_array_to_fl_value(JsonArray* array) {
  FlValue* list = fl_value_new_list();
  guint length = json_array_get_length(array);
  for (guint i = 0; i < length; i++) {
    g_autoptr(FlValue) value = json_node_to_fl_value(json_array_get_element(array, i));
    fl_value_append(list, value);
  }
  return list;
}

static FlValue* json_node_to_fl_value(JsonNode* node) {
  if (node == NULL || JSON_NODE_HOLDS_NULL(node)) return fl_value_new_null();
  switch (json_node_get_node_type(node)) {
    case JSON_NODE_OBJECT:
      return json_object_to_fl_value(json_node_get_object(node));
    case JSON_NODE_ARRAY:
      return json_array_to_fl_value(json_node_get_array(node));
    case JSON_NODE_VALUE: {
      GType t = json_node_get_value_type(node);
      if (t == G_TYPE_STRING)  return fl_value_new_string(json_node_get_string(node));
      if (t == G_TYPE_BOOLEAN) return fl_value_new_bool(json_node_get_boolean(node));
      if (t == G_TYPE_INT64)   return fl_value_new_int(json_node_get_int(node));
      if (t == G_TYPE_DOUBLE)  return fl_value_new_float(json_node_get_double(node));
      return fl_value_new_null();
    }
    default:
      return fl_value_new_null();
  }
}

/* Parses JSON and returns a new FlValue, or null on malformed input. Never
 * returns NULL, so callers can respond unconditionally. */
static FlValue* parse_json(const char* json) {
  if (json == NULL || *json == '\0') return fl_value_new_null();
  g_autoptr(JsonParser) parser = json_parser_new();
  g_autoptr(GError) error = NULL;
  if (!json_parser_load_from_data(parser, json, -1, &error)) {
    g_warning("ffmpeg_kit: failed to parse native JSON: %s", error->message);
    return fl_value_new_null();
  }
  return json_node_to_fl_value(json_parser_get_root(parser));
}

/* Takes ownership of a char* returned by the native layer, converts it, and
 * releases it with the allocator that produced it. */
static FlValue* take_json(FFmpegKitFlutterPlugin* self, char* json) {
  FlValue* value = parse_json(json);
  if (json != NULL && self->native_free != NULL) self->native_free(json);
  return value;
}

static FlValue* take_string(FFmpegKitFlutterPlugin* self, char* str) {
  FlValue* value = str != NULL ? fl_value_new_string(str) : fl_value_new_null();
  if (str != NULL && self->native_free != NULL) self->native_free(str);
  return value;
}

/* --- argument helpers ------------------------------------------------------- */

static FlValue* arg_get(FlValue* args, const char* key) {
  if (args == NULL || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return NULL;
  return fl_value_lookup_string(args, key);
}

static gboolean arg_int(FlValue* args, const char* key, int64_t* out) {
  FlValue* v = arg_get(args, key);
  if (v == NULL) return FALSE;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT)   { *out = fl_value_get_int(v);            return TRUE; }
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) { *out = (int64_t)fl_value_get_float(v); return TRUE; }
  return FALSE;
}

static const char* arg_string(FlValue* args, const char* key) {
  FlValue* v = arg_get(args, key);
  if (v == NULL || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return NULL;
  return fl_value_get_string(v);
}

static FlMethodResponse* error_response(const char* code, const char* message) {
  return FL_METHOD_RESPONSE(fl_method_error_response_new(code, message, nullptr));
}

/* --- event delivery ---------------------------------------------------------
 * Native callbacks arrive on FFmpeg worker threads. FlEventChannel must only be
 * touched on the thread running the main GLib context, so every event is
 * marshalled through g_idle_add.
 */
typedef struct {
  FlValue* event;      /* owned */
  gboolean logs_only;  /* respect per-plugin enable flags */
  gboolean stats_only;
} PendingEvent;

static gboolean emit_event_on_main(gpointer data) {
  PendingEvent* pending = static_cast<PendingEvent*>(data);

  g_mutex_lock(&plugins_mutex);
  for (GSList* l = plugins; l != NULL; l = l->next) {
    FFmpegKitFlutterPlugin* self = static_cast<FFmpegKitFlutterPlugin*>(l->data);
    if (!self->listening || self->event_channel == NULL) continue;
    if (pending->logs_only  && !self->logs_enabled)       continue;
    if (pending->stats_only && !self->statistics_enabled) continue;
    g_autoptr(GError) error = NULL;
    if (!fl_event_channel_send(self->event_channel, pending->event, NULL, &error)) {
      g_warning("ffmpeg_kit: failed to send event: %s", error->message);
    }
  }
  g_mutex_unlock(&plugins_mutex);

  fl_value_unref(pending->event);
  g_free(pending);
  return G_SOURCE_REMOVE;
}

static void post_event(FlValue* event, gboolean logs_only, gboolean stats_only) {
  PendingEvent* pending = g_new0(PendingEvent, 1);
  pending->event = event;  /* transfer */
  pending->logs_only = logs_only;
  pending->stats_only = stats_only;
  g_idle_add(emit_event_on_main, pending);
}

/* Wraps a payload as {"<EVENT_KEY>": payload}, matching the Dart decoder. */
static FlValue* wrap_event(const char* key, FlValue* payload) {
  FlValue* event = fl_value_new_map();
  fl_value_set_string_take(event, key, payload);
  return event;
}

static void on_native_log(long session_id, int level, const char* message) {
  FlValue* payload = fl_value_new_map();
  fl_value_set_string_take(payload, "sessionId", fl_value_new_int(session_id));
  fl_value_set_string_take(payload, "level", fl_value_new_int(level));
  fl_value_set_string_take(payload, "message",
                           fl_value_new_string(message != NULL ? message : ""));
  post_event(wrap_event(EVENT_LOG, payload), TRUE, FALSE);
}

static void on_native_statistics(long session_id, int video_frame_number,
                                 float video_fps, float video_quality, int64_t size,
                                 double time, double bitrate, double speed) {
  FlValue* payload = fl_value_new_map();
  fl_value_set_string_take(payload, "sessionId", fl_value_new_int(session_id));
  fl_value_set_string_take(payload, "videoFrameNumber", fl_value_new_int(video_frame_number));
  fl_value_set_string_take(payload, "videoFps", fl_value_new_float(video_fps));
  fl_value_set_string_take(payload, "videoQuality", fl_value_new_float(video_quality));
  fl_value_set_string_take(payload, "size", fl_value_new_int(size));
  fl_value_set_string_take(payload, "time", fl_value_new_float(time));
  fl_value_set_string_take(payload, "bitrate", fl_value_new_float(bitrate));
  fl_value_set_string_take(payload, "speed", fl_value_new_float(speed));
  post_event(wrap_event(EVENT_STATISTICS, payload), FALSE, TRUE);
}

/* Completion is never gated on the enable flags: Dart always needs to learn a
 * session finished, even with log and statistics redirection switched off. */
static void on_native_complete(long session_id, int /*type*/) {
  FlValue* payload = fl_value_new_map();
  fl_value_set_string_take(payload, "sessionId", fl_value_new_int(session_id));
  post_event(wrap_event(EVENT_COMPLETE, payload), FALSE, FALSE);
}

static void register_global_callbacks(FFmpegKitFlutterPlugin* self) {
  if (global_callbacks_registered) return;
  global_callbacks_registered = TRUE;
  if (self->enable_log_callback)        self->enable_log_callback(on_native_log);
  if (self->enable_statistics_callback) self->enable_statistics_callback(on_native_statistics);
  if (self->enable_ffmpeg_complete_callback)     self->enable_ffmpeg_complete_callback(on_native_complete);
  if (self->enable_ffprobe_complete_callback)    self->enable_ffprobe_complete_callback(on_native_complete);
  if (self->enable_media_info_complete_callback) self->enable_media_info_complete_callback(on_native_complete);
}

/* --- blocking execution off the platform thread -----------------------------
 * ffmpegSessionExecute and friends block for the whole transcode. Running them
 * inline would freeze the UI, so they run on a worker and the reply is handed
 * back through g_idle_add: FlMethodCall must be completed on the platform thread.
 */
typedef struct {
  FFmpegKitFlutterPlugin* self;
  FlMethodCall* call;   /* owned */
  long session_id;
  int wait_timeout;
  int kind;             /* 0 ffmpeg, 1 ffprobe, 2 media information */
} ExecuteTask;

static gboolean execute_finished(gpointer data) {
  ExecuteTask* task = static_cast<ExecuteTask*>(data);
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_null()));
  g_autoptr(GError) error = NULL;
  if (!fl_method_call_respond(task->call, response, &error)) {
    g_warning("ffmpeg_kit: failed to respond to execute: %s", error->message);
  }
  g_object_unref(task->call);
  g_free(task);
  return G_SOURCE_REMOVE;
}

static gpointer execute_worker(gpointer data) {
  ExecuteTask* task = static_cast<ExecuteTask*>(data);
  FFmpegKitFlutterPlugin* self = task->self;
  switch (task->kind) {
    case 0: if (self->ffmpeg_execute)  self->ffmpeg_execute(task->session_id);  break;
    case 1: if (self->ffprobe_execute) self->ffprobe_execute(task->session_id); break;
    default:
      if (self->media_info_execute) self->media_info_execute(task->session_id, task->wait_timeout);
      break;
  }
  g_idle_add(execute_finished, task);
  return NULL;
}

static void run_execute_async(FFmpegKitFlutterPlugin* self, FlMethodCall* call,
                              long session_id, int wait_timeout, int kind) {
  ExecuteTask* task = g_new0(ExecuteTask, 1);
  task->self = self;
  task->call = FL_METHOD_CALL(g_object_ref(call));
  task->session_id = session_id;
  task->wait_timeout = wait_timeout;
  task->kind = kind;
  g_thread_unref(g_thread_new("ffmpegkit-exec", execute_worker, task));
}

/* --- session creation ------------------------------------------------------- */

static FlMethodResponse* create_session(FFmpegKitFlutterPlugin* self, FlValue* args,
                                        FnStrPtrInt create) {
  if (create == NULL) return error_response("unsupported", "Session creation unavailable");
  FlValue* arguments = arg_get(args, "arguments");
  if (arguments == NULL || fl_value_get_type(arguments) != FL_VALUE_TYPE_LIST) {
    return error_response("invalid_arguments", "arguments must be a list of strings");
  }
  size_t count = fl_value_get_length(arguments);
  g_autofree const char** argv =
      static_cast<const char**>(g_malloc0(sizeof(char*) * (count + 1)));
  for (size_t i = 0; i < count; i++) {
    FlValue* item = fl_value_get_list_value(arguments, i);
    argv[i] = fl_value_get_type(item) == FL_VALUE_TYPE_STRING ? fl_value_get_string(item) : "";
  }
  g_autoptr(FlValue) session = take_json(self, create(argv, (int)count));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(session));
}

/* --- method dispatch -------------------------------------------------------- */

static void method_call_cb(FlMethodChannel* /*channel*/, FlMethodCall* call,
                           gpointer user_data) {
  FFmpegKitFlutterPlugin* self = static_cast<FFmpegKitFlutterPlugin*>(user_data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = NULL;

  if (self->lib == NULL) {
    response = error_response("library_unavailable",
                              "libffmpegkit.so could not be loaded");
    goto respond;
  }

  /* Shorthands. OK_* build a success response from a native call. */
#define OK(v)        (response = FL_METHOD_RESPONSE(fl_method_success_response_new(v)))
#define NEED(fn)     if (self->fn == NULL) { \
                       response = error_response("unsupported", #fn " unavailable"); \
                       goto respond; }
#define SESSION_ID(var) int64_t var = 0; \
                        if (!arg_int(args, "sessionId", &var)) { \
                          response = error_response("invalid_arguments", "sessionId is required"); \
                          goto respond; }

  if (g_strcmp0(method, "ffmpegSession") == 0) {
    response = create_session(self, args, self->create_ffmpeg_session);
  } else if (g_strcmp0(method, "ffprobeSession") == 0) {
    response = create_session(self, args, self->create_ffprobe_session);
  } else if (g_strcmp0(method, "mediaInformationSession") == 0) {
    response = create_session(self, args, self->create_media_info_session);

  /* --- session accessors --- */
  } else if (g_strcmp0(method, "abstractSessionGetEndTime") == 0) {
    NEED(session_get_end_time); SESSION_ID(id);
    OK(fl_value_new_int(self->session_get_end_time(id)));
  } else if (g_strcmp0(method, "abstractSessionGetDuration") == 0) {
    NEED(session_get_duration); SESSION_ID(id);
    OK(fl_value_new_int(self->session_get_duration(id)));
  } else if (g_strcmp0(method, "abstractSessionGetState") == 0) {
    NEED(session_get_state); SESSION_ID(id);
    OK(fl_value_new_int(self->session_get_state(id)));
  } else if (g_strcmp0(method, "abstractSessionGetReturnCode") == 0) {
    NEED(session_get_return_code); SESSION_ID(id);
    OK(fl_value_new_int(self->session_get_return_code(id)));
  } else if (g_strcmp0(method, "abstractSessionGetFailStackTrace") == 0) {
    NEED(session_get_fail_stack_trace); SESSION_ID(id);
    OK(take_string(self, self->session_get_fail_stack_trace(id)));
  } else if (g_strcmp0(method, "thereAreAsynchronousMessagesInTransmit") == 0) {
    NEED(session_there_are_async_messages); SESSION_ID(id);
    OK(fl_value_new_bool(self->session_there_are_async_messages(id) != 0));
  } else if (g_strcmp0(method, "abstractSessionGetLogs") == 0) {
    NEED(session_get_logs_json); SESSION_ID(id);
    OK(take_json(self, self->session_get_logs_json(id)));
  } else if (g_strcmp0(method, "abstractSessionGetAllLogs") == 0) {
    NEED(session_get_all_logs_json); SESSION_ID(id);
    int64_t timeout = 5000; arg_int(args, "waitTimeout", &timeout);
    OK(take_json(self, self->session_get_all_logs_json(id, (int)timeout)));
  } else if (g_strcmp0(method, "abstractSessionGetAllLogsAsString") == 0) {
    NEED(session_get_all_logs_as_string); SESSION_ID(id);
    int64_t timeout = 5000; arg_int(args, "waitTimeout", &timeout);
    OK(take_string(self, self->session_get_all_logs_as_string(id, (int)timeout)));
  } else if (g_strcmp0(method, "ffmpegSessionGetStatistics") == 0) {
    NEED(session_get_statistics_json); SESSION_ID(id);
    OK(take_json(self, self->session_get_statistics_json(id)));
  } else if (g_strcmp0(method, "ffmpegSessionGetAllStatistics") == 0) {
    NEED(session_get_all_statistics_json); SESSION_ID(id);
    int64_t timeout = 5000; arg_int(args, "waitTimeout", &timeout);
    OK(take_json(self, self->session_get_all_statistics_json(id, (int)timeout)));

  /* --- execution --- */
  } else if (g_strcmp0(method, "ffmpegSessionExecute") == 0) {
    NEED(ffmpeg_execute); SESSION_ID(id);
    run_execute_async(self, call, id, 0, 0);
    return;  /* responded from the worker */
  } else if (g_strcmp0(method, "ffprobeSessionExecute") == 0) {
    NEED(ffprobe_execute); SESSION_ID(id);
    run_execute_async(self, call, id, 0, 1);
    return;
  } else if (g_strcmp0(method, "mediaInformationSessionExecute") == 0) {
    NEED(media_info_execute); SESSION_ID(id);
    int64_t timeout = 5000; arg_int(args, "waitTimeout", &timeout);
    run_execute_async(self, call, id, (int)timeout, 2);
    return;
  } else if (g_strcmp0(method, "asyncFFmpegSessionExecute") == 0) {
    NEED(async_ffmpeg_execute); SESSION_ID(id);
    self->async_ffmpeg_execute(id);
    OK(fl_value_new_null());
  } else if (g_strcmp0(method, "asyncFFprobeSessionExecute") == 0) {
    NEED(async_ffprobe_execute); SESSION_ID(id);
    self->async_ffprobe_execute(id);
    OK(fl_value_new_null());
  } else if (g_strcmp0(method, "asyncMediaInformationSessionExecute") == 0) {
    NEED(async_media_info_execute); SESSION_ID(id);
    int64_t timeout = 5000; arg_int(args, "waitTimeout", &timeout);
    self->async_media_info_execute(id, (int)timeout);
    OK(fl_value_new_null());
  } else if (g_strcmp0(method, "cancel") == 0) {
    NEED(cancel); self->cancel(); OK(fl_value_new_null());
  } else if (g_strcmp0(method, "cancelSession") == 0) {
    NEED(cancel_session); SESSION_ID(id);
    self->cancel_session(id); OK(fl_value_new_null());

  /* --- redirection / callbacks --- */
  } else if (g_strcmp0(method, "enableRedirection") == 0) {
    NEED(enable_redirection); self->enable_redirection(); OK(fl_value_new_null());
  } else if (g_strcmp0(method, "disableRedirection") == 0) {
    NEED(disable_redirection); self->disable_redirection(); OK(fl_value_new_null());
  } else if (g_strcmp0(method, "enableLogs") == 0) {
    self->logs_enabled = TRUE;  OK(fl_value_new_null());
  } else if (g_strcmp0(method, "disableLogs") == 0) {
    self->logs_enabled = FALSE; OK(fl_value_new_null());
  } else if (g_strcmp0(method, "enableStatistics") == 0) {
    self->statistics_enabled = TRUE;  OK(fl_value_new_null());
  } else if (g_strcmp0(method, "disableStatistics") == 0) {
    self->statistics_enabled = FALSE; OK(fl_value_new_null());
  } else if (g_strcmp0(method, "getLogRedirectionStrategy") == 0) {
    NEED(get_log_redirection_strategy);
    OK(fl_value_new_int(self->get_log_redirection_strategy()));
  } else if (g_strcmp0(method, "setLogRedirectionStrategy") == 0) {
    NEED(set_log_redirection_strategy);
    int64_t strategy = 0; arg_int(args, "strategy", &strategy);
    self->set_log_redirection_strategy((int)strategy); OK(fl_value_new_null());
  } else if (g_strcmp0(method, "messagesInTransmit") == 0) {
    NEED(messages_in_transmit); SESSION_ID(id);
    OK(fl_value_new_int(self->messages_in_transmit(id)));

  /* --- configuration --- */
  } else if (g_strcmp0(method, "getLogLevel") == 0) {
    NEED(get_log_level); OK(fl_value_new_int(self->get_log_level()));
  } else if (g_strcmp0(method, "setLogLevel") == 0) {
    NEED(set_log_level);
    int64_t level = 0; arg_int(args, "level", &level);
    self->set_log_level((int)level); OK(fl_value_new_null());
  } else if (g_strcmp0(method, "getFFmpegVersion") == 0) {
    NEED(get_ffmpeg_version); OK(take_string(self, self->get_ffmpeg_version()));
  } else if (g_strcmp0(method, "isLTSBuild") == 0) {
    NEED(is_lts_build); OK(fl_value_new_bool(self->is_lts_build() != 0));
  } else if (g_strcmp0(method, "getBuildDate") == 0) {
    NEED(get_build_date); OK(take_string(self, self->get_build_date()));
  } else if (g_strcmp0(method, "setEnvironmentVariable") == 0) {
    NEED(set_environment_variable);
    const char* name = arg_string(args, "variableName");
    const char* value = arg_string(args, "variableValue");
    if (name == NULL) { response = error_response("invalid_arguments", "variableName is required"); goto respond; }
    self->set_environment_variable(name, value != NULL ? value : "");
    OK(fl_value_new_null());
  } else if (g_strcmp0(method, "ignoreSignal") == 0) {
    NEED(ignore_signal);
    int64_t signum = 0; arg_int(args, "signal", &signum);
    self->ignore_signal((int)signum); OK(fl_value_new_null());
  } else if (g_strcmp0(method, "getSessionHistorySize") == 0) {
    NEED(get_session_history_size); OK(fl_value_new_int(self->get_session_history_size()));
  } else if (g_strcmp0(method, "setSessionHistorySize") == 0) {
    NEED(set_session_history_size);
    int64_t size = 0; arg_int(args, "sessionHistorySize", &size);
    self->set_session_history_size((int)size); OK(fl_value_new_null());
  } else if (g_strcmp0(method, "getPlatform") == 0) {
    NEED(get_platform); OK(take_string(self, self->get_platform()));
  } else if (g_strcmp0(method, "getArch") == 0) {
    NEED(get_arch); OK(take_string(self, self->get_arch()));
  } else if (g_strcmp0(method, "getPackageName") == 0) {
    NEED(get_package_name); OK(take_string(self, self->get_package_name()));
  } else if (g_strcmp0(method, "getExternalLibraries") == 0) {
    NEED(get_external_libraries_json);
    OK(take_json(self, self->get_external_libraries_json()));

  /* --- fonts and pipes --- */
  } else if (g_strcmp0(method, "setFontconfigConfigurationPath") == 0) {
    NEED(set_fontconfig_path);
    const char* path = arg_string(args, "path");
    if (path == NULL) { response = error_response("invalid_arguments", "path is required"); goto respond; }
    self->set_fontconfig_path(path); OK(fl_value_new_null());
  } else if (g_strcmp0(method, "setFontDirectory") == 0 ||
             g_strcmp0(method, "setFontDirectoryList") == 0) {
    gboolean is_list = g_strcmp0(method, "setFontDirectoryList") == 0;
    NEED(set_font_directory);
    if (is_list) NEED(set_font_directory_list);
    /* fontNameMap is a Dart Map; the native ABI takes it as a JSON string. */
    g_autofree gchar* mapping = NULL;
    FlValue* font_map = arg_get(args, "fontNameMap");
    if (font_map != NULL && fl_value_get_type(font_map) == FL_VALUE_TYPE_MAP) {
      g_autoptr(JsonBuilder) builder = json_builder_new();
      json_builder_begin_object(builder);
      size_t n = fl_value_get_length(font_map);
      for (size_t i = 0; i < n; i++) {
        FlValue* k = fl_value_get_map_key(font_map, i);
        FlValue* v = fl_value_get_map_value(font_map, i);
        if (fl_value_get_type(k) != FL_VALUE_TYPE_STRING ||
            fl_value_get_type(v) != FL_VALUE_TYPE_STRING) continue;
        json_builder_set_member_name(builder, fl_value_get_string(k));
        json_builder_add_string_value(builder, fl_value_get_string(v));
      }
      json_builder_end_object(builder);
      g_autoptr(JsonGenerator) generator = json_generator_new();
      g_autoptr(JsonNode) root = json_builder_get_root(builder);
      json_generator_set_root(generator, root);
      mapping = json_generator_to_data(generator, NULL);
    }
    if (is_list) {
      const char* list = arg_string(args, "fontDirectoryList");
      self->set_font_directory_list(list != NULL ? list : "", mapping != NULL ? mapping : "{}");
    } else {
      const char* dir = arg_string(args, "fontDirectory");
      self->set_font_directory(dir != NULL ? dir : "", mapping != NULL ? mapping : "{}");
    }
    OK(fl_value_new_null());
  } else if (g_strcmp0(method, "registerNewFFmpegPipe") == 0) {
    NEED(register_new_pipe); OK(take_string(self, self->register_new_pipe()));
  } else if (g_strcmp0(method, "closeFFmpegPipe") == 0) {
    NEED(close_pipe);
    const char* pipe_path = arg_string(args, "ffmpegPipePath");
    if (pipe_path == NULL) { response = error_response("invalid_arguments", "ffmpegPipePath is required"); goto respond; }
    self->close_pipe(pipe_path); OK(fl_value_new_null());
  } else if (g_strcmp0(method, "writeToPipe") == 0) {
    NEED(write_to_pipe);
    const char* input = arg_string(args, "input");
    const char* pipe_path = arg_string(args, "pipe");
    if (input == NULL || pipe_path == NULL) { response = error_response("invalid_arguments", "input and pipe are required"); goto respond; }
    OK(fl_value_new_int(self->write_to_pipe(input, pipe_path)));

  /* --- session registry --- */
  } else if (g_strcmp0(method, "getSession") == 0) {
    NEED(get_session_json); SESSION_ID(id);
    OK(take_json(self, self->get_session_json(id)));
  } else if (g_strcmp0(method, "getLastSession") == 0) {
    NEED(get_last_session_json); OK(take_json(self, self->get_last_session_json()));
  } else if (g_strcmp0(method, "getLastCompletedSession") == 0) {
    NEED(get_last_completed_session_json);
    OK(take_json(self, self->get_last_completed_session_json()));
  } else if (g_strcmp0(method, "getSessions") == 0) {
    NEED(get_sessions_json); OK(take_json(self, self->get_sessions_json()));
  } else if (g_strcmp0(method, "clearSessions") == 0) {
    NEED(clear_sessions); self->clear_sessions(); OK(fl_value_new_null());
  } else if (g_strcmp0(method, "getSessionsByState") == 0) {
    NEED(get_sessions_by_state_json);
    int64_t state = 0; arg_int(args, "state", &state);
    OK(take_json(self, self->get_sessions_by_state_json((int)state)));
  } else if (g_strcmp0(method, "getFFmpegSessions") == 0) {
    NEED(get_ffmpeg_sessions_json); OK(take_json(self, self->get_ffmpeg_sessions_json()));
  } else if (g_strcmp0(method, "getFFprobeSessions") == 0) {
    NEED(get_ffprobe_sessions_json); OK(take_json(self, self->get_ffprobe_sessions_json()));
  } else if (g_strcmp0(method, "getMediaInformationSessions") == 0) {
    NEED(get_media_info_sessions_json);
    OK(take_json(self, self->get_media_info_sessions_json()));

  /* --- media information --- */
  } else if (g_strcmp0(method, "getMediaInformation") == 0 ||
             g_strcmp0(method, "mediaInformationSessionGetMediaInformation") == 0) {
    NEED(get_media_information_json); SESSION_ID(id);
    OK(take_json(self, self->get_media_information_json(id)));
  } else if (g_strcmp0(method, "mediaInformationJsonParserFrom") == 0) {
    NEED(mi_parser_from);
    const char* json = arg_string(args, "ffprobeJsonOutput");
    if (json == NULL) { response = error_response("invalid_arguments", "ffprobeJsonOutput is required"); goto respond; }
    OK(take_json(self, self->mi_parser_from(json)));
  } else if (g_strcmp0(method, "mediaInformationJsonParserFromWithError") == 0) {
    NEED(mi_parser_from_with_error);
    const char* json = arg_string(args, "ffprobeJsonOutput");
    if (json == NULL) { response = error_response("invalid_arguments", "ffprobeJsonOutput is required"); goto respond; }
    OK(take_json(self, self->mi_parser_from_with_error(json)));

  /* selectDocument and getSafParameter are Storage Access Framework calls and
   * exist only on Android; the Dart layer guards on platform but answers the
   * not-implemented contract if it ever reaches here. */
  } else if (g_strcmp0(method, "selectDocument") == 0 ||
             g_strcmp0(method, "getSafParameter") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

#undef OK
#undef NEED
#undef SESSION_ID

respond:
  if (response == NULL) {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  g_autoptr(GError) error = NULL;
  if (!fl_method_call_respond(call, response, &error)) {
    g_warning("ffmpeg_kit: failed to respond to %s: %s", method, error->message);
  }
}

/* --- event channel ---------------------------------------------------------- */

static FlMethodErrorResponse* listen_cb(FlEventChannel* /*channel*/, FlValue* /*args*/,
                                        gpointer user_data) {
  FFmpegKitFlutterPlugin* self = static_cast<FFmpegKitFlutterPlugin*>(user_data);
  self->listening = TRUE;
  return NULL;
}

static FlMethodErrorResponse* cancel_cb(FlEventChannel* /*channel*/, FlValue* /*args*/,
                                        gpointer user_data) {
  FFmpegKitFlutterPlugin* self = static_cast<FFmpegKitFlutterPlugin*>(user_data);
  self->listening = FALSE;
  return NULL;
}

/* --- lifecycle -------------------------------------------------------------- */

static gboolean load_native_library(FFmpegKitFlutterPlugin* self) {
  self->lib = ffmpeg_kit_load_library();
  if (self->lib == NULL) {
    g_warning("ffmpeg_kit: loading libffmpegkit.so failed: %s", dlerror());
    return FALSE;
  }

#define SYM(field, type, name) self->field = reinterpret_cast<type>(dlsym(self->lib, name))
  SYM(create_ffmpeg_session,     FnStrPtrInt,   "ffmpegkit_create_ffmpeg_session");
  SYM(create_ffprobe_session,    FnStrPtrInt,   "ffmpegkit_create_ffprobe_session");
  SYM(create_media_info_session, FnStrPtrInt,   "ffmpegkit_create_media_information_session");
  SYM(session_get_end_time,      FnInt64Long,   "ffmpegkit_session_get_end_time");
  SYM(session_get_duration,      FnLongLong,    "ffmpegkit_session_get_duration");
  SYM(session_get_state,         FnIntLong,     "ffmpegkit_session_get_state");
  SYM(session_get_return_code,   FnIntLong,     "ffmpegkit_session_get_return_code");
  SYM(session_get_fail_stack_trace, FnStrLong,  "ffmpegkit_session_get_fail_stack_trace");
  SYM(session_there_are_async_messages, FnIntLong, "ffmpegkit_session_there_are_async_messages");
  SYM(session_get_command,       FnStrLong,     "ffmpegkit_session_get_command");
  SYM(session_get_all_logs_as_string, FnStrLongInt, "ffmpegkit_session_get_all_logs_as_string");
  SYM(session_get_logs_json,     FnStrLong,     "ffmpegkit_session_get_logs_json");
  SYM(session_get_all_logs_json, FnStrLongInt,  "ffmpegkit_session_get_all_logs_json");
  SYM(session_get_statistics_json, FnStrLong,   "ffmpegkit_session_get_statistics_json");
  SYM(session_get_all_statistics_json, FnStrLongInt, "ffmpegkit_session_get_all_statistics_json");
  SYM(ffmpeg_execute,            FnVoidLong,    "ffmpegkit_ffmpeg_execute");
  SYM(ffprobe_execute,           FnVoidLong,    "ffmpegkit_ffprobe_execute");
  SYM(media_info_execute,        FnVoidLongInt, "ffmpegkit_media_information_execute");
  SYM(async_ffmpeg_execute,      FnVoidLong,    "ffmpegkit_async_ffmpeg_execute");
  SYM(async_ffprobe_execute,     FnVoidLong,    "ffmpegkit_async_ffprobe_execute");
  SYM(async_media_info_execute,  FnVoidLongInt, "ffmpegkit_async_media_information_execute");
  SYM(cancel,                    FnVoid,        "ffmpegkit_cancel");
  SYM(cancel_session,            FnVoidLong,    "ffmpegkit_cancel_session");
  SYM(enable_redirection,        FnVoid,        "ffmpegkit_enable_redirection");
  SYM(disable_redirection,       FnVoid,        "ffmpegkit_disable_redirection");
  SYM(get_log_level,             FnIntVoid,     "ffmpegkit_get_log_level");
  SYM(set_log_level,             FnVoidInt,     "ffmpegkit_set_log_level");
  SYM(get_ffmpeg_version,        FnStrVoid,     "ffmpegkit_get_ffmpeg_version");
  SYM(is_lts_build,              FnIntVoid,     "ffmpegkit_is_lts_build");
  SYM(get_build_date,            FnStrVoid,     "ffmpegkit_get_build_date");
  SYM(set_environment_variable,  FnVoidStrStr,  "ffmpegkit_set_environment_variable");
  SYM(ignore_signal,             FnVoidInt,     "ffmpegkit_ignore_signal");
  SYM(get_session_history_size,  FnIntVoid,     "ffmpegkit_get_session_history_size");
  SYM(set_session_history_size,  FnVoidInt,     "ffmpegkit_set_session_history_size");
  SYM(register_new_pipe,         FnStrVoid,     "ffmpegkit_register_new_pipe");
  SYM(close_pipe,                FnVoidStr,     "ffmpegkit_close_pipe");
  SYM(set_fontconfig_path,       FnVoidStr,     "ffmpegkit_set_fontconfig_configuration_path");
  SYM(set_font_directory,        FnVoidStrStr,  "ffmpegkit_set_font_directory");
  SYM(set_font_directory_list,   FnVoidStrStr,  "ffmpegkit_set_font_directory_list");
  SYM(get_log_redirection_strategy, FnIntVoid,  "ffmpegkit_get_log_redirection_strategy");
  SYM(set_log_redirection_strategy, FnVoidInt,  "ffmpegkit_set_log_redirection_strategy");
  SYM(messages_in_transmit,      FnIntLong,     "ffmpegkit_messages_in_transmit");
  SYM(get_platform,              FnStrVoid,     "ffmpegkit_get_platform");
  SYM(write_to_pipe,             FnIntStrStr,   "ffmpegkit_write_to_pipe");
  SYM(get_session_json,          FnStrLong,     "ffmpegkit_get_session_json");
  SYM(get_last_session_json,     FnStrVoid,     "ffmpegkit_get_last_session_json");
  SYM(get_last_completed_session_json, FnStrVoid, "ffmpegkit_get_last_completed_session_json");
  SYM(get_sessions_json,         FnStrVoid,     "ffmpegkit_get_sessions_json");
  SYM(clear_sessions,            FnVoid,        "ffmpegkit_clear_sessions");
  SYM(get_sessions_by_state_json, FnStrInt,     "ffmpegkit_get_sessions_by_state_json");
  SYM(get_ffmpeg_sessions_json,  FnStrVoid,     "ffmpegkit_get_ffmpeg_sessions_json");
  SYM(get_ffprobe_sessions_json, FnStrVoid,     "ffmpegkit_get_ffprobe_sessions_json");
  SYM(get_media_info_sessions_json, FnStrVoid,  "ffmpegkit_get_media_information_sessions_json");
  SYM(get_media_information_json, FnStrLong,    "ffmpegkit_get_media_information_json");
  SYM(mi_parser_from,            FnStrStr,      "ffmpegkit_media_information_json_parser_from");
  SYM(mi_parser_from_with_error, FnStrStr,      "ffmpegkit_media_information_json_parser_from_with_error");
  SYM(get_package_name,          FnStrVoid,     "ffmpegkit_get_package_name");
  SYM(get_external_libraries_json, FnStrVoid,   "ffmpegkit_get_external_libraries_json");
  SYM(get_arch,                  FnStrVoid,     "ffmpegkit_get_arch");
  SYM(enable_log_callback,        FnEnableLogCallback,        "ffmpegkit_enable_log_callback");
  SYM(enable_statistics_callback, FnEnableStatisticsCallback, "ffmpegkit_enable_statistics_callback");
  SYM(enable_ffmpeg_complete_callback,     FnEnableSessionCompleteCallback, "ffmpegkit_enable_ffmpeg_session_complete_callback");
  SYM(enable_ffprobe_complete_callback,    FnEnableSessionCompleteCallback, "ffmpegkit_enable_ffprobe_session_complete_callback");
  SYM(enable_media_info_complete_callback, FnEnableSessionCompleteCallback, "ffmpegkit_enable_media_information_session_complete_callback");
  SYM(native_free,               FnFreePtr,     "ffmpegkit_free");
#undef SYM

  return TRUE;
}

static void f_fmpeg_kit_flutter_plugin_dispose(GObject* object) {
  FFmpegKitFlutterPlugin* self = FFMPEG_KIT_FLUTTER_PLUGIN(object);

  g_mutex_lock(&plugins_mutex);
  plugins = g_slist_remove(plugins, self);
  g_mutex_unlock(&plugins_mutex);

  g_clear_object(&self->method_channel);
  g_clear_object(&self->event_channel);
  g_clear_object(&self->registrar);

  /* libffmpegkit.so is deliberately NOT dlclose()d: the native layer keeps
   * global callback pointers into this module and worker threads may still be
   * winding down, so unmapping it while another engine is live would crash. */

  G_OBJECT_CLASS(f_fmpeg_kit_flutter_plugin_parent_class)->dispose(object);
}

static void f_fmpeg_kit_flutter_plugin_class_init(FFmpegKitFlutterPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = f_fmpeg_kit_flutter_plugin_dispose;
}

static void f_fmpeg_kit_flutter_plugin_init(FFmpegKitFlutterPlugin* self) {
  self->listening = FALSE;
  self->logs_enabled = TRUE;
  self->statistics_enabled = TRUE;
}

void f_fmpeg_kit_flutter_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  FFmpegKitFlutterPlugin* plugin = FFMPEG_KIT_FLUTTER_PLUGIN(
      g_object_new(f_fmpeg_kit_flutter_plugin_get_type(), nullptr));
  plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));

  g_autoptr(FlStandardMethodCodec) method_codec = fl_standard_method_codec_new();
  plugin->method_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), METHOD_CHANNEL_NAME,
      FL_METHOD_CODEC(method_codec));
  fl_method_channel_set_method_call_handler(
      plugin->method_channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  g_autoptr(FlStandardMethodCodec) event_codec = fl_standard_method_codec_new();
  plugin->event_channel = fl_event_channel_new(
      fl_plugin_registrar_get_messenger(registrar), EVENT_CHANNEL_NAME,
      FL_METHOD_CODEC(event_codec));
  fl_event_channel_set_stream_handlers(
      plugin->event_channel, listen_cb, cancel_cb, g_object_ref(plugin), g_object_unref);

  if (load_native_library(plugin)) {
    g_mutex_lock(&plugins_mutex);
    plugins = g_slist_prepend(plugins, plugin);
    g_mutex_unlock(&plugins_mutex);
    register_global_callbacks(plugin);
  }

  g_object_unref(plugin);
}
