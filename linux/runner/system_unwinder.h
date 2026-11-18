#ifndef RUNNER_SYSTEM_UNWINDER_H_
#define RUNNER_SYSTEM_UNWINDER_H_

// Makes libgcc_s the C++ unwinder of every library in the process, then
// returns. Call it first in main(), before any thread starts.
//
// The Flutter engine exports part of an unwinder of its own
// (_Unwind_RaiseException and nine more). A library loaded after it binds
// those calls to the engine and the rest (_Unwind_GetCFA and others the
// engine does not export) to libgcc_s, and the two do not share a context:
// the first Lua error in libmpv's LuaJIT, or the first C++ exception in any
// system library, ends the app with a segmentation fault or an abort.
//
// The runner lists libgcc_s ahead of the engine (see CMakeLists.txt), which
// already settles it. This is the check behind that: if the engine's copy
// still comes first, the app starts itself again with libgcc_s preloaded.
void use_system_unwinder(char** argv);

#endif  // RUNNER_SYSTEM_UNWINDER_H_
