#define PY_SSIZE_T_CLEAN
#include <Python.h>

static PyObject* dot(PyObject* self, PyObject* args) {
  PyObject *a, *b;
  if (!PyArg_ParseTuple(args, "OO", &a, &b)) return NULL;
  Py_ssize_t n = PySequence_Size(a);
  double acc = 0;
  for (Py_ssize_t i = 0; i < n; i++) {
    PyObject* x = PySequence_GetItem(a, i);
    PyObject* y = PySequence_GetItem(b, i);
    acc += PyFloat_AsDouble(x) * PyFloat_AsDouble(y);
    Py_DECREF(x);
    Py_DECREF(y);
  }
  return PyFloat_FromDouble(acc);
}

static PyMethodDef methods[] = {{"dot", dot, METH_VARARGS, "Dot product."}, {NULL}};
static struct PyModuleDef module = {PyModuleDef_HEAD_INIT, "fastmath", NULL, -1, methods};
PyMODINIT_FUNC PyInit_fastmath(void) { return PyModule_Create(&module); }
