import sys

import fastmath

assert fastmath.dot([1, 2, 3], [4, 5, 6]) == 32.0
print("ok", sys.version.split()[0], fastmath.__file__)
