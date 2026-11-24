#include "system_unwinder.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <string>

// Set for the one restart, so a preload that did not take cannot loop.
static const char kRestarted[] = "MORNYE_UNWINDER_RESTARTED";
// The LD_PRELOAD the app was started with, given back after the restart.
static const char kOwnPreload[] = "MORNYE_UNWINDER_OWN_PRELOAD";
static const char kSystemUnwinder[] = "libgcc_s.so.1";

// Whether a library that asks for the unwinder gets the engine's copy.
static bool engine_unwinder_comes_first() {
  void* raise = dlsym(RTLD_DEFAULT, "_Unwind_RaiseException");
  Dl_info library;
  if (raise == nullptr || dladdr(raise, &library) == 0 ||
      library.dli_fname == nullptr) {
    return false;
  }
  return strstr(library.dli_fname, "libflutter_linux_gtk") != nullptr;
}

void use_system_unwinder(char** argv) {
  if (getenv(kRestarted) != nullptr) {
    // The preload is for this process only: programs the app starts (FFmpeg,
    // the updater, the app itself) get the environment it was given.
    const char* own = getenv(kOwnPreload);
    if (own != nullptr) {
      setenv("LD_PRELOAD", own, 1);
    } else {
      unsetenv("LD_PRELOAD");
    }
    unsetenv(kOwnPreload);
    unsetenv(kRestarted);
    if (engine_unwinder_comes_first()) {
      fprintf(stderr,
              "mornye: %s could not be preloaded; an error inside a system "
              "library may close the app.\n",
              kSystemUnwinder);
    }
    return;
  }
  if (!engine_unwinder_comes_first()) {
    return;
  }

  // Copied: setting the variable below ends the life of what getenv gave.
  const char* given = getenv("LD_PRELOAD");
  const std::string own = given != nullptr ? given : "";
  std::string preload = kSystemUnwinder;
  if (!own.empty()) {
    setenv(kOwnPreload, own.c_str(), 1);
    preload += ':';
    preload += own;
  }
  setenv("LD_PRELOAD", preload.c_str(), 1);
  setenv(kRestarted, "1", 1);
  execv("/proc/self/exe", argv);

  // The restart failed: carry on as started.
  if (!own.empty()) {
    setenv("LD_PRELOAD", own.c_str(), 1);
  } else {
    unsetenv("LD_PRELOAD");
  }
  unsetenv(kOwnPreload);
  unsetenv(kRestarted);
}
