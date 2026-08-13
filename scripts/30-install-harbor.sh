#!/usr/bin/env bash
#
# Phase 3 — Harbor 설치 및 클러스터 신뢰 설정
#
# Harbor 를 설치하고, kind 노드의 containerd 가 평문 HTTP 로
# harbor.localtest.me 에서 이미지를 받을 수 있게 한다.
#
#   사용법:  scripts/30-install-harbor.sh
set -euo pipefail

CLUSTER_NAME="erp-poc"
INGRESS_NODE="${CLUSTER_NAME}-worker"
HARBOR_NS="harbor"
HARBOR_HOST="harbor.localtest.me"
HARBOR_CHART_VERSION="1.19.2"   # Harbor 2.15.2
ADMIN_PW="Harbor12345"

# 프로젝트 구성.
#   erp-hq     본사 이미지. public 이라 익명 pull 이 된다.
#              pull secret 을 Git 에 두지 않기 위한 선택이다(저장소가 PUBLIC).
#   partner-*  파트너사별 격리 검증용. private 이라 robot account 가 필요하다.
PROJECTS=("erp-hq:true" "partner-a:false" "partner-b:false")

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARBOR_VALUES="${REPO_ROOT}/infra/harbor/values.yaml"

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[0;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}" \
  || die "kind 클러스터 '${CLUSTER_NAME}' 가 없다. scripts/00-bootstrap.sh 를 먼저 실행할 것."
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# ── 1. 노드의 containerd 설정 확인 ───────────────────────────────
# config_path 가 비어 있으면 아래에서 만드는 hosts.toml 을 읽지 않는다.
# 이 값은 노드 생성 시점에만 적용되므로 클러스터를 다시 만들어야 한다.
log "containerd 레지스트리 설정 확인"
CONFIG_PATH="$(docker exec "${INGRESS_NODE}" containerd config dump 2>/dev/null \
  | grep -A1 "io.containerd.cri.v1.images'.registry\]" | grep config_path | tr -d " '" || true)"

if [[ "${CONFIG_PATH}" != "config_path=/etc/containerd/certs.d" ]]; then
  die "노드의 containerd config_path 가 설정되지 않았다 (현재: ${CONFIG_PATH:-없음}).
  infra/kind/cluster.yaml 의 containerdConfigPatches 가 반영된 클러스터가 필요하다.
  scripts/99-teardown.sh -y && scripts/00-bootstrap.sh 로 다시 만들 것."
fi
ok "config_path = /etc/containerd/certs.d"

# ── 2. Harbor 설치 ───────────────────────────────────────────────
log "Harbor ${HARBOR_CHART_VERSION}"

helm repo add harbor https://helm.goharbor.io >/dev/null 2>&1 || true
helm repo update harbor >/dev/null 2>&1 || helm repo update >/dev/null 2>&1
ok "Helm 저장소 갱신"

helm upgrade --install harbor harbor/harbor \
  --namespace "${HARBOR_NS}" \
  --create-namespace \
  --version "${HARBOR_CHART_VERSION}" \
  --values "${HARBOR_VALUES}" \
  --wait \
  --timeout 15m >/dev/null
ok "설치 완료"

log "Harbor 기동 대기"
kubectl wait --namespace "${HARBOR_NS}" \
  --for=condition=Ready pod --all --timeout=600s >/dev/null 2>&1 || true

# API 가 응답할 때까지 기다린다. 파드가 Ready 여도 core 가 준비되기 전일 수 있다.
for i in $(seq 1 60); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://${HARBOR_HOST}/api/v2.0/systeminfo" 2>/dev/null || true)"
  printf '\r  [%3ds] API %s' "$((i * 5))" "${CODE:-대기}"
  [[ "${CODE}" == "200" ]] && break
  sleep 5
done
echo
[[ "${CODE}" == "200" ]] || die "Harbor API 가 응답하지 않는다."
ok "API 응답 확인"

# ── 3. 노드에 레지스트리 신뢰 설정 배포 ──────────────────────────
# containerd 는 harbor.localtest.me 를 이름으로 해석할 수 없다.
# localtest.me 는 127.0.0.1 로 해석되는데, 노드 안에서 그것은 노드 자신이다.
#
# hosts.toml 로 실제 엔드포인트를 직접 지정한다.
# kind 네트워크에서는 컨테이너 이름이 해석되므로 Ingress 노드 이름을 그대로 쓴다.
log "노드에 레지스트리 설정 배포"

for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "/etc/containerd/certs.d/${HARBOR_HOST}"
  docker exec -i "${node}" sh -c "cat > /etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml" <<EOF
# harbor.localtest.me 로의 요청을 Ingress 노드로 보낸다.
# 평문 HTTP 이므로 skip_verify 는 필요 없다.
server = "http://${HARBOR_HOST}"

[host."http://${INGRESS_NODE}:80"]
  capabilities = ["pull", "resolve"]
  # Host 헤더를 유지해야 ingress-nginx 가 Harbor 로 라우팅한다.
  override_path = false
EOF
  ok "${node}"
done

# config_path 아래의 파일은 요청마다 읽히므로 containerd 재시작이 필요 없다.
ok "containerd 재시작 불필요 (요청 시점에 읽는다)"

# ── 4. 프로젝트 생성 ─────────────────────────────────────────────
log "프로젝트 생성"

for entry in "${PROJECTS[@]}"; do
  name="${entry%%:*}"
  public="${entry#*:}"

  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -u "admin:${ADMIN_PW}" \
    -X POST "http://${HARBOR_HOST}/api/v2.0/projects" \
    -H 'Content-Type: application/json' \
    -d "{\"project_name\":\"${name}\",\"public\":${public},\"metadata\":{\"public\":\"${public}\",\"auto_scan\":\"true\"}}" \
    2>/dev/null || true)"

  case "${CODE}" in
    201) ok "${name}  (public=${public}, 자동 스캔 켜짐)" ;;
    409) ok "${name}  (이미 존재)" ;;
    *)   warn "${name}  생성 실패 HTTP ${CODE}" ;;
  esac
done

# ── 5. 결과 ──────────────────────────────────────────────────────
log "Harbor 파드"
kubectl get pods -n "${HARBOR_NS}" --no-headers 2>/dev/null | head -10

cat <<EOF

$(printf '\033[1;32mHarbor 준비 완료\033[0m')

  UI       http://${HARBOR_HOST}
  계정     admin / ${ADMIN_PW}

  프로젝트 erp-hq(public) · partner-a(private) · partner-b(private)

  다음     scripts/31-push-images.sh

EOF
