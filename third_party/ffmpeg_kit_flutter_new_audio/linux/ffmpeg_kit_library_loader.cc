#include "ffmpeg_kit_library_loader.h"

#include <dlfcn.h>
#include <unistd.h>

#include <string>

namespace {

// libffmpegkit.so and the FFmpeg libraries it links, each after the ones it
// needs. Flutter copies them into the bundle's lib/, next to this plugin, but
// nothing on the search path covers that directory for a dlopen() made from
// here: the runner's $ORIGIN/lib is a DT_RUNPATH, which glibc applies only to
// the runner's own dependencies; this plugin's run path is the build machine's
// linux/flutter/ephemeral; and the bundled libraries have none. Loaded by path
// in this order, each library's dependencies resolve, by soname, to the copies
// already loaded.
const char* const kBundledLibraries[] = {
    "libavutil.so",   "libswresample.so", "libswscale.so",  "libavcodec.so",
    "libavformat.so", "libavfilter.so",   "libavdevice.so", "libffmpegkit.so",
};

std::string plugin_directory() {
  Dl_info info;
  if (dladdr(reinterpret_cast<void*>(&plugin_directory), &info) == 0 ||
      info.dli_fname == nullptr) {
    return "";
  }
  const std::string path(info.dli_fname);
  const size_t slash = path.rfind('/');
  return slash == std::string::npos ? "" : path.substr(0, slash + 1);
}

}  // namespace

void* ffmpeg_kit_load_library() {
  const std::string dir = plugin_directory();
  if (!dir.empty() && access((dir + "libffmpegkit.so").c_str(), F_OK) == 0) {
    void* handle = nullptr;
    for (const char* name : kBundledLibraries) {
      const std::string path = dir + name;
      // A bundle may leave out a library its libffmpegkit.so doesn't link.
      if (access(path.c_str(), F_OK) != 0) continue;
      handle = dlopen(path.c_str(), RTLD_NOW | RTLD_GLOBAL);
      if (handle == nullptr) return nullptr;
    }
    return handle;
  }
  return dlopen("libffmpegkit.so", RTLD_NOW | RTLD_GLOBAL);
}
