#!/usr/bin/env bash
#
# Phase 3 — 완료 조건 검증
#
# 이슈 #10 의 완료 조건을 순서대로 확인한다.
# 취약 이미지를 실제로 올려 차단되는지, 파트너 계정으로 남의 이미지를
# 받을 수 없는지까지 확인한다.
#
#   사용법:  scripts/32-verify-harbor.sh
set -euo pipefail

CLUSTER_NAME="erp-poc"
INGRESS_NODE="${CLUSTER_NAME}-worker"
HARBOR_HOST="harbor.localtest.me"
ADMIN_PW="Harbor12345"
SKOPEO_IMAGE="quay.io/skopeo/stable:v1.19.0"

# 알려진 Critical 취약점이 있는 오래된 이미지.
# 허용목록에 없는 CVE 를 들고 있어야 차단 동작을 확인할 수 있다.
VULN_SOURCE="alpine:3.10"

PASS=0
FAIL=0

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
pass() { printf '  \033[0;32m✓ PASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[0;31m✗ FAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '          %s\n' "$*"; }

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 \
  || { echo "클러스터가 없다. scripts/00-bootstrap.sh 를 먼저 실행할 것." >&2; exit 1; }

INGRESS_IP="$(docker inspect "${INGRESS_NODE}" \
  --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' 2>/dev/null || true)"
[[ -n "${INGRESS_IP}" ]] || { echo "Ingress 노드 IP 를 찾을 수 없다." >&2; exit 1; }

TMPDIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMPDIR}"
  # 검증용으로 만든 것들을 지운다.
  curl -s -o /dev/null -u "admin:${ADMIN_PW}" -X DELETE \
    "http://${HARBOR_HOST}/api/v2.0/projects/erp-hq/repositories/vuln-probe" 2>/dev/null || true
  curl -s -o /dev/null -u "admin:${ADMIN_PW}" -X DELETE \
    "http://${HARBOR_HOST}/api/v2.0/projects/partner-b/repositories/secret-app" 2>/dev/null || true
  [[ -n "${ROBOT_ID:-}" ]] && curl -s -o /dev/null -u "admin:${ADMIN_PW}" -X DELETE \
    "http://${HARBOR_HOST}/api/v2.0/robots/${ROBOT_ID}" 2>/dev/null || true
}
trap cleanup EXIT

harbor_api() { curl -s --max-time 20 -u "admin:${ADMIN_PW}" -H 'Content-Type: application/json' "$@"; }

skopeo() {
  docker run --rm --network kind \
    --add-host "${HARBOR_HOST}:${INGRESS_IP}" \
    -v "${TMPDIR}:/work" "${SKOPEO_IMAGE}" "$@"
}

# ── 조건 1. 프로젝트 3개 ─────────────────────────────────────────
log "조건 1 — 프로젝트 구성"

PROJECTS_JSON="$(harbor_api "http://${HARBOR_HOST}/api/v2.0/projects?page_size=50" 2>/dev/null || echo '[]')"
FOUND="$(echo "${PROJECTS_JSON}" | python3 -c "
import json,sys
try:
    ps={p['name']: p['metadata'].get('public') for p in json.load(sys.stdin)}
except Exception:
    ps={}
