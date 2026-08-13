#!/usr/bin/env bash
#
# Phase 1 — 애플리케이션 이미지 빌드 및 클러스터 주입
#
# 앱 저장소(sunm2n/net8_Microservices)의 Dockerfile 6개를 빌드해
# kind 노드에 직접 주입한다. 레지스트리는 Phase 3(Harbor)에서 도입한다.
#
#   사용법:  scripts/10-build-images.sh [서비스명 ...]
#            인자가 없으면 6개 전부 빌드한다.
#
#   앱 소스 위치는 ESHOP_SRC 로 바꿀 수 있다.
#     ESHOP_SRC=/path/to/src scripts/10-build-images.sh
set -euo pipefail

CLUSTER_NAME="erp-poc"
IMAGE_TAG="local"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ESHOP_SRC="${ESHOP_SRC:-${REPO_ROOT}/EShopMicroservices-main/src}"

# 이미지 이름 → Dockerfile 경로 (빌드 컨텍스트는 항상 src 루트)
# Dockerfile 이 COPY 로 BuildingBlocks 를 참조하므로 컨텍스트를 좁히면 실패한다.
SERVICES=(
  "catalog-api:Services/Catalog/Catalog.API/Dockerfile"
  "basket-api:Services/Basket/Basket.API/Dockerfile"
  "discount-grpc:Services/Discount/Discount.Grpc/Dockerfile"
  "ordering-api:Services/Ordering/Ordering.API/Dockerfile"
  "yarp-apigateway:ApiGateways/YarpApiGateway/Dockerfile"
  "shopping-web:WebApps/Shopping.Web/Dockerfile"
)

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── 사전 점검 ────────────────────────────────────────────────────
[[ -d "${ESHOP_SRC}" ]] || die "앱 소스를 찾을 수 없다: ${ESHOP_SRC}
  git clone https://github.com/sunm2n/net8_Microservices.git 로 받은 뒤
  ESHOP_SRC 환경변수로 src 디렉터리를 지정할 것."

[[ -f "${ESHOP_SRC}/eshop-microservices.sln" ]] \
  || die "${ESHOP_SRC} 가 EShopMicroservices 의 src 디렉터리가 아니다."

kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}" \
  || die "kind 클러스터 '${CLUSTER_NAME}' 가 없다. scripts/00-bootstrap.sh 를 먼저 실행할 것."

# 인자가 있으면 해당 서비스만 빌드한다. 한 개만 고칠 때 6개를 다시 빌드하지 않아도 된다.
TARGETS=()
if [[ $# -gt 0 ]]; then
  for arg in "$@"; do
    found=""
    for entry in "${SERVICES[@]}"; do
      [[ "${entry%%:*}" == "${arg}" ]] && { TARGETS+=("${entry}"); found="1"; break; }
    done
    [[ -n "${found}" ]] || die "알 수 없는 서비스: ${arg}
  가능한 값: $(printf '%s ' "${SERVICES[@]%%:*}")"
  done
else
  TARGETS=("${SERVICES[@]}")
fi

log "빌드 대상 ${#TARGETS[@]}개  (소스: ${ESHOP_SRC})"

# ── 빌드 ─────────────────────────────────────────────────────────
BUILT=()
for entry in "${TARGETS[@]}"; do
  name="${entry%%:*}"
  dockerfile="${entry#*:}"
  image="eshop/${name}:${IMAGE_TAG}"

  log "빌드  ${image}"
  [[ -f "${ESHOP_SRC}/${dockerfile}" ]] || die "Dockerfile 없음: ${ESHOP_SRC}/${dockerfile}"

  # 컨텍스트는 src 루트. Dockerfile 이 BuildingBlocks 등 형제 디렉터리를 참조한다.
  docker build \
    --file "${ESHOP_SRC}/${dockerfile}" \
    --tag "${image}" \
    "${ESHOP_SRC}" \
    2>&1 | grep -E "^(#[0-9]+ (DONE|ERROR)|ERROR)" | tail -3 || true

  docker image inspect "${image}" >/dev/null 2>&1 || die "빌드 실패: ${image}"
  ok "완료  $(docker image inspect "${image}" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1024/1024}')"
  BUILT+=("${image}")
done

# ── 클러스터 주입 ────────────────────────────────────────────────
# kind load 는 이미지를 노드 컨테이너의 containerd 로 직접 넣는다.
# 레지스트리가 없어도 파드가 이미지를 찾을 수 있다.
log "kind 클러스터에 주입 (${#BUILT[@]}개)"
kind load docker-image --name "${CLUSTER_NAME}" "${BUILT[@]}"
ok "주입 완료"

# ── 결과 ─────────────────────────────────────────────────────────
log "노드에 적재된 이미지"
docker exec "${CLUSTER_NAME}-worker" crictl images 2>/dev/null \
  | grep -E "^(IMAGE|docker.io/eshop)" | head -10 \
  || echo "  (crictl 조회 실패 — 배포 시 확인)"

cat <<EOF

$(printf '\033[1;32m이미지 준비 완료\033[0m')

  다음   scripts/11-deploy-eshop.sh

EOF
