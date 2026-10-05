#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Writes a greeting for `name` into `buf` (at most `len` bytes, including the
// terminating NUL) and returns the length of the full greeting.
int greet(const char* name, char* buf, int len);

#ifdef __cplusplus
}
#endif
