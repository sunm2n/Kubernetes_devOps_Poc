#!/usr/bin/env bash
#
# Phase 5 — SonarQube 설치 및 CI 토큰 발급
#
# 정적분석 서버를 클러스터에 올리고, CI 가 쓸 토큰을 만들어 출력한다.
#
#   사용법:  scripts/50-install-sonarqube.sh
#            scripts/50-install-sonarqube.sh token   토큰만 다시 발급
set -euo pipefail

CLUSTER_NAME="erp-poc"
SONAR_NS="sonarqube"
SONAR_HOST="sonarqube.localtest.me"
SONAR_CHART_VERSION="2026.4.1"
ADMIN_USER="admin"
ADMIN_PW="SonarPoC12345!"
TOKEN_NAME="erp-poc-ci"
APP_REPO="sunm2n/net8_Microservices"
PROJECT_KEY="eshop-microservices"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SONAR_VALUES="${REPO_ROOT}/infra/sonarqube/values.yaml"

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[0;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

api() { curl -s --max-time 30 -u "${ADMIN_USER}:${ADMIN_PW}" "$@"; }

# 토큰을 새로 발급한다.
#
# SonarQube 는 토큰 값을 생성 시점에만 돌려주고 이후에는 조회할 수 없다.
# 그래서 같은 이름의 것을 지우고 다시 만드는 수밖에 없는데,
# 이때 앱 저장소 시크릿에 들어 있던 이전 토큰이 그 순간 무효가 된다.
#
# 실제로 이것 때문에 CI 의 정적분석 단계가 인증 실패로 멈췄다.
# 로컬에서 스크립트를 시험하려고 token 을 두 번 부르는 사이 시크릿이 죽어 있었다.
# 발급하면 반드시 시크릿까지 함께 갱신한다.
issue_token() {
  api -X POST "http://${SONAR_HOST}/api/user_tokens/revoke" \
    --data-urlencode "name=${TOKEN_NAME}" >/dev/null 2>&1 || true

  api -X POST "http://${SONAR_HOST}/api/user_tokens/generate" \
    --data-urlencode "name=${TOKEN_NAME}" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true
}

sync_secret() {
  local token="$1"
  command -v gh >/dev/null 2>&1 || { warn "gh 가 없어 시크릿을 갱신하지 못했다"; return; }
  gh secret set SONAR_TOKEN --repo "${APP_REPO}" --body "${token}" >/dev/null 2>&1 \
    && ok "${APP_REPO} 의 SONAR_TOKEN 갱신" \
    || warn "시크릿 갱신 실패 — 수동으로 등록할 것"
}

if [[ "${1:-install}" == "token" ]]; then
  TOKEN="$(issue_token)"
  [[ -n "${TOKEN}" ]] || die "토큰 발급 실패. SonarQube 가 떠 있는지 확인할 것."
  # 발급과 동시에 시크릿을 맞춰 이전 토큰이 죽은 채로 남지 않게 한다.
  sync_secret "${TOKEN}" >&2
  echo "${TOKEN}"
  exit 0
fi

kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}" \
  || die "kind 클러스터 '${CLUSTER_NAME}' 가 없다. scripts/00-bootstrap.sh 를 먼저 실행할 것."
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# ── 1. 설치 ──────────────────────────────────────────────────────
log "SonarQube ${SONAR_CHART_VERSION}"

helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube >/dev/null 2>&1 || true
helm repo update sonarqube >/dev/null 2>&1 || helm repo update >/dev/null 2>&1
ok "Helm 저장소 갱신"

# Elasticsearch 기동과 DB 마이그레이션에 시간이 걸린다.
helm upgrade --install sonarqube sonarqube/sonarqube \
  --namespace "${SONAR_NS}" \
  --create-namespace \
  --version "${SONAR_CHART_VERSION}" \
  --values "${SONAR_VALUES}" \
  --wait \
  --timeout 20m >/dev/null
ok "설치 완료"

# ── 2. 기동 대기 ─────────────────────────────────────────────────
log "기동 대기 (최대 10분)"

for i in $(seq 1 120); do
  STATUS="$(curl -s --max-time 5 "http://${SONAR_HOST}/api/system/status" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)"
  printf '\r  [%3ds] %s' "$((i * 5))" "${STATUS:-대기}"
  [[ "${STATUS}" == "UP" ]] && break
  sleep 5
done
echo
[[ "${STATUS}" == "UP" ]] || die "SonarQube 가 UP 상태가 되지 않았다.
  kubectl logs -n ${SONAR_NS} -l app=sonarqube 로 확인할 것."
ok "status UP"

# ── 3. 프로젝트 생성 ─────────────────────────────────────────────
log "프로젝트 '${PROJECT_KEY}'"

CODE="$(api -o /dev/null -w '%{http_code}' -X POST "http://${SONAR_HOST}/api/projects/create" \
  --data-urlencode "project=${PROJECT_KEY}" \
  --data-urlencode "name=EShop Microservices" 2>/dev/null || true)"
case "${CODE}" in
  200) ok "생성 완료" ;;
  400) ok "이미 존재" ;;
  *)   warn "생성 응답 HTTP ${CODE}" ;;
esac

# ── 4. CI 토큰 ───────────────────────────────────────────────────
log "CI 토큰 발급"

TOKEN="$(issue_token)"
[[ -n "${TOKEN}" ]] || die "토큰 발급 실패"
ok "${TOKEN_NAME}"
sync_secret "${TOKEN}"

log "상태"
kubectl get pods -n "${SONAR_NS}" --no-headers 2>/dev/null | head -5

cat <<EOF

$(printf '\033[1;32mSonarQube 준비 완료\033[0m')

  UI        http://${SONAR_HOST}
  계정      ${ADMIN_USER} / ${ADMIN_PW}
  프로젝트  ${PROJECT_KEY}

  CI 토큰   ${TOKEN}

  앱 저장소(${APP_REPO})의 SONAR_TOKEN 시크릿은 위에서 함께 갱신했다.

  토큰 재발급  scripts/50-install-sonarqube.sh token
               재발급하면 이전 토큰이 즉시 무효가 되므로 시크릿도 함께 갱신된다.

EOF
