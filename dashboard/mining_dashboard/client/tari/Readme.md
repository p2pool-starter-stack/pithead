# Tari gRPC Collector

The Tari gRPC client and its generated protobuf stubs.

## Generate Protobuf Files

The eight files in `proto/` are byte-identical to
`applications/minotari_app_grpc/proto/` at Tari commit
`f42e14ddac360db0bda56eff43e6c7e00167fb10`. Replace all eight files together from one upstream
ref, then run:

```bash
docker run --rm -v "$PWD":/work -w /work ghcr.io/astral-sh/uv:0.12.13-python3.11-trixie-slim \
  /bin/bash -c "uvx --from grpcio-tools python -m grpc_tools.protoc -Iproto --python_out=generated --grpc_python_out=generated proto/*.proto && sed -i 's/^import.*_pb2/from . \0/' generated/*_pb2*.py"
```
