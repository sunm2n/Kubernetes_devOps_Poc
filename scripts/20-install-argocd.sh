#!/usr/bin/env bash
#
# Phase 2 — ArgoCD 설치 및 Application 등록
#
# ArgoCD 를 설치하고 eshop-dev Application 을 등록한다.
# 등록 이후 클러스터 상태는 Git 이 결정한다.
#
#   사용법:  scripts/20-install-argocd.sh
#
#   감시할 브랜치를 바꾸려면:
#     ARGOCD_TARGET_REVISION=feat/my-branch scripts/20-install-argocd.sh
#
#   기본값은 Application 매니페스트에 적힌 dev 다.
#   머지 전 작업 브랜치에서 검증할 때만 덮어쓴다.
set -euo pipefail

CLUSTER_NAME="erp-poc"
ARGOCD_NS="argocd"
ARGOCD_CHART_VERSION="10.3.3"   # ArgoCD v3.5.1
APP_NAME="eshop-dev"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGOCD_VALUES="${REPO_ROOT}/argocd/values.yaml"
APP_MANIFEST="${REPO_ROOT}/argocd/applications/eshop-dev.yaml"

TARGET_REVISION="${ARGOCD_TARGET_REVISION:-}"

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[0;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}" \
  || die "kind 클러스터 '${CLUSTER_NAME}' 가 없다. scripts/00-bootstrap.sh 를 먼저 실행할 것."
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# ── 1. 기존 Helm 릴리스 정리 ─────────────────────────────────────
# Phase 1은 helm 으로 직접 배포했다. 같은 자원을 ArgoCD 가 관리하려 하면
# 소유권이 겹쳐 동기화가 계속 실패한다.
# 릴리스만 제거하고 네임스페이스와 PVC 는 남긴다 — ArgoCD 가 이어받는다.
log "기존 Helm 릴리스 확인"
if helm status eshop -n eshop >/dev/null 2>&1; then
  warn "Phase 1의 Helm 릴리스가 남아 있다. ArgoCD 로 이관하기 위해 제거한다"
  # --no-hooks 로 정리 훅을 건너뛰고, 자원은 다음 단계에서 ArgoCD 가 다시 만든다.
  helm uninstall eshop -n eshop --wait >/dev/null 2>&1 || true
  ok "릴리스 제거 완료 (네임스페이스·PVC 는 유지)"
else
  ok "정리할 릴리스 없음"
fi

# ── 2. ArgoCD 설치 ───────────────────────────────────────────────
log "ArgoCD ${ARGOCD_CHART_VERSION}"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null 2>&1 || helm repo update >/dev/null 2>&1
ok "Helm 저장소 갱신"

helm upgrade --install argocd argo/argo-cd \
  --namespace "${ARGOCD_NS}" \
  --create-namespace \
  --version "${ARGOCD_CHART_VERSION}" \
  --values "${ARGOCD_VALUES}" \
  --wait \
  --timeout 10m >/dev/null
ok "설치 완료"

log "ArgoCD 기동 대기"
kubectl wait --namespace "${ARGOCD_NS}" \
  --for=condition=Available deployment --all --timeout=300s >/dev/null
ok "전체 Deployment Available"

# ── 3. Application 등록 ──────────────────────────────────────────
log "Application '${APP_NAME}' 등록"

if [[ -n "${TARGET_REVISION}" ]]; then
  # 머지 전 검증용. 매니페스트의 targetRevision 을 임시로 바꿔 적용한다.
  # 파일 자체는 고치지 않는다 — Git 에 남는 정의는 dev 를 가리켜야 한다.
  warn "감시 브랜치를 '${TARGET_REVISION}' 로 덮어쓴다 (검증용)"
  sed "s|targetRevision: dev|targetRevision: ${TARGET_REVISION}|g" "${APP_MANIFEST}" \
    | kubectl apply -f - >/dev/null
else
  kubectl apply -f "${APP_MANIFEST}" >/dev/null
fi
ok "등록 완료"

log "최초 동기화 대기 (최대 10분)"
# 이미지 6개와 인프라 5종이 뜨는 시간이 필요하다.
# SQL Server 는 Rosetta 변환이라 기동에만 약 2분 걸린다.
for i in $(seq 1 60); do
  SYNC=$(kubectl get application "${APP_NAME}" -n "${ARGOCD_NS}" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  HEALTH=$(kubectl get application "${APP_NAME}" -n "${ARGOCD_NS}" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  printf '\r  [%3ds] sync=%-12s health=%-12s' "$((i * 10))" "${SYNC:-?}" "${HEALTH:-?}"
  [[ "${SYNC}" == "Synced" && "${HEALTH}" == "Healthy" ]] && break
  sleep 10
done
echo

if [[ "${SYNC}" == "Synced" && "${HEALTH}" == "Healthy" ]]; then
  ok "Synced · Healthy"
else
  warn "sync=${SYNC:-?} health=${HEALTH:-?} — 아직 진행 중이거나 문제가 있다"
  kubectl get application "${APP_NAME}" -n "${ARGOCD_NS}" \
    -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' 2>/dev/null \
    | sed 's/^/          /' || true
fi

# ── 4. 접속 정보 ─────────────────────────────────────────────────
ADMIN_PW="$(kubectl get secret argocd-initial-admin-secret -n "${ARGOCD_NS}" \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "(조회 실패)")"

log "배포 상태"
kubectl get pods -n eshop --no-headers 2>/dev/null | head -12

cat <<EOF

$(printf '\033[1;32mArgoCD 준비 완료\033[0m')

  UI       http://argocd.localtest.me
  계정     admin
  비밀번호 ${ADMIN_PW}

  검증     scripts/21-verify-gitops.sh

  이후 배포는 Git 커밋으로 한다.
  envs/dev/values.yaml 을 고쳐 푸시하면 ArgoCD 가 반영한다.

EOF
