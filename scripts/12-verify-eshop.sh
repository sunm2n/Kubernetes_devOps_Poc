#!/usr/bin/env bash
#
# Phase 1 — 완료 조건 검증
#
# 이슈 #4 의 완료 조건을 순서대로 확인한다.
# 실제 주문 플로우를 끝까지 태워 서비스 간 통신(HTTP · gRPC · AMQP)이
# 모두 성립하는지 본다.
#
#   사용법:  scripts/12-verify-eshop.sh
set -euo pipefail

CLUSTER_NAME="erp-poc"
NAMESPACE="eshop"
WEB="http://eshop.localtest.me"
API="http://api.eshop.localtest.me"

# 실행마다 다른 사용자로 검증해 이전 실행의 잔여 데이터와 섞이지 않게 한다.
USER="poc-$(date +%s)"
CUSTOMER="58c49479-ec65-4de2-86e7-033c546291aa"

EXPECTED_PODS=11
PASS=0
FAIL=0

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
pass() { printf '  \033[0;32m✓ PASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[0;31m✗ FAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '          %s\n' "$*"; }

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 \
  || { echo "클러스터 kind-${CLUSTER_NAME} 가 없다. scripts/00-bootstrap.sh 를 먼저 실행할 것." >&2; exit 1; }

# ── 조건 1. 파드 11개 Ready ──────────────────────────────────────
log "조건 1 — 파드 ${EXPECTED_PODS}개 Ready"

# READY 열은 "1/1" 형태다. 앞뒤 값이 같아야 컨테이너가 모두 준비된 것이다.
# awk 의 정규식은 POSIX ERE 라 역참조(\1)를 지원하지 않으므로 split 으로 비교한다.
READY=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | awk '{split($2, a, "/"); if (a[1] == a[2] && a[1] > 0 && $3 == "Running") c++} END {print c+0}')
TOTAL=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "${READY}" == "${EXPECTED_PODS}" && "${TOTAL}" == "${EXPECTED_PODS}" ]]; then
  pass "파드 ${EXPECTED_PODS}개 전부 Running·Ready"
else
  fail "Ready ${READY} / 전체 ${TOTAL} (기대: ${EXPECTED_PODS})"
  kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | awk '{split($2, a, "/"); if (a[1] != a[2] || $3 != "Running") print}' | sed 's/^/          /'
fi

RESTARTS=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | awk '{s += $4} END {print s+0}')
info "누적 재시작 ${RESTARTS}회"

# ── 조건 2. Ingress 경유 화면 접속 ───────────────────────────────
log "조건 2 — Ingress → shopping-web"

CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${WEB}/" 2>/dev/null || true)
if [[ "${CODE}" == "200" ]]; then
  pass "${WEB}/ → 200"
else
  fail "${WEB}/ → ${CODE:-응답 없음}"
fi

# 화면이 게이트웨이를 거쳐 Catalog 까지 닿았는지 본다.
# 200 만으로는 상품 목록이 비어 있어도 통과해 버린다.
RENDERED=$(curl -s --max-time 15 "${WEB}/" 2>/dev/null | grep -coE "IPhone X|Samsung 10|Huawei Plus" || true)
if [[ "${RENDERED}" -gt 0 ]]; then
  pass "화면에 상품이 렌더링됨 (web → gateway → catalog 경로 성립)"
else
  fail "화면에 상품이 보이지 않는다"
fi

# ── 조건 3. 주문 플로우 ──────────────────────────────────────────
log "조건 3 — 상품 조회 → 장바구니 → 주문"

PID=$(curl -s --max-time 15 "${API}/catalog-service/products" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['products'][0]['id'])" 2>/dev/null || true)

if [[ -n "${PID}" ]]; then
  pass "상품 조회 — Catalog API 응답 (id ${PID:0:8}…)"
else
  fail "상품 조회 실패"
fi

