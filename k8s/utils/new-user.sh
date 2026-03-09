#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage:
  new-user [options] <username>

Creates a client cert for <username> via Kubernetes CSR API and applies a
Role+RoleBinding in a namespace (default: default).

Options:
  -n, --namespace <ns>     Namespace for Role/RoleBinding (default: default)
  -r, --roles <verbs>      Comma-separated verbs (default: get,watch,list)
  -R, --resource <res>     Comma-separated resources (default: pods)
  -h, --help               Show help

Outputs (in <username>/):
  <username>.key
  <username>.csr
  <username>.crt
  csr.yaml
  rbac.yaml
EOF
}

trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

csv_to_inline_yaml_array() {
  local csv="${1:-}"
  local -a parts
  local out=""

  IFS=',' read -r -a parts <<<"${csv}"
  for part in "${parts[@]}"; do
    part="$(trim "${part}")"
    [[ -n "${part}" ]] || continue
    part="${part//\"/\\\"}"
    if [[ -n "${out}" ]]; then
      out+=", "
    fi
    out+="\"${part}\""
  done

  if [[ -z "${out}" ]]; then
    echo "Error: list cannot be empty: '${csv}'" >&2
    exit 2
  fi

  printf '%s' "${out}"
}

USERNAME=""
NAMESPACE="default"
RBAC_VERBS="get,watch,list"
RBAC_RESOURCES="pods"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -n|--namespace)
      NAMESPACE="${2:-}"
      shift 2
      ;;
    -r|--roles)
      RBAC_VERBS="${2:-}"
      shift 2
      ;;
    -R|--resource|--resources)
      RBAC_RESOURCES="${2:-}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "${USERNAME}" ]]; then
        USERNAME="$1"
        shift
      else
        echo "Error: unexpected extra argument: $1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

if [[ -z "${USERNAME}" && $# -gt 0 ]]; then
  USERNAME="$1"
  shift
fi

if [[ -z "${USERNAME}" ]]; then
  usage >&2
  exit 2
fi

if [[ -z "${NAMESPACE}" ]]; then
  echo "Error: namespace cannot be empty" >&2
  exit 2
fi

for bin in openssl kubectl base64 tr; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "Error: missing dependency: ${bin}" >&2
    exit 1
  fi
done

OUT_DIR="${USERNAME}"
KEY_FILE="${OUT_DIR}/${USERNAME}.key"
CSR_FILE="${OUT_DIR}/${USERNAME}.csr"
CRT_FILE="${OUT_DIR}/${USERNAME}.crt"
CSR_YAML="${OUT_DIR}/csr.yaml"
RBAC_YAML="${OUT_DIR}/rbac.yaml"

if [[ -d "${OUT_DIR}" ]]; then
  echo "Error: output directory already exists: ${OUT_DIR}" >&2
  echo "Refusing to overwrite. Remove or rename it first." >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

openssl genrsa -out "${KEY_FILE}" 2048
openssl req -new -key "${KEY_FILE}" -out "${CSR_FILE}" -subj "/CN=${USERNAME}/O=group1"

CSR_REQUEST="$(base64 < "${CSR_FILE}" | tr -d '\n')"

cat > "${CSR_YAML}" <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USERNAME}
spec:
  request: ${CSR_REQUEST}
  signerName: kubernetes.io/kube-apiserver-client
  usages:
    - client auth
EOF

kubectl apply -f "${CSR_YAML}"
kubectl certificate approve "${USERNAME}"
# macOS uses -D instead of --decode
BASE64_DECODE_FLAG="--decode"
if [[ "$(uname -s)" == "Darwin" ]]; then 
  BASE64_DECODE_FLAG="-D"
fi

kubectl get csr "${USERNAME}" -o jsonpath='{.status.certificate}' | base64 "${BASE64_DECODE_FLAG}" > "${CRT_FILE}"

cat > "${RBAC_YAML}" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: ${NAMESPACE}
  name: pod-reader
rules:
  - apiGroups: [""]
    resources: [$(csv_to_inline_yaml_array "${RBAC_RESOURCES}")]
    verbs: [$(csv_to_inline_yaml_array "${RBAC_VERBS}")]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: ${NAMESPACE}
subjects:
  - kind: User
    name: ${USERNAME}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl apply -f "${RBAC_YAML}"
kubectl config set-credentials ${USERNAME} --client-certificate=${CRT_FILE} --client-key=${KEY_FILE}
kubectl config set-context ${USERNAME}-context --cluster=kubernetes --namespace=${NAMESPACE} --user=${USERNAME} 

echo "Created user cert and RBAC in ${OUT_DIR}/"
echo "  key:  ${KEY_FILE}"
echo "  csr:  ${CSR_FILE}"
echo "  crt:  ${CRT_FILE}"
echo "  csr yaml:  ${CSR_YAML}"
echo "  rbac yaml: ${RBAC_YAML}"