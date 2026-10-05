"""Python bindings for libgreet (via ctypes; no compiled extension)."""

import ctypes
import os
import sys

_lib = ctypes.CDLL(os.path.join(sys.prefix, "lib", "libgreet.so"))
_lib.greet.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
_lib.greet.restype = ctypes.c_int


def greet(name: str) -> str:
    buf = ctypes.create_string_buffer(256)
    _lib.greet(name.encode(), buf, len(buf))
    return buf.value.decode()
