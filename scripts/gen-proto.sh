#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVICES_DIR="$(cd "${REPO_ROOT}/../services" && pwd)"
PROTO_DIR="${SERVICES_DIR}/proto"
OUT_DIR="${SERVICES_DIR}/golang"

if ! command -v protoc >/dev/null 2>&1; then
  echo "protoc not found; install protoc and protoc-gen-go/protoc-gen-go-grpc" >&2
  exit 1
fi
if ! command -v protoc-gen-go >/dev/null 2>&1; then
  echo "protoc-gen-go not found; run 'go install google.golang.org/protobuf/cmd/protoc-gen-go@latest'" >&2
  exit 1
fi
if ! command -v protoc-gen-go-grpc >/dev/null 2>&1; then
  echo "protoc-gen-go-grpc not found; run 'go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest'" >&2
  exit 1
fi

cd "${SERVICES_DIR}"
protos=(
  "plan.proto"
  "node_agent.proto"
  "clustercontroller.proto"
)

for proto in "${protos[@]}"; do
  if [[ ! -f "${PROTO_DIR}/${proto}" ]]; then
    echo "missing proto ${PROTO_DIR}/${proto}" >&2
    exit 1
  fi
done

protoc -I "${PROTO_DIR}" \
  --go_out="${OUT_DIR}" --go_opt=paths=source_relative \
  --go-grpc_out="${OUT_DIR}" --go-grpc_opt=paths=source_relative \
  "${PROTO_DIR}/plan.proto" \
  "${PROTO_DIR}/node_agent.proto" \
  "${PROTO_DIR}/clustercontroller.proto"

echo "protos regenerated under ${OUT_DIR}"
