#!/usr/bin/env bash
#
# Phase 7 — 파트너사 격리 구성
#
# 파트너사별로 레지스트리 · 네임스페이스 · 자격증명을 만들고,
# ArgoCD 가 각자의 범위 안에서만 배포하도록 등록한다.
#
#   사용법:  scripts/70-setup-partners.sh
#            scripts/70-setup-partners.sh remove   구성 제거
#
# ── Git 에 넣을 수 없는 것 ───────────────────────────────────────
#
# 이 저장소는 PUBLIC 이다. Harbor robot 계정의 비밀번호가 들어가면 안 된다.
# 그래서 자격증명이 필요한 것만 이 스크립트가 클러스터에 직접 만들고,
# Git 의 매니페스트는 Secret 의 "이름" 만 참조한다.
#
#   Git 에 있는 것    네임스페이스 이름, Secret 이름, 정책, Application 정의
#   여기서 만드는 것  robot 계정, docker-registry Secret
#
# 운영에서는 이 자리에 OpenBao 가 들어간다 (Phase 8).
set -euo pipefail

CLUSTER_NAME="erp-poc"
HARBOR_HOST="harbor.localtest.me"
HARBOR_ADMIN="admin"
HARBOR_PW="Harbor12345"
SOURCE_PROJECT="erp-hq"
INGRESS_NODE="${CLUSTER_NAME}-worker"
SKOPEO_IMAGE="quay.io/skopeo/stable:v1.19.0"

