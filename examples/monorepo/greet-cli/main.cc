#include <cstdio>

#include "libgreet/greet.h"

int main(int argc, char** argv) {
  char buf[256];
  greet(argc > 1 ? argv[1] : "world", buf, sizeof(buf));
  std::puts(buf);
  return 0;
}
