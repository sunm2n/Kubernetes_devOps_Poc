#!/usr/bin/env bash
#
# Phase 0 — 완료 조건 검증
#
# 이슈 #1 의 완료 조건을 순서대로 확인한다.
# 샘플 워크로드를 띄워 호스트에서 Ingress 를 통해 닿는지까지 본다.
# 검증이 끝나면 샘플은 네임스페이스째 정리한다.
#
#   사용법:  scripts/01-verify.sh
set -euo pipefail

CLUSTER_NAME="erp-poc"
INGRESS_NODE="${CLUSTER_NAME}-worker"
SAMPLE_NS="poc-verify"
SAMPLE_HOST="whoami.localtest.me"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLE_MANIFEST="${REPO_ROOT}/infra/samples/whoami.yaml"

PASS=0
FAIL=0

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
pass() { printf '  \033[0;32m✓ PASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[0;31m✗ FAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '          %s\n' "$*"; }

cleanup() {
  kubectl delete -f "${SAMPLE_MANIFEST}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 \
  || { echo "클러스터 kind-${CLUSTER_NAME} 가 없다. scripts/00-bootstrap.sh 를 먼저 실행할 것." >&2; exit 1; }

# ── 조건 1. 노드 3대가 모두 Ready ────────────────────────────────
log "조건 1 — 노드 3대 Ready"

READY_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l | tr -d ' ')"
TOTAL_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"

if [[ "${READY_COUNT}" == "3" && "${TOTAL_COUNT}" == "3" ]]; then
  pass "노드 3대 전부 Ready"
else
  fail "Ready ${READY_COUNT} / 전체 ${TOTAL_COUNT} (기대: 3 / 3)"
fi
kubectl get nodes --no-headers | awk '{ printf "          %-28s %-8s %s\n", $1, $2, $3 }'

# ── 조건 2. Ingress 컨트롤러가 지정 노드에서 동작 ────────────────
log "조건 2 — Ingress 컨트롤러 배치"

CONTROLLER_NODE="$(kubectl get pods -n ingress-nginx \
  -l app.kubernetes.io/component=controller \
  -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"

if [[ "${CONTROLLER_NODE}" == "${INGRESS_NODE}" ]]; then
  pass "컨트롤러가 ${INGRESS_NODE} 에 배치됨 (호스트 포트 매핑 노드)"
else
  fail "컨트롤러 위치: '${CONTROLLER_NODE:-없음}' (기대: ${INGRESS_NODE})"
fi

# ── 조건 3. 호스트에서 Ingress 경유 접속 ─────────────────────────
log "조건 3 — 호스트 → Ingress → 파드 경로"

kubectl apply -f "${SAMPLE_MANIFEST}" >/dev/null
info "샘플 워크로드 배포, 준비 대기 중"

if kubectl wait --namespace "${SAMPLE_NS}" \
     --for=condition=Available deployment/whoami --timeout=120s >/dev/null 2>&1; then
  info "샘플 파드 Ready"
else
  fail "샘플 워크로드가 준비되지 않았다"
  kubectl get pods -n "${SAMPLE_NS}" 2>&1 | sed 's/^/          /'
fi

# Ingress 컨트롤러가 규칙을 반영할 때까지 잠깐 여유를 준다.
HTTP_CODE=""
for _ in $(seq 1 20); do
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${SAMPLE_HOST}/" 2>/dev/null || true)"
  [[ "${HTTP_CODE}" == "200" ]] && break
  sleep 2
done

if [[ "${HTTP_CODE}" == "200" ]]; then
  pass "http://${SAMPLE_HOST}/ → 200"
  curl -s --max-time 5 "http://${SAMPLE_HOST}/" | grep -E '^(Hostname|RemoteAddr)' | sed 's/^/          /' || true
else
  fail "http://${SAMPLE_HOST}/ → ${HTTP_CODE:-응답 없음} (기대: 200)"
fi

# ── 조건 4. 워커 2대에 분산 배치 ─────────────────────────────────
log "조건 4 — 멀티 노드 스케줄링"

DISTINCT_NODES="$(kubectl get pods -n "${SAMPLE_NS}" -l app=whoami \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u | grep -c . || echo 0)"

if [[ "${DISTINCT_NODES}" -ge 2 ]]; then
  pass "복제본 2개가 서로 다른 노드 ${DISTINCT_NODES}대에 배치됨"
else
  # 단일 노드 배치가 곧 실패는 아니다. whenUnsatisfiable: ScheduleAnyway 이므로
  # 스케줄러가 다른 조건을 우선했을 수 있다. 다만 멀티 노드 구성의 의미는 줄어든다.
  fail "복제본이 노드 ${DISTINCT_NODES}대에만 배치됨 (기대: 2대 이상)"
fi
kubectl get pods -n "${SAMPLE_NS}" -l app=whoami \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName' --no-headers 2>/dev/null \
  | sed 's/^/          /' || true

# ── 결과 ─────────────────────────────────────────────────────────
printf '\n────────────────────────────────────\n'
printf '  통과 %d · 실패 %d\n' "${PASS}" "${FAIL}"
printf '────────────────────────────────────\n\n'

[[ "${FAIL}" -eq 0 ]] || exit 1
