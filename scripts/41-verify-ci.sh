#!/usr/bin/env bash
#
# Phase 4 — 완료 조건 검증
#
# 이슈 #13 의 완료 조건을 확인한다.
# 앱 저장소의 최신 커밋이 실제로 클러스터에서 돌고 있는지를 끝에서 확인하는 방식이다.
#
#   사용법:  scripts/41-verify-ci.sh
set -euo pipefail

APP_REPO="sunm2n/net8_Microservices"
GITOPS_REPO="sunm2n/Kubernetes_devOps_Poc"
GITOPS_BRANCH="dev"
HARBOR_HOST="harbor.localtest.me"
HARBOR_PROJECT="erp-hq"
ADMIN_PW="Harbor12345"
APP_NS="eshop"
RUNNER_DIR="${HOME}/actions-runner-erp-poc"

SERVICES=(catalog-api basket-api discount-grpc ordering-api yarp-apigateway shopping-web)

PASS=0
FAIL=0

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
pass() { printf '  \033[0;32m✓ PASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[0;31m✗ FAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '          %s\n' "$*"; }

command -v gh >/dev/null 2>&1 || { echo "gh 가 필요하다." >&2; exit 1; }

# ── 조건 1. 러너 ────────────────────────────────────────────────
log "조건 1 — self-hosted 러너"

RUNNER_STATUS="$(gh api "repos/${APP_REPO}/actions/runners" \
  --jq '.runners[] | select(.name=="erp-poc-local") | .status' 2>/dev/null || true)"
if [[ "${RUNNER_STATUS}" == "online" ]]; then
  pass "erp-poc-local — online"
else
  fail "러너 상태 '${RUNNER_STATUS:-없음}' (기대: online)"
  info "scripts/40-setup-runner.sh 로 등록·실행할 것"
fi

if pgrep -f "${RUNNER_DIR}/bin/Runner.Listener" >/dev/null 2>&1; then
  pass "러너 프로세스 실행 중"
else
  fail "러너 프로세스가 없다"
fi

# ── 조건 2. 최신 워크플로 실행 ──────────────────────────────────
log "조건 2 — 워크플로 실행 결과"

RUN_JSON="$(gh run list --repo "${APP_REPO}" --workflow CI --limit 1 \
  --json headSha,conclusion,status,databaseId 2>/dev/null || echo '[]')"
RUN_SHA="$(echo "${RUN_JSON}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['headSha'] if d else '')" 2>/dev/null || true)"
RUN_CONCLUSION="$(echo "${RUN_JSON}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['conclusion'] if d else '')" 2>/dev/null || true)"

if [[ "${RUN_CONCLUSION}" == "success" ]]; then
  pass "최근 실행 성공 (${RUN_SHA:0:12})"
else
  fail "최근 실행 결과 '${RUN_CONCLUSION:-없음}' (기대: success)"
fi

# 태그는 12자리 단축 해시다.
EXPECTED_TAG="${RUN_SHA:0:12}"
[[ -n "${EXPECTED_TAG}" ]] || { echo "워크플로 실행 정보를 가져오지 못했다." >&2; exit 1; }
info "기대 태그 ${EXPECTED_TAG}"

# ── 조건 3. Harbor 에 커밋 해시 태그 ────────────────────────────
log "조건 3 — Harbor 에 커밋 해시 태그로 저장"

FOUND=0
for svc in "${SERVICES[@]}"; do
  HAS="$(curl -s --max-time 15 -u "admin:${ADMIN_PW}" \
    "http://${HARBOR_HOST}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/${svc}/artifacts?with_tag=true" \
    2>/dev/null | TAG="${EXPECTED_TAG}" python3 -c "
import json,sys,os
tag=os.environ['TAG']
try:
    arts=json.load(sys.stdin)
except Exception:
    print('no'); raise SystemExit
print('yes' if any(t['name']==tag for a in arts for t in (a.get('tags') or [])) else 'no')
" 2>/dev/null || echo no)"
  [[ "${HAS}" == "yes" ]] && FOUND=$((FOUND + 1))
done