want={'erp-hq':'true','partner-a':'false','partner-b':'false'}
print('ok' if all(ps.get(k)==v for k,v in want.items()) else 'no')
print(' '.join(f\"{k}({ps.get(k,'없음')})\" for k in want))
" 2>/dev/null || echo -e "no\n")"

if [[ "$(echo "${FOUND}" | head -1)" == "ok" ]]; then
  pass "erp-hq(public) · partner-a(private) · partner-b(private)"
else
  fail "프로젝트 구성이 기대와 다르다: $(echo "${FOUND}" | tail -1)"
fi

# ── 조건 2. 이미지 6개 + 스캔 결과 ───────────────────────────────
log "조건 2 — 이미지 저장 및 Trivy 스캔"

SERVICES=(catalog-api basket-api discount-grpc ordering-api yarp-apigateway shopping-web)
STORED=0
SCANNED=0
for svc in "${SERVICES[@]}"; do
  RESULT="$(harbor_api "http://${HARBOR_HOST}/api/v2.0/projects/erp-hq/repositories/${svc}/artifacts?with_scan_overview=true" 2>/dev/null \
    | python3 -c "
import json,sys
try:
    a=json.load(sys.stdin)[0]
except Exception:
    print('none 0'); raise SystemExit
st='none'; total=0
for v in (a.get('scan_overview') or {}).values():
    st=v.get('scan_status','none')
    total=(v.get('summary') or {}).get('total',0)
print(st, total)
" 2>/dev/null || echo "none 0")"
  STATUS="${RESULT%% *}"
  TOTAL="${RESULT##* }"
  [[ "${STATUS}" != "none" ]] && STORED=$((STORED + 1))
  [[ "${STATUS}" == "Success" ]] && { SCANNED=$((SCANNED + 1)); info "${svc} — 취약점 ${TOTAL}건"; }
done

if [[ "${STORED}" == "6" ]]; then
  pass "이미지 6개 저장됨"
else
  fail "저장된 이미지 ${STORED}개 (기대: 6)"
fi

if [[ "${SCANNED}" == "6" ]]; then
  pass "6개 전부 Trivy 스캔 완료"
else
  fail "스캔 완료 ${SCANNED}개 (기대: 6)"
fi

# ── 조건 3. 클러스터가 Harbor 에서 이미지를 받는가 ───────────────
log "조건 3 — 클러스터가 Harbor 를 이미지 출처로 쓰는가"

USING_HARBOR=$(kubectl get pods -n eshop -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c "^${HARBOR_HOST}/" || true)

if [[ "${USING_HARBOR}" == "6" ]]; then
  pass "앱 컨테이너 6개가 ${HARBOR_HOST} 를 참조"
else
  fail "Harbor 참조 컨테이너 ${USING_HARBOR}개 (기대: 6)"
fi

READY=$(kubectl get pods -n eshop --no-headers 2>/dev/null \
  | awk '{split($2, a, "/"); if (a[1] == a[2] && a[1] > 0 && $3 == "Running") c++} END {print c+0}')
if [[ "${READY}" == "11" ]]; then
  pass "파드 11개 Running·Ready"
else
  fail "Ready ${READY}개 (기대: 11)"
fi

# ── 조건 4. 취약 이미지 차단 ─────────────────────────────────────
# 허용목록에 없는 Critical 을 가진 이미지를 올려 pull 이 막히는지 본다.
log "조건 4 — 취약 이미지 차단 (검증 목표 3번)"

info "${VULN_SOURCE} 를 erp-hq/vuln-probe 로 올린다"
if skopeo copy --dest-tls-verify=false --dest-creds "admin:${ADMIN_PW}" \
     "docker://docker.io/library/${VULN_SOURCE}" \
     "docker://${HARBOR_HOST}/erp-hq/vuln-probe:test" >/dev/null 2>&1; then

  # 자동 스캔이 끝날 때까지 기다린다.
  SEVERITY=""
  for _ in $(seq 1 30); do
    SEVERITY="$(harbor_api "http://${HARBOR_HOST}/api/v2.0/projects/erp-hq/repositories/vuln-probe/artifacts?with_scan_overview=true" 2>/dev/null \
      | python3 -c "
import json,sys
try:
    a=json.load(sys.stdin)[0]
except Exception:
    raise SystemExit
for v in (a.get('scan_overview') or {}).values():
    if v.get('scan_status')=='Success':
        s=(v.get('summary') or {}).get('summary',{})
        print(s.get('Critical',0))
" 2>/dev/null || true)"
    [[ -n "${SEVERITY}" ]] && break
    sleep 5
  done
  info "스캔 결과 Critical ${SEVERITY:-?}건"

  if skopeo inspect --tls-verify=false --creds "admin:${ADMIN_PW}" \
       "docker://${HARBOR_HOST}/erp-hq/vuln-probe:test" >/dev/null 2>&1; then
    fail "취약 이미지 pull 이 허용됐다 — 차단 정책이 동작하지 않는다"
  else
    pass "취약 이미지 pull 거부됨 (Critical ${SEVERITY:-?}건)"
    info "허용목록에 없는 Critical 이 있으면 막힌다"
  fi
else
  fail "검증용 취약 이미지를 올리지 못했다"
fi

# 정상 이미지는 계속 받을 수 있어야 한다.
# 허용목록에 등록한 6건 때문에 통과하며, 게이트 자체는 켜져 있다.
if skopeo inspect --tls-verify=false --creds "admin:${ADMIN_PW}" \
     "docker://${HARBOR_HOST}/erp-hq/catalog-api:local" >/dev/null 2>&1; then
  pass "허용목록에 등록된 CVE 만 있는 이미지는 통과"
else
  fail "정상 이미지까지 막혔다 — 허용목록 설정을 확인할 것"
  info "reuse_sys_cve_allowlist 가 false 인지 확인. true 면 프로젝트 허용목록이 무시된다"
fi

# ── 조건 5. 파트너 격리 ──────────────────────────────────────────
log "조건 5 — 파트너 프로젝트 격리"

# partner-b 에 이미지를 하나 올려둔다.
skopeo copy --dest-tls-verify=false --dest-creds "admin:${ADMIN_PW}" \
  "docker://docker.io/library/busybox:1.37" \
  "docker://${HARBOR_HOST}/partner-b/secret-app:v1" >/dev/null 2>&1 || true

# partner-a 에서만 pull 할 수 있는 robot account 를 만든다.
ROBOT_JSON="$(harbor_api -X POST "http://${HARBOR_HOST}/api/v2.0/robots" -d '{
  "name": "partner-a-verify",
  "duration": -1,
  "level": "project",
  "permissions": [{
    "kind": "project", "namespace": "partner-a",
    "access": [{"resource": "repository", "action": "pull"}]
  }]
}' 2>/dev/null || echo '{}')"

ROBOT_NAME="$(echo "${ROBOT_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || true)"
ROBOT_SECRET="$(echo "${ROBOT_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('secret',''))" 2>/dev/null || true)"
ROBOT_ID="$(echo "${ROBOT_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)"

if [[ -z "${ROBOT_NAME}" || -z "${ROBOT_SECRET}" ]]; then
  fail "robot account 를 만들지 못했다"
else
  info "robot ${ROBOT_NAME} — partner-a 만 pull 가능"

  if skopeo inspect --tls-verify=false --creds "${ROBOT_NAME}:${ROBOT_SECRET}" \
       "docker://${HARBOR_HOST}/partner-b/secret-app:v1" >/dev/null 2>&1; then
    fail "partner-a 계정으로 partner-b 이미지를 받았다 — 격리 실패"
  else
    pass "partner-a 계정으로 partner-b 이미지 접근 거부됨"
  fi

  # 익명 접근도 막혀야 private 프로젝트다.
  if skopeo inspect --tls-verify=false \
       "docker://${HARBOR_HOST}/partner-b/secret-app:v1" >/dev/null 2>&1; then
    fail "익명으로 partner-b 이미지를 받았다 — private 설정을 확인할 것"
  else
    pass "익명 접근 거부됨 (private 프로젝트)"
  fi
fi

# ── 조건 6. 애플리케이션 정상 ────────────────────────────────────
log "조건 6 — ArgoCD 및 주문 플로우"

SYNC="$(kubectl get application eshop-dev -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
HEALTH="$(kubectl get application eshop-dev -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
if [[ "${SYNC}" == "Synced" && "${HEALTH}" == "Healthy" ]]; then
  pass "ArgoCD — Synced · Healthy"
else
  fail "ArgoCD sync=${SYNC:-없음} health=${HEALTH:-없음}"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if "${REPO_ROOT}/scripts/12-verify-eshop.sh" >/tmp/phase3-recheck.log 2>&1; then
  pass "주문 플로우 9개 항목 통과"
else
  fail "주문 플로우 검증 실패 — /tmp/phase3-recheck.log 확인"
  grep -E "FAIL" /tmp/phase3-recheck.log | sed 's/^/          /' || true
fi

# ── 결과 ─────────────────────────────────────────────────────────
printf '\n────────────────────────────────────\n'
printf '  통과 %d · 실패 %d\n' "${PASS}" "${FAIL}"
printf '────────────────────────────────────\n\n'

[[ "${FAIL}" -eq 0 ]] || exit 1
