#!/usr/bin/env bash
#
# Phase 1 — EShopMicroservices 배포
#
# charts/eshop 을 kind 클러스터에 설치한다. 여러 번 실행해도 안전하다.
#
#   사용법:  scripts/11-deploy-eshop.sh
#            scripts/11-deploy-eshop.sh --restart   이미지 갱신 후 파드 재생성
set -euo pipefail

CLUSTER_NAME="erp-poc"
RELEASE="eshop"
NAMESPACE="eshop"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="${REPO_ROOT}/charts/eshop"

RESTART="false"
[[ "${1:-}" == "--restart" ]] && RESTART="true"

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}" \
  || die "kind 클러스터 '${CLUSTER_NAME}' 가 없다. scripts/00-bootstrap.sh 를 먼저 실행할 것."
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# 이미지가 노드에 있는지 먼저 본다.
# 없으면 파드가 ErrImageNeverPull 로 멈춘 뒤에야 원인을 알게 된다.
log "이미지 확인"
# 목록을 한 번만 받아 변수에 담고 그 안에서 찾는다.
#
# `docker exec ... | grep -q` 형태로 서비스마다 조회하면 안 된다.
# grep -q 는 첫 매치에서 즉시 끝나며 파이프를 닫고, 그러면 아직 출력 중이던
# docker exec 가 SIGPIPE 로 죽는다. set -o pipefail 때문에 grep 이 성공했는데도
# 파이프라인 전체가 실패로 처리되어, 있는 이미지를 없다고 보고한다.
# 어느 서비스에서 터질지는 실행마다 달라진다.
NODE_IMAGES="$(docker exec "${CLUSTER_NAME}-worker" crictl images 2>/dev/null || true)"

MISSING=()
for svc in catalog-api basket-api discount-grpc ordering-api yarp-apigateway shopping-web; do
  case "${NODE_IMAGES}" in
    *"eshop/${svc} "*) ;;
    *) MISSING+=("${svc}") ;;
  esac
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  die "노드에 없는 이미지: ${MISSING[*]}
  scripts/10-build-images.sh 를 먼저 실행할 것."
fi
ok "이미지 6개 확인"

log "Helm 배포  ${RELEASE} → ${NAMESPACE}"
helm upgrade --install "${RELEASE}" "${CHART}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --wait \
  --timeout 15m
ok "배포 완료"

if [[ "${RESTART}" == "true" ]]; then
  # kind load 로 이미지를 덮어써도 태그가 같으면 Kubernetes 는 변화를 알지 못한다.
  # 명시적으로 다시 굴려야 새 이미지가 반영된다.
  log "파드 재생성"
  kubectl rollout restart deployment -n "${NAMESPACE}" >/dev/null
  kubectl rollout status deployment -n "${NAMESPACE}" --timeout=10m >/dev/null
  ok "재생성 완료"
fi

log "배포 상태"
kubectl get pods -n "${NAMESPACE}" -o wide

cat <<EOF

$(printf '\033[1;32m배포 완료\033[0m')

  화면    http://eshop.localtest.me
  API     http://api.eshop.localtest.me/catalog-service/products

  검증    scripts/12-verify-eshop.sh

EOF