if [[ "${FOUND}" == "6" ]]; then
  pass "이미지 6개가 ${EXPECTED_TAG} 태그로 저장됨"
else
  fail "태그 ${EXPECTED_TAG} 를 가진 이미지 ${FOUND}개 (기대: 6)"
fi

# ── 조건 4. 매니페스트 저장소가 CI 로 갱신됨 ────────────────────
log "조건 4 — 매니페스트 저장소 자동 갱신"

VALUES="$(gh api "repos/${GITOPS_REPO}/contents/envs/dev/values.yaml?ref=${GITOPS_BRANCH}" \
  --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)"
GITOPS_TAG="$(echo "${VALUES}" | grep -E '^\s+imageTag:' | head -1 | awk '{print $2}')"

if [[ "${GITOPS_TAG}" == "${EXPECTED_TAG}" ]]; then
  pass "envs/dev/values.yaml 의 imageTag = ${GITOPS_TAG}"
else
  fail "매니페스트 태그 '${GITOPS_TAG:-없음}' (기대: ${EXPECTED_TAG})"
fi

# 그 커밋을 사람이 아니라 CI 가 만들었는지 본다.
AUTHOR="$(gh api "repos/${GITOPS_REPO}/commits?sha=${GITOPS_BRANCH}&path=envs/dev/values.yaml&per_page=1" \
  --jq '.[0].commit.author.name' 2>/dev/null || true)"
if [[ "${AUTHOR}" == "erp-poc-ci" ]]; then
  pass "마지막 변경 주체 = ${AUTHOR} (사람이 아님)"
else
  fail "마지막 변경 주체 '${AUTHOR:-없음}' (기대: erp-poc-ci)"
fi

# ── 조건 5. 클러스터에 반영 ─────────────────────────────────────
log "조건 5 — 클러스터에 배포됨"

RUNNING_TAGS="$(kubectl get pods -n "${APP_NS}" \
  -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null \
  | grep "^${HARBOR_HOST}/" | sed 's/.*://' | sort -u || true)"

if [[ "${RUNNING_TAGS}" == "${EXPECTED_TAG}" ]]; then
  pass "실행 중인 앱 파드 전부가 ${EXPECTED_TAG}"
else
  fail "실행 중인 태그: $(echo "${RUNNING_TAGS}" | tr '\n' ' ') (기대: ${EXPECTED_TAG} 하나)"
fi

READY=$(kubectl get pods -n "${APP_NS}" --no-headers 2>/dev/null \
  | awk '{split($2, a, "/"); if (a[1] == a[2] && a[1] > 0 && $3 == "Running") c++} END {print c+0}')
if [[ "${READY}" == "11" ]]; then
  pass "파드 11개 Running·Ready"
else
  fail "Ready ${READY}개 (기대: 11)"
fi

SYNC="$(kubectl get application eshop-dev -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
HEALTH="$(kubectl get application eshop-dev -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
if [[ "${SYNC}" == "Synced" && "${HEALTH}" == "Healthy" ]]; then
  pass "ArgoCD — Synced · Healthy"
else
  fail "ArgoCD sync=${SYNC:-없음} health=${HEALTH:-없음}"
fi

# ── 조건 6. 애플리케이션 동작 ───────────────────────────────────
log "조건 6 — 주문 플로우"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if "${REPO_ROOT}/scripts/12-verify-eshop.sh" >/tmp/phase4-recheck.log 2>&1; then
  pass "주문 플로우 9개 항목 통과"
else
  fail "주문 플로우 검증 실패 — /tmp/phase4-recheck.log 확인"
  grep -E "FAIL" /tmp/phase4-recheck.log | sed 's/^/          /' || true
fi

# ── 결과 ────────────────────────────────────────────────────────
printf '\n────────────────────────────────────\n'
printf '  통과 %d · 실패 %d\n' "${PASS}" "${FAIL}"
printf '────────────────────────────────────\n'
printf '  앱 커밋 %s 가 클러스터에서 돌고 있다.\n' "${EXPECTED_TAG}"
printf '  사람이 개입한 지점은 앱 저장소 커밋 하나뿐이다.\n\n'

[[ "${FAIL}" -eq 0 ]] || exit 1
