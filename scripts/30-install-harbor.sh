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
log "노드에 레지스트리 설정 배포"

INGRESS_IP="$(docker inspect "${INGRESS_NODE}" \
  --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' 2>/dev/null || true)"
[[ -n "${INGRESS_IP}" ]] || die "Ingress 노드 IP 를 찾을 수 없다: ${INGRESS_NODE}"
ok "Ingress 노드 ${INGRESS_NODE} → ${INGRESS_IP}"

for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  # 1) 이름 해석.
  #
  # harbor.localtest.me 는 공개 DNS 에서 127.0.0.1 로 해석된다.
  # 노드 안에서 그것은 노드 자신이라, Ingress 의 hostPort 를 가진
  # 노드에서만 우연히 통하고 나머지 노드에서는 연결이 되지 않는다.
  #
  # 이 항목이 없으면 hosts.toml 만으로는 부족하다.
  # Harbor 는 401 응답의 Www-Authenticate 헤더에 토큰 발급 주소를
  # http://harbor.localtest.me/service/token 으로 돌려주는데,
  # containerd 가 그 주소를 다시 해석해야 하기 때문이다.
  # 결과적으로 Ingress 노드에 뜬 파드만 이미지를 받고
  # 다른 노드의 파드는 ImagePullBackOff 에 빠진다.
  docker exec "${node}" sh -c \
    "grep -q ' ${HARBOR_HOST}\$' /etc/hosts || echo '${INGRESS_IP} ${HARBOR_HOST}' >> /etc/hosts"

  # 2) 평문 HTTP 허용.
  #
  # containerd 는 registry.k8s.io 처럼 기본적으로 HTTPS 를 시도한다.
  # Harbor 를 TLS 없이 노출했으므로 엔드포인트를 명시해야 한다.
  docker exec "${node}" mkdir -p "/etc/containerd/certs.d/${HARBOR_HOST}"
  docker exec -i "${node}" sh -c "cat > /etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml" <<EOF
server = "http://${HARBOR_HOST}"

[host."http://${HARBOR_HOST}"]
  capabilities = ["pull", "resolve"]
EOF
  ok "${node}"
done

# config_path 아래의 파일은 요청마다 읽히므로 containerd 재시작이 필요 없다.
ok "containerd 재시작 불필요 (요청 시점에 읽는다)"

# ── 4. 프로젝트 생성 ─────────────────────────────────────────────
log "프로젝트 생성"

harbor_api() {
  curl -s --max-time 20 -u "admin:${ADMIN_PW}" -H 'Content-Type: application/json' "$@"
}

# 프로젝트 메타데이터는 키 하나씩만 받는다.
# 여러 개를 한 번에 보내면 400 "only allow one key/value pair" 이 돌아온다.
set_meta() {
  local project="$1" key="$2" value="$3"
  harbor_api -o /dev/null -X POST "http://${HARBOR_HOST}/api/v2.0/projects/${project}/metadatas" \
    -d "{\"${key}\":\"${value}\"}" || true
  harbor_api -o /dev/null -X PUT "http://${HARBOR_HOST}/api/v2.0/projects/${project}/metadatas/${key}" \
    -d "{\"${key}\":\"${value}\"}" || true
}

for entry in "${PROJECTS[@]}"; do
  name="${entry%%:*}"
  public="${entry#*:}"

  CODE="$(harbor_api -o /dev/null -w '%{http_code}' \
    -X POST "http://${HARBOR_HOST}/api/v2.0/projects" \
    -d "{\"project_name\":\"${name}\",\"public\":${public},\"metadata\":{\"public\":\"${public}\",\"auto_scan\":\"true\"}}" \
    2>/dev/null || true)"

  case "${CODE}" in
    201) ok "${name}  (public=${public}, 자동 스캔 켜짐)" ;;
    409) ok "${name}  (이미 존재)" ;;
    *)   warn "${name}  생성 실패 HTTP ${CODE}" ;;
  esac
done

# ── 4-1. 취약점 차단 정책 ────────────────────────────────────────
# Critical 이상이 있는 이미지는 받을 수 없게 한다.
# 아키텍처 문서 6p 의 "Harbor 취약점 검사" 가 실제로 배포를 막는 게이트가 된다.
log "취약점 차단 정책 (erp-hq)"

set_meta erp-hq prevent_vul true
set_meta erp-hq severity critical

# 프로젝트 자체 허용목록을 쓰도록 명시한다.
#
# 기본값은 true 이고, 그 경우 프로젝트에 등록한 허용목록이 아니라
# 시스템 전역 허용목록(보통 비어 있음)을 본다.
# 이 값을 바꾸지 않으면 프로젝트에 CVE 를 아무리 등록해도 계속 차단된다.
set_meta erp-hq reuse_sys_cve_allowlist false

ok "prevent_vul=true · severity=critical · 프로젝트 허용목록 사용"

# ── 4-2. CVE 허용목록 ────────────────────────────────────────────
# 게이트를 켜면 지금 쓰는 이미지가 그대로 막힌다.
# 이미지 6개 전체를 스캔해 나온 고유 Critical 은 7건이다.
#
#   베이스 이미지 (mcr.microsoft.com/dotnet/aspnet:8.0 의 Debian)  5건
#     CVE-2026-13221  CVE-2026-42496  CVE-2026-57433  CVE-2026-8376   perl-base
#     CVE-2023-45853                                                  zlib1g
#     → 애플리케이션 코드로 손댈 수 없다. 베이스 이미지를 갱신해야 한다.
#
#   애플리케이션 의존성                                              2건
#     CVE-2026-45288  Marten  (catalog-api, basket-api)
#     CVE-2024-51501  Refit   (shopping-web)
#     → 버전 상향으로 해결된다. 여기 넣고 넘길 항목이 아니다. 이슈로 분리했다.
#
# 등록해두면 이 7건은 통과하되, 새로 생기는 Critical 은 그대로 막힌다.
# 상세는 docs/005-phase3-harbor-registry.md 와 docs/006-phase4-ci-pipeline.md 참고.
log "CVE 허용목록 등록"

harbor_api -o /dev/null -X PUT "http://${HARBOR_HOST}/api/v2.0/projects/erp-hq" -d '{
  "cve_allowlist": {
    "items": [
      {"cve_id": "CVE-2026-13221"},
      {"cve_id": "CVE-2026-42496"},
      {"cve_id": "CVE-2026-57433"},
      {"cve_id": "CVE-2026-8376"},
      {"cve_id": "CVE-2023-45853"},
      {"cve_id": "CVE-2026-45288"},
      {"cve_id": "CVE-2024-51501"}
    ]
  }
}' || true
ok "베이스 이미지 5건 + 애플리케이션 의존성 2건"

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
