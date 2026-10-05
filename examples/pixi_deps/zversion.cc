#include <zlib.h>

#include <cstdio>
#include <cstring>

int main() {
  const char* msg = "hello hello hello hello";
  unsigned char buf[128];
  uLongf len = sizeof(buf);
  compress(buf, &len, reinterpret_cast<const Bytef*>(msg), std::strlen(msg));
  std::printf("zlib %s: %zu -> %lu bytes\n", zlibVersion(), std::strlen(msg), len);
  return 0;
}
