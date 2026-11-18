#include "my_application.h"
#include "system_unwinder.h"

int main(int argc, char** argv) {
  use_system_unwinder(argv);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
