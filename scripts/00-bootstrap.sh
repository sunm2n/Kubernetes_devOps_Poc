#!/usr/bin/env bash
#
# Phase 0 — 로컬 kind 클러스터 부트스트랩
#
# 클러스터 생성부터 Ingress 진입 경로 확보까지를 한 번에 수행한다.
# 여러 번 실행해도 안전하다(멱등). 이미 있는 자원은 건너뛰거나 갱신한다.
#
#   사용법:  scripts/00-bootstrap.sh
#   삭제:    scripts/99-teardown.sh
set -euo pipefail

CLUSTER_NAME="erp-poc"
INGRESS_NODE="${CLUSTER_NAME}-worker"
INGRESS_NGINX_CHART_VERSION="4.15.1"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND_CONFIG="${REPO_ROOT}/infra/kind/cluster.yaml"
INGRESS_VALUES="${REPO_ROOT}/infra/ingress-nginx/values.yaml"

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[0;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── 1. 사전 점검 ─────────────────────────────────────────────────
log "사전 점검"

for cmd in docker kind kubectl helm; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd 가 설치되어 있지 않다.  brew install $cmd"
done
ok "docker · kind · kubectl · helm 확인"

docker info >/dev/null 2>&1 || die "Docker 데몬이 응답하지 않는다. Docker Desktop 을 실행할 것."
ok "Docker 데몬 응답"

# 클러스터를 새로 만드는 경우에만 호스트 포트를 점검한다.
# 이미 클러스터가 떠 있으면 80/443 은 그 클러스터가 쓰고 있는 것이 정상이다.
if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  for port in 80 443; do
    if lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
      lsof -nP -iTCP:"${port}" -sTCP:LISTEN | tail -n +2 >&2
      die "호스트 ${port} 포트가 이미 사용 중이다. 위 프로세스를 종료한 뒤 다시 실행할 것."
    fi
  done
  ok "호스트 80 · 443 포트 사용 가능"
fi

# ── 2. 클러스터 생성 ─────────────────────────────────────────────
log "kind 클러스터 '${CLUSTER_NAME}'"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  ok "이미 존재 — 생성 건너뜀"
else
  kind create cluster --config "${KIND_CONFIG}" --wait 120s
  ok "생성 완료"
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
ok "kubectl 컨텍스트: kind-${CLUSTER_NAME}"

log "노드 Ready 대기"
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
ok "노드 $(kubectl get nodes --no-headers | wc -l | tr -d ' ')대 Ready"

# ── 3. Ingress 노드 라벨 ─────────────────────────────────────────
# ingress-nginx 컨트롤러는 호스트 80/443 이 매핑된 노드에만 떠야 한다.
# 해당 노드는 infra/kind/cluster.yaml 에서 두 번째로 정의된 워커다.
log "Ingress 노드 라벨"

kubectl get node "${INGRESS_NODE}" >/dev/null 2>&1 \
  || die "노드 ${INGRESS_NODE} 를 찾을 수 없다. infra/kind/cluster.yaml 의 노드 구성을 확인할 것."

kubectl label node "${INGRESS_NODE}" ingress-ready=true --overwrite >/dev/null
ok "${INGRESS_NODE} ← ingress-ready=true"

# 라벨을 붙인 노드가 실제로 호스트 포트와 연결돼 있는지 확인한다.
# 노드 이름과 포트 매핑이 어긋나면 Ingress 는 뜨지만 브라우저에서 접속이 안 되는,
# 원인을 찾기 까다로운 상태가 된다.
if docker port "${INGRESS_NODE}" 2>/dev/null | grep -q '^80/tcp'; then
  ok "${INGRESS_NODE} 에 호스트 80 포트 매핑 확인"
else
  warn "${INGRESS_NODE} 에서 호스트 80 포트 매핑을 찾지 못했다. 브라우저 접속이 실패할 수 있다."
fi

# ── 4. ingress-nginx 설치 ────────────────────────────────────────
log "ingress-nginx ${INGRESS_NGINX_CHART_VERSION}"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null 2>&1 || helm repo update >/dev/null 2>&1
ok "Helm 저장소 갱신"

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --version "${INGRESS_NGINX_CHART_VERSION}" \
  --values "${INGRESS_VALUES}" \
  --wait \
  --timeout 5m >/dev/null
ok "설치 완료"

log "컨트롤러 기동 대기"
kubectl wait --namespace ingress-nginx \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s >/dev/null
ok "컨트롤러 Ready"

# ── 5. 결과 ──────────────────────────────────────────────────────
log "클러스터 상태"
kubectl get nodes -o wide
echo
kubectl get pods -n ingress-nginx

cat <<EOF

$(printf '\033[1;32m클러스터 준비 완료\033[0m')

  컨텍스트   kind-${CLUSTER_NAME}
  진입점     http://localhost  (→ ${INGRESS_NODE})

  검증       scripts/01-verify.sh
  삭제       scripts/99-teardown.sh

EOF
