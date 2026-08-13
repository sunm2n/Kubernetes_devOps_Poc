#!/usr/bin/env bash
#
# Phase 2 — 완료 조건 검증
#
# 이슈 #7 의 완료 조건을 순서대로 확인한다.
# 클러스터를 실제로 망가뜨린 뒤 ArgoCD 가 되돌리는지 본다.
#
#   사용법:  scripts/21-verify-gitops.sh
set -euo pipefail

CLUSTER_NAME="erp-poc"
ARGOCD_NS="argocd"
APP_NAME="eshop-dev"
APP_NS="eshop"

PASS=0
FAIL=0

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
pass() { printf '  \033[0;32m✓ PASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[0;31m✗ FAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '          %s\n' "$*"; }

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 \
  || { echo "클러스터 kind-${CLUSTER_NAME} 가 없다. scripts/00-bootstrap.sh 를 먼저 실행할 것." >&2; exit 1; }

app_field() {
  kubectl get application "${APP_NAME}" -n "${ARGOCD_NS}" -o jsonpath="{$1}" 2>/dev/null || true
}

# ── 조건 1. Application 이 Synced · Healthy ──────────────────────
log "조건 1 — Application 상태"

SYNC="$(app_field '.status.sync.status')"
HEALTH="$(app_field '.status.health.status')"

if [[ "${SYNC}" == "Synced" && "${HEALTH}" == "Healthy" ]]; then
  pass "eshop-dev — Synced · Healthy"
else
  fail "sync=${SYNC:-없음} health=${HEALTH:-없음} (기대: Synced · Healthy)"
fi
info "감시 브랜치 $(app_field '.spec.sources[0].targetRevision')  ·  경로 $(app_field '.spec.sources[0].path')"

# ── 조건 2. selfHeal ─────────────────────────────────────────────
# 이 PoC 의 검증 목표 2번이다.
# 클러스터를 사람이 직접 바꿔도 Git 상태로 되돌아와야 한다.
log "조건 2 — selfHeal (수동 변경분 자동 복구)"

DESIRED="$(kubectl get deployment catalog-api -n "${APP_NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")"
if [[ -z "${DESIRED}" ]]; then
  fail "catalog-api Deployment 를 찾을 수 없다"
else
  info "Git 기준 복제본 ${DESIRED}개 → 5개로 강제 변경"
  kubectl scale deployment catalog-api -n "${APP_NS}" --replicas=5 >/dev/null

  HEALED=""
  for i in $(seq 1 30); do
    CURRENT="$(kubectl get deployment catalog-api -n "${APP_NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    if [[ "${CURRENT}" == "${DESIRED}" && "${i}" -gt 1 ]]; then HEALED="$((i * 2))"; break; fi
    sleep 2
  done

  if [[ -n "${HEALED}" ]]; then
    pass "약 ${HEALED}초 만에 ${DESIRED}개로 복구"
    info "selfHeal 은 Git 폴링과 무관하다. 클러스터 변화를 감시해 즉시 반응한다"
  else
    fail "60초 내에 복구되지 않았다 (현재 $(kubectl get deployment catalog-api -n "${APP_NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null))"
    kubectl scale deployment catalog-api -n "${APP_NS}" --replicas="${DESIRED}" >/dev/null 2>&1 || true
  fi
fi

# ── 조건 3. prune ────────────────────────────────────────────────
log "조건 3 — prune (Git 에 없는 자원 제거)"

# ArgoCD 는 argocd.argoproj.io/tracking-id 어노테이션으로 자원의 소속을 판단한다.
# app.kubernetes.io/instance 라벨이 아니다.
# 이 어노테이션을 붙여 앱 소속으로 만들되 Git 에는 없는 자원을 만든다.
kubectl delete configmap prune-test -n "${APP_NS}" --ignore-not-found >/dev/null 2>&1
kubectl create configmap prune-test -n "${APP_NS}" --from-literal=note=not-in-git >/dev/null
kubectl annotate configmap prune-test -n "${APP_NS}" \
  "argocd.argoproj.io/tracking-id=${APP_NAME}:/ConfigMap:${APP_NS}/prune-test" >/dev/null

PRUNED=""
for i in $(seq 1 30); do
  kubectl get configmap prune-test -n "${APP_NS}" >/dev/null 2>&1 || { PRUNED="$((i * 2))"; break; }
  sleep 2
done

if [[ -n "${PRUNED}" ]]; then
  pass "약 ${PRUNED}초 만에 제거됨"
else
  fail "60초 내에 제거되지 않았다"
  kubectl delete configmap prune-test -n "${APP_NS}" --ignore-not-found >/dev/null 2>&1
fi

# ── 조건 4. 파드 11개 정상 ───────────────────────────────────────
log "조건 4 — ArgoCD 관리 하에서 애플리케이션 정상"

READY=$(kubectl get pods -n "${APP_NS}" --no-headers 2>/dev/null \
  | awk '{split($2, a, "/"); if (a[1] == a[2] && a[1] > 0 && $3 == "Running") c++} END {print c+0}')

if [[ "${READY}" == "11" ]]; then
  pass "파드 11개 전부 Running·Ready"
else
  fail "Ready ${READY}개 (기대: 11)"
  kubectl get pods -n "${APP_NS}" --no-headers 2>/dev/null \
    | awk '{split($2, a, "/"); if (a[1] != a[2] || $3 != "Running") print}' | sed 's/^/          /'
fi

# 모든 자원이 ArgoCD 소유인지 확인한다.
# 하나라도 빠져 있으면 그 자원은 selfHeal 대상이 아니다.
UNTRACKED=$(kubectl get deployment,statefulset -n "${APP_NS}" -o json 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
n=[i['metadata']['name'] for i in d['items']
   if 'argocd.argoproj.io/tracking-id' not in (i['metadata'].get('annotations') or {})]
print(' '.join(n))
" 2>/dev/null || true)

if [[ -z "${UNTRACKED}" ]]; then
  pass "Deployment·StatefulSet 전부 ArgoCD 추적 대상"
else
  fail "추적되지 않는 자원: ${UNTRACKED}"
fi

# ── 조건 5. 애플리케이션 기능 ────────────────────────────────────
log "조건 5 — 주문 플로우 (Phase 1 검증 재실행)"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if "${REPO_ROOT}/scripts/12-verify-eshop.sh" >/tmp/phase1-recheck.log 2>&1; then
  pass "Phase 1 검증 9개 항목 재통과"
else
  fail "Phase 1 검증 실패 — /tmp/phase1-recheck.log 확인"
  grep -E "FAIL" /tmp/phase1-recheck.log | sed 's/^/          /' || true
fi

# ── 결과 ─────────────────────────────────────────────────────────
printf '\n────────────────────────────────────\n'
printf '  통과 %d · 실패 %d\n' "${PASS}" "${FAIL}"
printf '────────────────────────────────────\n\n'

[[ "${FAIL}" -eq 0 ]] || exit 1
