#!/usr/bin/env bash
#
# Phase 5 — 완료 조건 검증
#
# 이슈 #18 의 완료 조건을 확인한다.
# 파이프라인이 도는 것뿐 아니라 막아야 할 때 막았는지를 이력에서 확인한다.
#
#   사용법:  scripts/51-verify-gates.sh
set -euo pipefail

APP_REPO="sunm2n/net8_Microservices"
GITOPS_REPO="sunm2n/Kubernetes_devOps_Poc"
SONAR_HOST="sonarqube.localtest.me"
SONAR_PROJECT="eshop-microservices"
HARBOR_HOST="harbor.localtest.me"
HARBOR_PROJECT="erp-hq"
ADMIN_PW="Harbor12345"
SONAR_NS="sonarqube"

PASS=0
FAIL=0

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
pass() { printf '  \033[0;32m✓ PASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[0;31m✗ FAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '          %s\n' "$*"; }

command -v gh >/dev/null 2>&1 || { echo "gh 가 필요하다." >&2; exit 1; }

# ── 조건 1. SonarQube 동작 ──────────────────────────────────────
log "조건 1 — SonarQube"

SONAR_STATUS="$(curl -s --max-time 10 "http://${SONAR_HOST}/api/system/status" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)"
if [[ "${SONAR_STATUS}" == "UP" ]]; then
  pass "서버 UP (http://${SONAR_HOST})"
else
  fail "서버 상태 '${SONAR_STATUS:-없음}' (기대: UP)"
fi

READY=$(kubectl get pods -n "${SONAR_NS}" --no-headers 2>/dev/null \
  | awk '{split($2,a,"/"); if (a[1]==a[2] && a[1]>0 && $3=="Running") c++} END {print c+0}')
if [[ "${READY}" -ge 1 ]]; then
  pass "파드 ${READY}개 Running·Ready"
else
  fail "실행 중인 파드가 없다"
fi

# ── 조건 2. 최근 성공 실행의 단계 구성 ──────────────────────────
log "조건 2 — 파이프라인 단계"

LAST_OK="$(gh run list --repo "${APP_REPO}" --workflow CI --status success --limit 1 \
  --json databaseId,headSha --jq '.[0] | "\(.databaseId) \(.headSha[0:12])"' 2>/dev/null || true)"
RUN_ID="${LAST_OK%% *}"
RUN_SHA="${LAST_OK##* }"

if [[ -z "${RUN_ID}" ]]; then
  fail "성공한 실행을 찾을 수 없다"
else
  STEPS="$(gh run view "${RUN_ID}" --repo "${APP_REPO}" --json jobs \
    --jq '.jobs[0].steps[] | select(.conclusion=="success") | .name' 2>/dev/null || true)"

  MISSING=()
  for want in "단위 테스트" "정적분석" "이미지 빌드" "Harbor 푸시" "취약점 스캔 확인" "매니페스트 갱신"; do
    echo "${STEPS}" | grep -qx "${want}" || MISSING+=("${want}")
  done

  if [[ ${#MISSING[@]} -eq 0 ]]; then
    pass "6단계 전부 성공 (${RUN_SHA})"
    info "테스트 → 정적분석 → 빌드 → 푸시 → 스캔 → 매니페스트"
  else
    fail "성공하지 않은 단계: ${MISSING[*]}"
  fi
fi

# ── 조건 3. 게이트가 실제로 막았는가 ────────────────────────────
# 이 이슈의 실질이다. 통과 이력만으로는 게이트를 증명하지 못한다.
log "조건 3 — 실패 시 차단 (이 단계의 실질)"

FAILED_RUN="$(gh run list --repo "${APP_REPO}" --workflow CI --status failure --limit 10 \
  --json databaseId,headSha,conclusion --jq '.[0] | "\(.databaseId) \(.headSha[0:12])"' 2>/dev/null || true)"
FAIL_ID="${FAILED_RUN%% *}"
FAIL_SHA="${FAILED_RUN##* }"

if [[ -z "${FAIL_ID}" ]]; then
  fail "실패한 실행 이력이 없어 차단을 확인할 수 없다"
  info "테스트를 일부러 깨뜨린 커밋을 한 번 올려 확인할 것"
else
  # 실패한 단계 뒤가 전부 건너뛰어졌는지 본다.
  SKIPPED="$(gh run view "${FAIL_ID}" --repo "${APP_REPO}" --json jobs \
    --jq '.jobs[0].steps[] | select(.conclusion=="skipped") | .name' 2>/dev/null || true)"
  FAILED_STEP="$(gh run view "${FAIL_ID}" --repo "${APP_REPO}" --json jobs \
    --jq '.jobs[0].steps[] | select(.conclusion=="failure") | .name' 2>/dev/null | head -1 || true)"

  SKIP_COUNT="$(echo "${SKIPPED}" | grep -c . || true)"
  if [[ -n "${FAILED_STEP}" && "${SKIP_COUNT}" -ge 1 ]]; then
    pass "'${FAILED_STEP}' 실패 → 이후 ${SKIP_COUNT}단계 건너뜀 (${FAIL_SHA})"
    echo "${SKIPPED}" | sed 's/^/            skipped  /'
  else
    fail "실패 후 차단이 확인되지 않는다 (실패 단계 '${FAILED_STEP:-없음}', 건너뜀 ${SKIP_COUNT})"
  fi

  # 실패한 커밋의 이미지가 Harbor 에 없어야 한다.
  PUSHED="$(curl -s --max-time 15 -u "admin:${ADMIN_PW}" \
    "http://${HARBOR_HOST}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/catalog-api/artifacts?with_tag=true" \
    2>/dev/null | TAG="${FAIL_SHA}" python3 -c "
import json,sys,os
tag=os.environ['TAG']
try:
    arts=json.load(sys.stdin)
except Exception:
    print('unknown'); raise SystemExit
print('yes' if any(t['name']==tag for a in arts for t in (a.get('tags') or [])) else 'no')
" 2>/dev/null || echo unknown)"

  if [[ "${PUSHED}" == "no" ]]; then
    pass "실패한 커밋(${FAIL_SHA})의 이미지가 Harbor 에 없다"
  else
    fail "실패했는데 이미지가 올라가 있다 (${PUSHED})"
  fi
fi

# ── 조건 4. 매니페스트가 실패 커밋을 가리키지 않는가 ────────────
log "조건 4 — 매니페스트 무결성"

GITOPS_TAG="$(gh api "repos/${GITOPS_REPO}/contents/envs/dev/values.yaml?ref=dev" \
  --jq '.content' 2>/dev/null | base64 -d 2>/dev/null \
  | grep -E '^\s+imageTag:' | head -1 | awk '{print $2}' || true)"

if [[ -n "${FAIL_SHA}" && "${GITOPS_TAG}" == "${FAIL_SHA}" ]]; then
  fail "매니페스트가 실패한 커밋을 가리킨다 (${GITOPS_TAG})"
elif [[ -n "${GITOPS_TAG}" ]]; then
  pass "매니페스트 태그 ${GITOPS_TAG} — 실패 커밋이 아니다"
else
  fail "매니페스트 태그를 읽지 못했다"
fi

# ── 조건 5. 정적분석 결과가 수집되는가 ──────────────────────────
log "조건 5 — 품질 게이트 판정"

GATE="$(curl -s --max-time 15 -u "admin:SonarPoC12345!" \
  "http://${SONAR_HOST}/api/qualitygates/project_status?projectKey=${SONAR_PROJECT}" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['projectStatus']['status'])" 2>/dev/null || true)"

if [[ "${GATE}" == "OK" ]]; then
  pass "품질 게이트 OK"
elif [[ "${GATE}" == "ERROR" ]]; then
  fail "품질 게이트 ERROR — http://${SONAR_HOST}/dashboard?id=${SONAR_PROJECT}"
else
  fail "판정을 읽지 못했다 (${GATE:-없음}). 분석이 한 번도 돌지 않았을 수 있다"
fi

MEASURES="$(curl -s --max-time 15 -u "admin:SonarPoC12345!" \
  "http://${SONAR_HOST}/api/measures/component?component=${SONAR_PROJECT}&metricKeys=ncloc,bugs,vulnerabilities,code_smells" \
  2>/dev/null | python3 -c "
import json,sys
try:
    ms=json.load(sys.stdin)['component']['measures']
except Exception:
    raise SystemExit
names={'ncloc':'코드 라인','bugs':'버그','vulnerabilities':'취약점','code_smells':'코드 스멜'}
print('  '.join(f\"{names.get(m['metric'],m['metric'])} {m['value']}\" for m in sorted(ms, key=lambda x: x['metric'])))
" 2>/dev/null || true)"
[[ -n "${MEASURES}" ]] && info "${MEASURES}"

# ── 조건 6. 애플리케이션 정상 ───────────────────────────────────
log "조건 6 — 배포된 애플리케이션"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if "${REPO_ROOT}/scripts/41-verify-ci.sh" >/tmp/phase5-recheck.log 2>&1; then
  pass "CI 전 구간 검증 통과"
else
  fail "CI 전 구간 검증 실패 — /tmp/phase5-recheck.log 확인"
  grep -E "FAIL" /tmp/phase5-recheck.log | sed 's/^/          /' || true
fi

# ── 결과 ────────────────────────────────────────────────────────
printf '\n────────────────────────────────────\n'
printf '  통과 %d · 실패 %d\n' "${PASS}" "${FAIL}"
printf '────────────────────────────────────\n\n'

[[ "${FAIL}" -eq 0 ]] || exit 1