PARTNERS=(partner-a partner-b)
SERVICES=(catalog-api basket-api discount-grpc ordering-api yarp-apigateway shopping-web)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "${REPO_ROOT}" == /* ]] \
  || REPO_ROOT="$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd)")"

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[0;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

harbor_api() {
  curl -s --max-time 30 -u "${HARBOR_ADMIN}:${HARBOR_PW}" -H 'Content-Type: application/json' "$@"
}

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 \
  || die "클러스터 kind-${CLUSTER_NAME} 가 없다."

# ── 제거 ─────────────────────────────────────────────────────────
if [[ "${1:-}" == "remove" ]]; then
  log "파트너 구성 제거"
  for p in "${PARTNERS[@]}"; do
    kubectl delete application "eshop-${p}" -n argocd --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  sleep 5
  kubectl delete appproject partner-a partner-b -n argocd --ignore-not-found >/dev/null 2>&1 || true
  for p in "${PARTNERS[@]}"; do
    kubectl delete ns "${p}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    ok "${p} 제거 요청"
  done
  warn "Harbor 의 robot 계정과 이미지는 남는다. UI 에서 지울 것."
  exit 0
fi

curl -sf -o /dev/null --max-time 10 "http://${HARBOR_HOST}/api/v2.0/systeminfo" \
  || die "Harbor 가 응답하지 않는다. scripts/30-install-harbor.sh 를 먼저 실행할 것."

INGRESS_IP="$(docker inspect "${INGRESS_NODE}" \
  --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' 2>/dev/null || true)"
[[ -n "${INGRESS_IP}" ]] || die "Ingress 노드를 찾을 수 없다: ${INGRESS_NODE}"

# 배포할 태그는 본사 값에서 읽는다.
# 파트너사는 스스로 빌드하지 않고 본사가 검증한 것을 받는다.
IMAGE_TAG="$(grep -E '^\s+imageTag:' "${REPO_ROOT}/envs/dev/values.yaml" | head -1 | awk '{print $2}')"
[[ -n "${IMAGE_TAG}" ]] || die "envs/dev/values.yaml 에서 imageTag 를 읽지 못했다."

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# skopeo 는 컨테이너로 돈다 (scripts/61-export-bundle.sh 와 같은 이유).
skopeo() {
  docker run --rm --network kind --add-host "${HARBOR_HOST}:${INGRESS_IP}" \
    -v "${TMPDIR}:/work" "${SKOPEO_IMAGE}" "$@"
}

log "파트너사 ${#PARTNERS[@]}곳 · 태그 ${IMAGE_TAG}"
ok "본사 프로젝트 ${SOURCE_PROJECT} → 파트너 프로젝트"

for partner in "${PARTNERS[@]}"; do
  log "${partner}"

  # ── 1. Harbor 프로젝트 ─────────────────────────────────────────
  #
  # private 이어야 한다. public 이면 자격증명 없이 누구나 받을 수 있어
  # 레지스트리 격리가 성립하지 않는다.
  CODE="$(harbor_api -o /dev/null -w '%{http_code}' \
    -X POST "http://${HARBOR_HOST}/api/v2.0/projects" \
    -d "{\"project_name\":\"${partner}\",\"public\":false,\"metadata\":{\"public\":\"false\",\"auto_scan\":\"true\"}}" || true)"
  case "${CODE}" in
    201) ok "프로젝트 생성 (private)" ;;
    409) ok "프로젝트 이미 존재" ;;
    *)   die "프로젝트 생성 실패 HTTP ${CODE}" ;;
  esac

  IS_PUBLIC="$(harbor_api "http://${HARBOR_HOST}/api/v2.0/projects/${partner}" \
    | python3 -c "import json,sys; print((json.load(sys.stdin).get('metadata') or {}).get('public','?'))" 2>/dev/null || true)"
  [[ "${IS_PUBLIC}" == "false" ]] || die "${partner} 프로젝트가 private 이 아니다 (public=${IS_PUBLIC})."
  ok "private 확인"

  # ── 2. 이미지 배포 ─────────────────────────────────────────────
  #
  # 본사가 검증한 이미지를 파트너 프로젝트로 복사한다.
  # 파트너사는 빌드 파이프라인을 갖지 않는다 — 받은 것만 돌린다.
  for svc in "${SERVICES[@]}"; do
    skopeo copy --quiet \
      --src-tls-verify=false --src-creds "${HARBOR_ADMIN}:${HARBOR_PW}" \
      --dest-tls-verify=false --dest-creds "${HARBOR_ADMIN}:${HARBOR_PW}" \
      "docker://${HARBOR_HOST}/${SOURCE_PROJECT}/${svc}:${IMAGE_TAG}" \
      "docker://${HARBOR_HOST}/${partner}/${svc}:${IMAGE_TAG}" >/dev/null 2>&1 \
      || die "${partner}/${svc} 복사 실패."
  done
  ok "이미지 ${#SERVICES[@]}개 배포"

  # ── 3. robot 계정 ──────────────────────────────────────────────
  #
  # 이 프로젝트에서 pull 만 할 수 있는 계정이다.
  # push 를 주지 않는 이유는 파트너가 자기 프로젝트에 임의의 이미지를
  # 올리기 시작하면 본사가 검증한 것만 돈다는 전제가 깨지기 때문이다.
  #
  # 이름은 Harbor 가 robot$<프로젝트>+<이름> 으로 만든다.
  # 접두어를 빼고 쓰면 인증이 조용히 실패하므로 응답에서 그대로 받아 쓴다.
  # 재실행할 수 있어야 하므로 같은 이름이 있으면 먼저 지운다.
  # 비밀번호는 발급 시점에 한 번만 돌려주고 다시 조회할 수 없어,
  # 남겨두면 쓸 수 없는 계정이 쌓이고 생성은 CONFLICT 로 실패한다.
  #
  # 프로젝트 robot 은 그냥 조회되지 않는다.
  # /robots 는 기본적으로 시스템 robot 만 돌려주고,
  # 프로젝트 것을 보려면 질의에 프로젝트 ID 가 있어야 한다.
  #
  #   q=Level=project,ProjectID=<id>
  #
  # 이것 없이 부르면 빈 목록이 와서 "없다" 고 판단하게 된다.
  PROJECT_ID="$(harbor_api "http://${HARBOR_HOST}/api/v2.0/projects/${partner}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['project_id'])" 2>/dev/null || true)"
  [[ -n "${PROJECT_ID}" ]] || die "${partner} 프로젝트 ID 를 읽지 못했다."

  OLD_ID="$(harbor_api \
    "http://${HARBOR_HOST}/api/v2.0/robots?page_size=100&q=Level%3Dproject%2CProjectID%3D${PROJECT_ID}" \
    | ROBOT="robot\$${partner}+puller" python3 -c "
import json, os, sys
want = os.environ['ROBOT']
for r in json.load(sys.stdin) or []:
    if r.get('name') == want:
        print(r['id'])
        break
" 2>/dev/null || true)"

  if [[ -n "${OLD_ID}" ]]; then
    harbor_api -o /dev/null -X DELETE "http://${HARBOR_HOST}/api/v2.0/robots/${OLD_ID}" || true
  fi

  ROBOT_JSON="$(harbor_api -X POST "http://${HARBOR_HOST}/api/v2.0/robots" -d "{
    \"name\": \"puller\",
    \"duration\": 365,
    \"level\": \"project\",
    \"disable\": false,
    \"permissions\": [{
      \"kind\": \"project\",
      \"namespace\": \"${partner}\",
      \"access\": [{\"resource\": \"repository\", \"action\": \"pull\"}]
    }]
  }")"

  ROBOT_NAME="$(echo "${ROBOT_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || true)"
  ROBOT_SECRET="$(echo "${ROBOT_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('secret',''))" 2>/dev/null || true)"

  [[ -n "${ROBOT_NAME}" && -n "${ROBOT_SECRET}" ]] \
    || die "${partner} robot 계정 발급 실패: ${ROBOT_JSON}"
  ok "robot 계정 ${ROBOT_NAME} (pull 전용, 365일)"

  # ── 4. 네임스페이스와 pull secret ──────────────────────────────
  #
  # ArgoCD 가 만들지 않는다. AppProject 가 클러스터 범위 자원을 막고 있고,
  # 파드가 뜨기 전에 secret 이 있어야 이미지를 받을 수 있다.
  kubectl create namespace "${partner}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret docker-registry "harbor-${partner}" \
    --namespace "${partner}" \
    --docker-server="${HARBOR_HOST}" \
    --docker-username="${ROBOT_NAME}" \
    --docker-password="${ROBOT_SECRET}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "네임스페이스 · Secret harbor-${partner}"
done

# ── 5. AppProject 와 Application ─────────────────────────────────
log "ArgoCD 등록"

kubectl apply -f "${REPO_ROOT}/argocd/projects/partners.yaml" >/dev/null
ok "AppProject 2개 — 배포 가능 네임스페이스 고정, 클러스터 자원 금지"

# 매니페스트의 targetRevision 은 항상 dev 다.
#
# 그런데 머지 전에는 envs/partner-*/values.yaml 이 dev 에 없어서
# 동기화가 실패한다. 검증을 하려면 작업 브랜치를 가리켜야 한다.
#
# Git 파일을 고치지 않고 환경변수로 덮어쓴다.
# 매니페스트를 브랜치 이름으로 바꿔놓고 되돌리는 것을 잊으면,
# 머지된 뒤 없어진 브랜치를 가리키는 Application 이 남는다.
#
#   TARGET_REVISION=feat/phase7-partner-isolation scripts/70-setup-partners.sh
TARGET_REVISION="${TARGET_REVISION:-dev}"
[[ "${TARGET_REVISION}" == "dev" ]] || warn "targetRevision 을 ${TARGET_REVISION} 로 덮어쓴다 (검증용)"

