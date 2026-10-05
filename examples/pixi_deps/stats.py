import numpy as np


def summary(values):
    a = np.asarray(values, dtype=float)
    return f"n={a.size} mean={a.mean():.2f} std={a.std():.2f} (numpy {np.__version__})"
