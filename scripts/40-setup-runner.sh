#!/usr/bin/env bash
#
# Phase 4 — GitHub Actions self-hosted 러너 설치·등록
#
# 앱 저장소(net8_Microservices)의 워크플로를 이 머신에서 실행한다.
#
#   사용법:  scripts/40-setup-runner.sh          설치·등록 후 실행
#            scripts/40-setup-runner.sh status   상태 확인
#            scripts/40-setup-runner.sh stop     중지
#            scripts/40-setup-runner.sh remove   등록 해제 및 삭제
#
# GitHub 호스티드 러너를 쓸 수 없는 이유:
# 인터넷 밖에 있어 로컬 Harbor(harbor.localtest.me)와 kind 클러스터에 닿지 않는다.
# 로컬 러너는 무료이고 실행 시간 제한도 없으며, 폐쇄망(Phase 6)에서는 어차피 이 형태가 된다.
set -euo pipefail

APP_REPO="sunm2n/net8_Microservices"
RUNNER_DIR="${HOME}/actions-runner-erp-poc"
RUNNER_NAME="erp-poc-local"
RUNNER_LABELS="self-hosted,macos,arm64,erp-poc"
RUNNER_VERSION="2.336.0"

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[0;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

runner_pid() { pgrep -f "${RUNNER_DIR}/bin/Runner.Listener" 2>/dev/null | head -1 || true; }

case "${1:-setup}" in
  status)
    PID="$(runner_pid)"
    if [[ -n "${PID}" ]]; then
      ok "러너 실행 중 (pid ${PID})"
    else
      warn "러너가 실행되고 있지 않다"
    fi
    gh api "repos/${APP_REPO}/actions/runners" --jq \
      '.runners[] | "  \(.name)  \(.status)  labels=\([.labels[].name] | join(","))"' 2>/dev/null \
      || warn "GitHub 쪽 러너 목록을 조회하지 못했다"
    exit 0
    ;;

  stop)
    PID="$(runner_pid)"
    [[ -n "${PID}" ]] || { ok "이미 중지 상태"; exit 0; }
    kill "${PID}" 2>/dev/null || true
    sleep 2
    ok "러너 중지 (pid ${PID})"
    exit 0
    ;;

  remove)
    PID="$(runner_pid)"
    [[ -n "${PID}" ]] && { kill "${PID}" 2>/dev/null || true; sleep 2; }
    if [[ -d "${RUNNER_DIR}" ]]; then
      TOKEN="$(gh api -X POST "repos/${APP_REPO}/actions/runners/remove-token" --jq '.token' 2>/dev/null || true)"
      [[ -n "${TOKEN}" ]] && (cd "${RUNNER_DIR}" && ./config.sh remove --token "${TOKEN}" >/dev/null 2>&1 || true)
      rm -rf "${RUNNER_DIR}"
      ok "등록 해제 및 삭제 완료"
    else
      ok "설치되어 있지 않다"
    fi
    exit 0
    ;;

  setup) ;;
  *) die "알 수 없는 명령: ${1}" ;;
esac

# ── 사전 점검 ────────────────────────────────────────────────────
log "사전 점검"

command -v gh >/dev/null 2>&1 || die "gh 가 필요하다.  brew install gh"
gh auth status >/dev/null 2>&1 || die "gh 인증이 필요하다.  gh auth login"
ok "gh 인증 확인"

[[ "$(uname -m)" == "arm64" ]] || warn "arm64 가 아니다. RUNNER_ARCH 를 확인할 것"

if [[ -n "$(runner_pid)" ]]; then
  ok "러너가 이미 실행 중이다 — 할 일 없음"
  exit 0
fi

# ── 다운로드 ─────────────────────────────────────────────────────
if [[ ! -f "${RUNNER_DIR}/config.sh" ]]; then
  log "러너 ${RUNNER_VERSION} 내려받기"
  mkdir -p "${RUNNER_DIR}"
  TARBALL="actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
  curl -sSL -o "${RUNNER_DIR}/${TARBALL}" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}" \
    || die "다운로드 실패"
  tar xzf "${RUNNER_DIR}/${TARBALL}" -C "${RUNNER_DIR}"
  rm -f "${RUNNER_DIR}/${TARBALL}"
  ok "${RUNNER_DIR}"
else
  ok "이미 내려받음 — 건너뜀"
fi

# ── 등록 ─────────────────────────────────────────────────────────
if [[ ! -f "${RUNNER_DIR}/.runner" ]]; then
  log "저장소에 등록  ${APP_REPO}"

  # 등록 토큰은 1시간 유효하며 gh 인증으로 발급한다.
  # 사용자 자격증명을 따로 다루지 않는다.
  TOKEN="$(gh api -X POST "repos/${APP_REPO}/actions/runners/registration-token" --jq '.token' 2>/dev/null)" \
    || die "등록 토큰을 발급하지 못했다. 저장소 권한을 확인할 것."

  (cd "${RUNNER_DIR}" && ./config.sh \
    --unattended \
    --url "https://github.com/${APP_REPO}" \
    --token "${TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}" \
    --work _work \
    --replace >/dev/null) || die "등록 실패"
  ok "${RUNNER_NAME}  labels=${RUNNER_LABELS}"
else
  ok "이미 등록됨 — 건너뜀"
fi

# ── 실행 ─────────────────────────────────────────────────────────
# launchd 서비스(svc.sh) 대신 백그라운드 프로세스로 둔다.
# PoC 범위에서 재부팅 후 자동 시작이 필요하지 않고,
# 서비스 등록은 권한 요구가 따라와 재현이 번거롭다.
log "러너 실행"

LOG_FILE="${RUNNER_DIR}/runner.log"
nohup "${RUNNER_DIR}/run.sh" >"${LOG_FILE}" 2>&1 &
sleep 8

PID="$(runner_pid)"
[[ -n "${PID}" ]] || die "러너가 뜨지 않았다. 로그를 확인할 것: ${LOG_FILE}"
ok "실행 중 (pid ${PID})"

log "GitHub 쪽 상태"
gh api "repos/${APP_REPO}/actions/runners" --jq \
  '.runners[] | "  \(.name)  \(.status)"' 2>/dev/null || warn "조회 실패"

cat <<EOF

$(printf '\033[1;32m러너 준비 완료\033[0m')

  로그     ${LOG_FILE}
  상태     scripts/40-setup-runner.sh status
  중지     scripts/40-setup-runner.sh stop

EOF
