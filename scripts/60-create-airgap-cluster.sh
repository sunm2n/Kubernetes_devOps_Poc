#!/usr/bin/env bash
#
# Phase 6a — 폐쇄망 클러스터 생성
#
# 외부로 나갈 수 없는 kind 클러스터를 만들고, 차단을 실제로 확인한다.
#
#   사용법:  scripts/60-create-airgap-cluster.sh
#            scripts/60-create-airgap-cluster.sh isolate   기본 경로만 다시 제거
#            scripts/60-create-airgap-cluster.sh delete    삭제
#
# 차단 방식:
#
# 처음에는 docker network create --internal 을 썼으나 노드가 부팅하지 못했다.
#   iptables-restore: host/network `' not found
# internal 네트워크에는 게이트웨이가 없는데 kind 의 진입 스크립트가
# 게이트웨이 주소를 참조해 iptables 규칙을 만들기 때문이다.
#
# 대신 일반 네트워크에 올린 뒤 각 노드의 기본 경로를 지운다.
# 서브넷 내부 경로는 남으므로 클러스터 내부 통신은 그대로이고,
# 밖으로 나가는 길만 사라진다.
set -euo pipefail

CLUSTER_NAME="erp-airgap"
NETWORK="erp-airgap-net"
INGRESS_NODE="${CLUSTER_NAME}-worker"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND_CONFIG="${REPO_ROOT}/infra/kind/airgap-cluster.yaml"

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[0;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# 노드에서 외부로 나가는 길을 끊는다.
#
# 컨테이너가 재시작되면 Docker 가 기본 경로를 다시 넣는다.
# 그래서 별도 명령으로도 부를 수 있게 해두었다.
isolate_nodes() {
  local blocked=0

  # 서비스 CIDR 경로를 따로 남겨야 한다.
  #
  # 기본 경로를 지우면 ClusterIP(10.96.0.0/16)로 가는 경로도 함께 사라진다.
  # ClusterIP 는 iptables 가 파드 IP 로 바꿔주지만, 그 전에 커널이 경로를 찾는다.
  # 맞는 경로가 하나도 없으면 그 자리에서 끊긴다.
  #
  #   dial tcp 10.96.97.48:443: connect: network is unreachable
  #
  # 실제로 이것 때문에 API 서버가 ingress-nginx 어드미션 웹훅을 부르지 못해
  # Harbor 설치가 실패했다. 파드끼리는 멀쩡한데 API 서버만 막히는,
  # 원인을 찾기 까다로운 형태다.
  local svc_cidr
  svc_cidr="$(docker exec "${CLUSTER_NAME}-control-plane" \
    grep -o 'service-cluster-ip-range=[^ ]*' /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null \
    | cut -d= -f2 || true)"
  [[ -n "${svc_cidr}" ]] || die "서비스 CIDR 을 읽지 못했다. 제어 평면이 떠 있는지 확인할 것."

  for node in $(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null); do
    docker exec "${node}" ip route del default >/dev/null 2>&1 || true
    docker exec "${node}" ip route replace "${svc_cidr}" dev eth0 >/dev/null 2>&1 \
      || die "${node} 에 서비스 CIDR 경로를 넣지 못했다."

    if docker exec "${node}" timeout 8 curl -sf -o /dev/null https://www.google.com >/dev/null 2>&1; then
      die "${node} 가 여전히 외부에 닿는다. 격리가 성립하지 않는다."
    fi
    ok "${node} — 외부 접근 불가 (서비스 CIDR ${svc_cidr} 경로는 유지)"
    blocked=$((blocked + 1))
  done
  [[ "${blocked}" -gt 0 ]] || die "격리할 노드를 찾지 못했다."
}

case "${1:-create}" in
  delete)
    kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true
    docker network rm "${NETWORK}" >/dev/null 2>&1 || true
    ok "폐쇄망 클러스터·네트워크 삭제"
    exit 0
    ;;
  isolate)
    log "노드 격리 재적용"
    isolate_nodes
    exit 0
    ;;
  create) ;;
  *) die "알 수 없는 명령: ${1}" ;;
esac

command -v kind >/dev/null 2>&1 || die "kind 가 필요하다."
docker info >/dev/null 2>&1 || die "Docker 데몬이 응답하지 않는다."

for port in 8080 8443; do
  if lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
    die "호스트 ${port} 포트가 사용 중이다."
  fi
done

# ── 1. 네트워크 ──────────────────────────────────────────────────
log "네트워크 ${NETWORK}"

if docker network inspect "${NETWORK}" >/dev/null 2>&1; then
  ok "이미 존재"
else
  docker network create "${NETWORK}" >/dev/null
  ok "생성"
fi

# ── 2. 클러스터 ──────────────────────────────────────────────────
log "kind 클러스터 ${CLUSTER_NAME}"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  ok "이미 존재 — 생성 건너뜀"
else
  # 노드 이미지는 호스트 Docker 가 받는다.
  # 실제 폐쇄망에서도 서버에 OS 와 컨테이너 런타임은 미리 설치돼 있다.
  KIND_EXPERIMENTAL_DOCKER_NETWORK="${NETWORK}" \
    kind create cluster --config "${KIND_CONFIG}" --wait 180s
  ok "생성 완료"
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
ok "노드 $(kubectl get nodes --no-headers | wc -l | tr -d ' ')대 Ready"

# Ingress 컨트롤러를 호스트 포트와 이어진 노드에 고정하기 위한 라벨.
# 이 노드에만 8080/8443 매핑이 있다.
kubectl label node "${INGRESS_NODE}" ingress-ready=true --overwrite >/dev/null
ok "${INGRESS_NODE} ← ingress-ready=true"

# ── 3. 격리 ──────────────────────────────────────────────────────
log "외부 경로 차단"
isolate_nodes

# 이미지도 받을 수 없어야 한다. 이것이 이 단계의 핵심 전제다.
if docker exec "${INGRESS_NODE}" timeout 25 crictl pull alpine:3.21 >/dev/null 2>&1; then
  die "노드가 외부 레지스트리에서 이미지를 받았다. 격리가 성립하지 않는다."
fi
ok "외부 레지스트리 pull 불가"

# 반면 클러스터 내부는 살아 있어야 한다.
kubectl get nodes >/dev/null 2>&1 || die "kubectl 이 API 서버에 닿지 못한다."
ok "클러스터 내부 통신 정상"

INGRESS_IP="$(docker inspect "${INGRESS_NODE}" \
  --format "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}" 2>/dev/null || true)"

log "상태"
kubectl get nodes -o wide

cat <<EOF

$(printf '\033[1;32m폐쇄망 클러스터 준비 완료\033[0m')

  컨텍스트     kind-${CLUSTER_NAME}
  네트워크     ${NETWORK}
  Ingress 노드 ${INGRESS_NODE} (${INGRESS_IP})
  진입점       http://localhost:8080

  이 클러스터의 노드는 인터넷에서 아무것도 받을 수 없다.
  필요한 것은 전부 반입해야 한다.

  노드를 재시작하면 Docker 가 기본 경로를 되살린다.
  그때는 scripts/60-create-airgap-cluster.sh isolate 로 다시 끊는다.

  다음   scripts/61-export-bundle.sh

EOF
