#
# Generated file, do not edit.
#

list(APPEND FLUTTER_PLUGIN_LIST
  app_links_linux
  audioplayers_linux
  desktop_drop
  dynamic_color
  ffmpeg_kit_flutter_new_audio
  flutter_secure_storage_linux
  media_kit_libs_linux
  record_linux
  url_launcher_linux
  volume_controller
)

list(APPEND FLUTTER_FFI_PLUGIN_LIST
  dart_smb2
  jni
)

set(PLUGIN_BUNDLED_LIBRARIES)

foreach(plugin ${FLUTTER_PLUGIN_LIST})
  add_subdirectory(flutter/ephemeral/.plugin_symlinks/${plugin}/linux plugins/${plugin})
  target_link_libraries(${BINARY_NAME} PRIVATE ${plugin}_plugin)
  list(APPEND PLUGIN_BUNDLED_LIBRARIES $<TARGET_FILE:${plugin}_plugin>)
  list(APPEND PLUGIN_BUNDLED_LIBRARIES ${${plugin}_bundled_libraries})
endforeach(plugin)

foreach(ffi_plugin ${FLUTTER_FFI_PLUGIN_LIST})
  add_subdirectory(flutter/ephemeral/.plugin_symlinks/${ffi_plugin}/linux plugins/${ffi_plugin})
  list(APPEND PLUGIN_BUNDLED_LIBRARIES ${${ffi_plugin}_bundled_libraries})
endforeach(ffi_plugin)
