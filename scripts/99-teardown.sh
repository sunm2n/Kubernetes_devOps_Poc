#!/usr/bin/env bash
#
# Phase 0 — 클러스터 삭제
#
# kind 클러스터를 노드 컨테이너째 제거한다.
# 클러스터 안의 자원은 모두 사라지므로, 남길 것이 있으면 먼저 백업할 것.
#
#   사용법:  scripts/99-teardown.sh [-y]
#     -y     확인 절차 생략
set -euo pipefail

CLUSTER_NAME="erp-poc"
ASSUME_YES="false"

[[ "${1:-}" == "-y" ]] && ASSUME_YES="true"

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "클러스터 '${CLUSTER_NAME}' 가 존재하지 않는다. 할 일 없음."
  exit 0
fi

if [[ "${ASSUME_YES}" != "true" ]]; then
  printf '\033[0;33m클러스터 '\''%s'\'' 를 삭제한다. 내부 자원은 모두 사라진다.\033[0m\n' "${CLUSTER_NAME}"
  read -r -p "계속하려면 y 입력: " reply
  [[ "${reply}" == "y" ]] || { echo "취소했다."; exit 0; }
fi

kind delete cluster --name "${CLUSTER_NAME}"
echo "삭제 완료."
