#include "my_application.h"
#include "system_unwinder.h"

int main(int argc, char** argv) {
  use_system_unwinder(argv);
  // Flutter 3.50's Wayland renderer leaves the window black on some
  // compositors, so prefer X11. GDK_BACKEND=wayland overrides.
  gdk_set_allowed_backends("x11,wayland");
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
