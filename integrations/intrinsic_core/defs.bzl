"""Shared metadata for the Intrinsic Core conda packages."""

load("@rules_rattler//conda:defs.bzl", "conda_package", "conda_python_package")

VERSION = "20260922.0"

_COMMON = dict(
    documentation = "https://developer.intrinsic.ai",
    homepage = "https://github.com/intrinsic-ai/intrinsic-core",
    license = "Apache-2.0",
    repository = "https://github.com/intrinsic-ai/intrinsic-core",
    version = VERSION,
)

# Upstream BCR protobuf 32.x generates code for the Python protobuf 6.32 runtime.
PROTOBUF = "protobuf >=6.32,<7"

# googleapis-common-protos 1.75 registers google/longrunning/operations.proto
# as `operations_proto.proto`, which breaks all generated code importing it.
GOOGLEAPIS = "googleapis-common-protos <1.75"

# External Bazel modules whose Python files come from conda-forge instead.
_REPO_MAP = {
    "abseil-py": "absl-py",
    "cel-spec": "bundle",
    "googleapis": GOOGLEAPIS,
    "grpc": "grpcio",
    "grpc_ecosystem_grpc_gateway": "protoc-gen-openapiv2",
    "opentelemetry-proto": "opentelemetry-proto",
    "protobuf": PROTOBUF,
    "rules_python": "",
}

_PYPI_TO_CONDA = {
    "googleapis-common-protos": GOOGLEAPIS,
    "graphviz": "python-graphviz",
    "opencv-python": "opencv",
    "opencv-python-headless": "opencv",
    "protobuf": PROTOBUF,
}

def ic_package(name, **kwargs):
    conda_package(name = name, **(_COMMON | kwargs))

def ic_python_package(name, **kwargs):
    conda_python_package(
        name = name,
        pip_hub = "ai_intrinsic_sdks_pip_deps",
        pypi_to_conda = _PYPI_TO_CONDA,
        repo_map = _REPO_MAP,
        **(_COMMON | kwargs)
    )
