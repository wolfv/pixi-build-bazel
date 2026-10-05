import sys

from examples.pixi_deps.stats import summary

print(f"python {sys.version.split()[0]} from {sys.prefix}")
print(summary([1, 2, 3, 4, 5]))
