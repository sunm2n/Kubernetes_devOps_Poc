#!/usr/bin/env bash
#
# Phase 6a — 완료 조건 검증
#
# 이슈 #22 의 완료 조건을 순서대로 확인한다.
#
# 검증은 전부 점프 호스트에서 한다.
# 호스트(맥)에서 curl 이 성공하는 것은 아무것도 증명하지 못한다.
# 호스트는 인터넷에 연결돼 있고 폐쇄망 밖에 있기 때문이다.
#
#   사용법:  scripts/63-verify-airgap.sh
#            scripts/63-verify-airgap.sh --skip-dev   개발계 재검증 생략
set -euo pipefail

CLUSTER_NAME="erp-airgap"
NETWORK="erp-airgap-net"
JUMP="airgap-jump"
GITLAB="airgap-gitlab"
NAMESPACE="eshop"

HARBOR_HOST="harbor.airgap"
GITLAB_HOST="gitlab.airgap"
WEB="http://eshop.airgap"
API="http://api.eshop.airgap"

EXPECTED_PODS=11
USER="airgap-$(date +%s)"
CUSTOMER="58c49479-ec65-4de2-86e7-033c546291aa"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "${REPO_ROOT}" == /* ]] \
  || REPO_ROOT="$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd)")"

BUNDLE="${REPO_ROOT}/.bundle"

PASS=0
FAIL=0

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
pass() { printf '  \033[0;32m✓ PASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[0;31m✗ FAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '          %s\n' "$*"; }

jump()   { docker exec "${JUMP}" "$@"; }
jumpsh() { docker exec -i "${JUMP}" sh -c "$1"; }
kc()     { docker exec "${JUMP}" kubectl "$@"; }

docker inspect "${JUMP}" >/dev/null 2>&1 \
  || { echo "점프 호스트가 없다. scripts/62-import-bundle.sh 를 먼저 실행할 것." >&2; exit 1; }

# ── 조건 1. 격리 ─────────────────────────────────────────────────
#
# 이것이 먼저다. 막히지 않은 상태에서 나머지가 통과하면 의미가 없다.
log "조건 1 — 폐쇄망이 실제로 닫혀 있는가"

BLOCKED=0
NODES=0
for node in $(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null); do
  NODES=$((NODES + 1))
  docker exec "${node}" timeout 8 curl -sf -o /dev/null https://www.google.com >/dev/null 2>&1 \
    || BLOCKED=$((BLOCKED + 1))
done

if [[ "${NODES}" -gt 0 && "${BLOCKED}" == "${NODES}" ]]; then
  pass "클러스터 노드 ${NODES}대 전부 외부 HTTP 차단"
else
  fail "노드 ${NODES}대 중 ${BLOCKED}대만 차단됨"
fi

# HTTP 만 막혀 있고 레지스트리는 열려 있는 상황을 배제한다.
if docker exec "${CLUSTER_NAME}-worker" timeout 25 crictl pull alpine:3.21 >/dev/null 2>&1; then
  fail "노드가 외부 레지스트리에서 이미지를 받았다"
else
  pass "외부 레지스트리 pull 불가"
fi

for c in "${JUMP}" "${GITLAB}"; do
  if docker exec "${c}" timeout 8 curl -sf -o /dev/null https://www.google.com >/dev/null 2>&1; then
    fail "${c} 가 외부에 닿는다"
  else
    pass "${c} 외부 접근 불가"
  fi
done

# ── 조건 2. 번들만으로 반입됐는가 ────────────────────────────────
log "조건 2 — 반입 경로"

if [[ -f "${BUNDLE}/MANIFEST.txt" ]]; then
  BSIZE="$(du -sh "${BUNDLE}" | awk '{print $1}')"
  NIMG="$(grep -c '' "${BUNDLE}/images/payload.txt" 2>/dev/null || echo 0)"
  NBOOT="$(grep -c '' "${BUNDLE}/images/bootstrap.txt" 2>/dev/null || echo 0)"
  pass "번들 ${BSIZE} — 부트스트랩 ${NBOOT}개 · 페이로드 ${NIMG}개"
else
  fail "번들 명세가 없다"
fi

# 점프 호스트가 번들 외의 것을 쓰지 않았음을 확인한다.
MOUNT_RO="$(docker inspect "${JUMP}" \
  --format '{{range .Mounts}}{{.Destination}}:{{.RW}} {{end}}' 2>/dev/null || true)"
if [[ "${MOUNT_RO}" == *"/bundle:false"* ]]; then
  pass "점프 호스트의 번들 마운트가 읽기 전용"
else
  fail "번들 마운트 상태 확인 실패 (${MOUNT_RO})"
fi

# ── 조건 3. 망 안의 GitLab 을 ArgoCD 가 본다 ─────────────────────
log "조건 3 — 폐쇄망 GitOps"

if jump curl -sf -o /dev/null --max-time 10 "http://${GITLAB_HOST}/-/readiness" 2>/dev/null; then
  pass "GitLab 응답 (http://${GITLAB_HOST})"
else
  fail "GitLab 이 응답하지 않는다"
fi

REPO_URL="$(kc -n argocd get application eshop-airgap \
  -o jsonpath='{.spec.sources[0].repoURL}' 2>/dev/null || true)"
if [[ "${REPO_URL}" == *"${GITLAB_HOST}"* ]]; then
  pass "Application 이 망 안의 저장소를 본다 — ${REPO_URL}"
elif [[ "${REPO_URL}" == *github.com* ]]; then
  fail "Application 이 아직 github.com 을 본다 (${REPO_URL})"
else
  fail "Application repoURL 을 읽지 못했다"
fi

SYNC="$(kc -n argocd get application eshop-airgap \
  -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
if [[ "${SYNC}" == "Synced/Healthy" ]]; then
  pass "동기화 상태 ${SYNC}"
else
  fail "동기화 상태 ${SYNC:-읽지 못함} (기대: Synced/Healthy)"
fi

REV="$(kc -n argocd get application eshop-airgap \
  -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
[[ -n "${REV}" ]] && info "동기화된 리비전 ${REV:0:12}"

# ── 조건 4. 파드 11개 · 이미지 출처 ──────────────────────────────
log "조건 4 — 인터넷 없이 기동한 파드"

READY="$(kc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | awk '{split($2,a,"/"); if (a[1]==a[2] && a[1]>0 && $3=="Running") c++} END {print c+0}')"
TOTAL="$(kc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"

if [[ "${READY}" == "${EXPECTED_PODS}" && "${TOTAL}" == "${EXPECTED_PODS}" ]]; then
  pass "파드 ${EXPECTED_PODS}개 전부 Running·Ready"
else
  fail "Ready ${READY} / 전체 ${TOTAL} (기대: ${EXPECTED_PODS})"
  kc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | awk '{split($2,a,"/"); if (a[1]!=a[2] || $3!="Running") print}' | sed 's/^/          /'
fi

# 이 단계의 실질이다.
# 파드가 떴다는 것만으로는 부족하다. 이미지가 어디서 왔는지가 증명 대상이다.
IMAGES="$(kc get pods -n "${NAMESPACE}" \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
  | sort -u | grep -v '^$' || true)"
OUTSIDE="$(echo "${IMAGES}" | grep -vc "^${HARBOR_HOST}/" || true)"

if [[ "${OUTSIDE}" == "0" ]]; then
  pass "이미지 $(echo "${IMAGES}" | grep -c .)종 전부 ${HARBOR_HOST} 출처"
  echo "${IMAGES}" | sed 's/^/            /'
else
  fail "${HARBOR_HOST} 밖에서 온 이미지가 ${OUTSIDE}종 있다"
  echo "${IMAGES}" | grep -v "^${HARBOR_HOST}/" | sed 's/^/          /'
fi

# 이미지를 못 받아 재시도한 흔적이 있으면 반입이 불완전했다는 뜻이다.
PULLFAIL="$(kc get events -n "${NAMESPACE}" --field-selector reason=Failed \
  -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -ci 'pull' || true)"
if [[ "${PULLFAIL}" == "0" ]]; then
  pass "이미지 pull 실패 이벤트 없음"
else
  fail "이미지 pull 실패 이벤트 ${PULLFAIL}건"
fi

# ── 조건 5. 주문 플로우 ──────────────────────────────────────────
#
# 개발계 검증(12-verify-eshop.sh)과 같은 경로를 태운다.
# HTTP · gRPC · AMQP 세 가지가 폐쇄망에서도 성립하는지 본다.
log "조건 5 — 주문 플로우 (점프 호스트에서)"

CODE="$(jump curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${WEB}/" 2>/dev/null || true)"
if [[ "${CODE}" == "200" ]]; then
  pass "${WEB}/ → 200"
else
  fail "${WEB}/ → ${CODE:-응답 없음}"
fi

RENDERED="$(jump curl -s --max-time 15 "${WEB}/" 2>/dev/null \
  | grep -coE "IPhone X|Samsung 10|Huawei Plus" || true)"
if [[ "${RENDERED}" -gt 0 ]]; then
  pass "화면에 상품 렌더링 (web → gateway → catalog)"
else
  fail "화면에 상품이 보이지 않는다"
fi

PID="$(jump curl -s --max-time 15 "${API}/catalog-service/products" 2>/dev/null \
  | jump python3 -c "import json,sys; print(json.load(sys.stdin)['products'][0]['id'])" 2>/dev/null || true)"
if [[ -n "${PID}" ]]; then
  pass "상품 조회 — Catalog API (id ${PID:0:8}…)"
else
  fail "상품 조회 실패"
fi

STORE="$(jump curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
  -X POST "${API}/basket-service/basket" -H 'Content-Type: application/json' \
  -d "{\"cart\":{\"userName\":\"${USER}\",\"items\":[{\"quantity\":2,\"color\":\"Black\",\"price\":950,\"productId\":\"${PID}\",\"productName\":\"IPhone X\"}]}}" \
  2>/dev/null || true)"
if [[ "${STORE}" == "201" ]]; then
  pass "장바구니 담기 → 201"
else
  fail "장바구니 담기 → ${STORE:-응답 없음}"
fi

# 950 이 800 으로 바뀌었으면 Discount 를 gRPC 로 부른 것이다.
PRICE="$(jump curl -s --max-time 15 "${API}/basket-service/basket/${USER}" 2>/dev/null \
  | jump python3 -c "import json,sys; print(json.load(sys.stdin)['cart']['items'][0]['price'])" 2>/dev/null || true)"
if [[ "${PRICE}" == "800" ]]; then
  pass "Discount gRPC 적용 — 950 → 800"
else
  fail "할인가 ${PRICE:-없음} (기대: 800)"
fi

CHECKOUT="$(jump curl -s --max-time 20 -X POST "${API}/basket-service/basket/checkout" \
  -H 'Content-Type: application/json' \
  -d "{\"basketCheckoutDto\":{\"userName\":\"${USER}\",\"customerId\":\"${CUSTOMER}\",\"totalPrice\":1600,\"firstName\":\"Airgap\",\"lastName\":\"Verify\",\"emailAddress\":\"poc@example.com\",\"addressLine\":\"Seoul\",\"country\":\"KR\",\"state\":\"Seoul\",\"zipCode\":\"04524\",\"cardName\":\"PoC Card\",\"cardNumber\":\"4111111111111111\",\"expiration\":\"12/30\",\"cvv\":\"123\",\"paymentMethod\":1}}" \
  2>/dev/null || true)"
if echo "${CHECKOUT}" | grep -q '"isSuccess":true'; then
  pass "체크아웃 → 이벤트 발행"
else
  fail "체크아웃 실패: ${CHECKOUT:-응답 없음}"
fi

# 목록이 아니라 이름으로 조회한다. 이 엔드포인트는 없는 이름에도 200 을 준다.
FOUND=""
for _ in $(seq 1 15); do
  COUNT="$(jump curl -s --max-time 15 "${API}/ordering-service/orders/${USER}" 2>/dev/null \
    | jump python3 -c "
import json,sys
try:
    print(len(json.load(sys.stdin).get('orders', [])))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
  if [[ "${COUNT}" -gt 0 ]]; then FOUND="1"; break; fi
  sleep 2
done

if [[ -n "${FOUND}" ]]; then
  pass "주문 생성 — Basket → RabbitMQ → Ordering 비동기 경로 성립"
else
  fail "30초 내에 주문이 생성되지 않았다"
fi

# ── 조건 6. 개발계 영향 없음 ─────────────────────────────────────
log "조건 6 — 개발계 클러스터"

if [[ "${1:-}" == "--skip-dev" ]]; then
  info "생략됨 (--skip-dev)"
elif kind get clusters 2>/dev/null | grep -qx "erp-poc"; then
  if "${REPO_ROOT}/scripts/12-verify-eshop.sh" >/tmp/airgap-devcheck.log 2>&1; then
    pass "개발계 검증 재통과 — 폐쇄망 구축이 개발계에 영향 없음"
  else
    fail "개발계 검증 실패 — /tmp/airgap-devcheck.log 확인"
    grep -E "FAIL" /tmp/airgap-devcheck.log | sed 's/^/          /' || true
  fi
else
  fail "개발계 클러스터 erp-poc 가 없다"
fi

# ── 자원 사용량 ──────────────────────────────────────────────────
log "자원 사용량 (참고)"

docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}' 2>/dev/null \
  | grep -E "erp-airgap|airgap-" | sed 's/^/          /' || true

# ── 결과 ─────────────────────────────────────────────────────────
printf '\n────────────────────────────────────\n'
printf '  통과 %d · 실패 %d\n' "${PASS}" "${FAIL}"
printf '────────────────────────────────────\n\n'

[[ "${FAIL}" -eq 0 ]] || exit 1
