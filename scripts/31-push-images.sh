#!/usr/bin/env bash
#
# Phase 3 — 이미지를 Harbor 에 푸시
#
# 호스트에서 빌드한 이미지를 Harbor 의 erp-hq 프로젝트로 올린다.
#
#   사용법:  scripts/31-push-images.sh [태그]
#            태그 기본값은 local
#
# 호스트 Docker 데몬 설정을 바꾸지 않는다.
#
# docker push 로 평문 HTTP 레지스트리에 올리려면 daemon.json 에
# insecure-registries 를 넣고 데몬을 재시작해야 한다. 사용자 환경의
# 보안 설정을 건드리는 일이라 피했다.
#
# 대신 kind 네트워크에 붙인 skopeo 컨테이너로 푸시한다.
# 네트워크 안에서는 Ingress 노드에 바로 닿고, --dest-tls-verify=false 로
# 평문 HTTP 를 허용하므로 호스트 데몬 설정과 무관하다.
#
# crane 은 쓸 수 없었다. --insecure 가 레지스트리 연결에만 적용되고
# 인증 흐름에는 미치지 않아, Harbor 가 돌려주는 http realm 을 거부한다.
#   Error: invalid realm in www-authenticate:
#          realm scheme "http" not allowed for a secure registry; use https
set -euo pipefail

CLUSTER_NAME="erp-poc"
INGRESS_NODE="${CLUSTER_NAME}-worker"
HARBOR_HOST="harbor.localtest.me"
HARBOR_PROJECT="erp-hq"
ADMIN_PW="Harbor12345"
SKOPEO_IMAGE="quay.io/skopeo/stable:v1.19.0"

TAG="${1:-local}"

SERVICES=(catalog-api basket-api discount-grpc ordering-api yarp-apigateway shopping-web)

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}" \
  || die "kind 클러스터 '${CLUSTER_NAME}' 가 없다."

# Ingress 노드의 IP. crane 컨테이너가 harbor.localtest.me 를 이 주소로 해석하게 한다.
# 이름을 그대로 쓰면 Docker DNS 가 IPv6 를 먼저 주는 경우가 있어 IPv4 를 명시한다.
INGRESS_IP="$(docker inspect "${INGRESS_NODE}" \
  --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' 2>/dev/null || true)"
[[ -n "${INGRESS_IP}" ]] || die "Ingress 노드 IP 를 찾을 수 없다: ${INGRESS_NODE}"

log "대상  ${HARBOR_HOST}/${HARBOR_PROJECT}  (태그 ${TAG})"
ok "Ingress 노드 ${INGRESS_NODE} → ${INGRESS_IP}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# skopeo 를 kind 네트워크에서 실행한다.
#   --add-host  harbor.localtest.me 를 Ingress 노드로 해석시킨다.
#               Host 헤더가 유지되어야 ingress-nginx 가 Harbor 로 보낸다.
skopeo() {
  docker run --rm \
    --network kind \
    --add-host "${HARBOR_HOST}:${INGRESS_IP}" \
    -v "${TMPDIR}:/work" \
    "${SKOPEO_IMAGE}" "$@"
}

log "인증 확인"
skopeo login --tls-verify=false -u admin -p "${ADMIN_PW}" "${HARBOR_HOST}" >/dev/null 2>&1 \
  || die "Harbor 로그인 실패. scripts/30-install-harbor.sh 가 끝났는지 확인할 것."
ok "admin 로그인"

PUSHED=0
for svc in "${SERVICES[@]}"; do
  SRC="eshop/${svc}:${TAG}"
  DST="${HARBOR_HOST}/${HARBOR_PROJECT}/${svc}:${TAG}"

  docker image inspect "${SRC}" >/dev/null 2>&1 \
    || die "이미지가 없다: ${SRC}
  scripts/10-build-images.sh 를 먼저 실행할 것."

  log "푸시  ${svc}"
  # docker save 로 만든 아카이브를 skopeo 가 그대로 올린다.
  docker save "${SRC}" -o "${TMPDIR}/${svc}.tar"
  skopeo copy \
    --dest-tls-verify=false \
    --dest-creds "admin:${ADMIN_PW}" \
    "docker-archive:/work/${svc}.tar" \
    "docker://${DST}" 2>&1 | tail -1
  rm -f "${TMPDIR}/${svc}.tar"

  DIGEST="$(skopeo inspect --tls-verify=false --creds "admin:${ADMIN_PW}" \
    "docker://${DST}" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['Digest'])" 2>/dev/null || echo "?")"
  ok "${DST}"
  ok "digest ${DIGEST}"
  PUSHED=$((PUSHED + 1))
done

log "Harbor 저장 결과"
curl -s --max-time 15 -u "admin:${ADMIN_PW}" \
  "http://${HARBOR_HOST}/api/v2.0/projects/${HARBOR_PROJECT}/repositories?page_size=50" \
  2>/dev/null | python3 -c "
import json,sys
try:
    for r in json.load(sys.stdin):
        print(f\"  {r['name']:<40} artifacts={r.get('artifact_count',0)}\")
except Exception:
    print('  (조회 실패)')
"

cat <<EOF

$(printf '\033[1;32m푸시 완료 — %d개\033[0m' "${PUSHED}")

  확인   http://${HARBOR_HOST}/harbor/projects
  다음   envs/dev/values.yaml 을 Harbor 참조로 전환 후 커밋

EOF