# 장바구니 담기. Basket 은 저장 전에 Discount 를 gRPC 로 호출해 할인가를 적용한다.
STORE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
  -X POST "${API}/basket-service/basket" -H 'Content-Type: application/json' \
  -d "{\"cart\":{\"userName\":\"${USER}\",\"items\":[{\"quantity\":2,\"color\":\"Black\",\"price\":950,\"productId\":\"${PID}\",\"productName\":\"IPhone X\"}]}}" \
  2>/dev/null || true)

if [[ "${STORE}" == "201" ]]; then
  pass "장바구니 담기 → 201"
else
  fail "장바구니 담기 → ${STORE:-응답 없음} (기대: 201)"
fi

# 정가 950 이 할인가 800 으로 저장됐는지 확인한다.
# 이 값이 950 그대로면 gRPC 호출이 실패하고 조용히 원가가 쓰인 것이다.
PRICE=$(curl -s --max-time 15 "${API}/basket-service/basket/${USER}" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['cart']['items'][0]['price'])" 2>/dev/null || true)

if [[ "${PRICE}" == "800" ]]; then
  pass "Discount gRPC 적용 — 950 → 800 (평문 HTTP/2 경로 성립)"
else
  fail "할인가 ${PRICE:-없음} (기대: 800). Discount gRPC 호출을 확인할 것"
fi

# ── 조건 4. RabbitMQ 이벤트 전달 ─────────────────────────────────
log "조건 4 — 체크아웃 → RabbitMQ → 주문 생성"

CHECKOUT=$(curl -s --max-time 20 -X POST "${API}/basket-service/basket/checkout" \
  -H 'Content-Type: application/json' \
  -d "{\"basketCheckoutDto\":{\"userName\":\"${USER}\",\"customerId\":\"${CUSTOMER}\",\"totalPrice\":1600,\"firstName\":\"PoC\",\"lastName\":\"Verify\",\"emailAddress\":\"poc@example.com\",\"addressLine\":\"Seoul\",\"country\":\"KR\",\"state\":\"Seoul\",\"zipCode\":\"04524\",\"cardName\":\"PoC Card\",\"cardNumber\":\"4111111111111111\",\"expiration\":\"12/30\",\"cvv\":\"123\",\"paymentMethod\":1}}" \
  2>/dev/null || true)

if echo "${CHECKOUT}" | grep -q '"isSuccess":true'; then
  pass "체크아웃 → 이벤트 발행"
else
  fail "체크아웃 실패: ${CHECKOUT:-응답 없음}"
fi

# Ordering 이 이벤트를 소비해 주문을 만들 때까지 기다린다.
# 비동기 경로이므로 즉시 조회하면 아직 없을 수 있다.
FOUND=""
for _ in $(seq 1 15); do
  if curl -s --max-time 15 "${API}/ordering-service/orders" 2>/dev/null | grep -q "${USER}"; then
    FOUND="1"; break
  fi
  sleep 2
done

if [[ -n "${FOUND}" ]]; then
  pass "주문 생성 확인 — Basket → RabbitMQ → Ordering 비동기 경로 성립"
else
  fail "30초 내에 주문이 생성되지 않았다. Ordering 로그와 RabbitMQ 큐를 확인할 것"
fi

# 체크아웃이 끝나면 장바구니는 비워져야 한다.
EMPTY=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  "${API}/basket-service/basket/${USER}" 2>/dev/null || true)
if [[ "${EMPTY}" == "404" || "${EMPTY}" == "400" || "${EMPTY}" == "500" ]]; then
  pass "체크아웃 후 장바구니 삭제됨 (HTTP ${EMPTY})"
else
  fail "체크아웃 후에도 장바구니가 남아 있다 (HTTP ${EMPTY})"
fi

# ── 결과 ─────────────────────────────────────────────────────────
printf '\n────────────────────────────────────\n'
printf '  통과 %d · 실패 %d\n' "${PASS}" "${FAIL}"
printf '────────────────────────────────────\n\n'

[[ "${FAIL}" -eq 0 ]] || exit 1
