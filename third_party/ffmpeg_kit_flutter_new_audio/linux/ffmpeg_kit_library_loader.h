#ifndef FFMPEG_KIT_LIBRARY_LOADER_H_
#define FFMPEG_KIT_LIBRARY_LOADER_H_

// Loads libffmpegkit.so from the directory this plugin's library was loaded
// from, where Flutter bundles it, or else from the library search path.
// Returns the dlopen() handle, or NULL with dlerror() saying why.
void* ffmpeg_kit_load_library();

#endif  // FFMPEG_KIT_LIBRARY_LOADER_H_