for partner in "${PARTNERS[@]}"; do
  sed "s|targetRevision: dev|targetRevision: ${TARGET_REVISION}|" \
    "${REPO_ROOT}/argocd/applications/eshop-${partner}.yaml" | kubectl apply -f - >/dev/null
  ok "Application eshop-${partner}"
done

# ── 6. 동기화 대기 ───────────────────────────────────────────────
log "동기화"

for i in $(seq 1 150); do
  DONE=0
  LINE=""
  for partner in "${PARTNERS[@]}"; do
    S="$(kubectl -n argocd get application "eshop-${partner}" \
      -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
    R="$(kubectl get pods -n "${partner}" --no-headers 2>/dev/null \
      | awk '{split($2,a,"/"); if (a[1]==a[2] && a[1]>0 && $3=="Running") c++} END {print c+0}')"
    LINE="${LINE}${partner} ${R}/11  "
    [[ "${S}" == "Synced/Healthy" && "${R}" == "11" ]] && DONE=$((DONE + 1))
  done
  printf '\r    %4ds  %s' "$((i * 6))" "${LINE}"
  [[ "${DONE}" == "${#PARTNERS[@]}" ]] && break
  sleep 6
done
echo

for partner in "${PARTNERS[@]}"; do
  S="$(kubectl -n argocd get application "eshop-${partner}" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  if [[ "${S}" == "Synced/Healthy" ]]; then
    ok "eshop-${partner} ${S}"
  else
    warn "eshop-${partner} ${S} — scripts/71-verify-isolation.sh 로 원인을 확인할 것"
  fi
done

cat <<EOF

$(printf '\033[1;32m파트너 구성 완료\033[0m')

  파트너 A   http://eshop.partner-a.localtest.me
  파트너 B   http://eshop.partner-b.localtest.me
  본사       http://eshop.localtest.me   (영향 없음)

  각 파트너는 자기 Harbor 프로젝트(private)에서만 이미지를 받는다.
  robot 계정은 pull 만 가능하고 다른 프로젝트에는 접근할 수 없다.

  다음   scripts/71-verify-isolation.sh

EOF
