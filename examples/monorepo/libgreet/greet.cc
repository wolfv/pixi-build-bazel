#include "libgreet/greet.h"

#include <zlib.h>

#include <cstdio>
#include <cstring>

int greet(const char* name, char* buf, int len) {
  // zlib from conda-forge (via pixi.lock), to show a third-party dependency.
  unsigned long crc = crc32(0L, reinterpret_cast<const Bytef*>(name), std::strlen(name));
  return std::snprintf(buf, len, "Hello, %s! (crc32 %08lx, zlib %s)", name, crc, zlibVersion());
}
