#!/usr/bin/env bash
#
# Phase 7 — 완료 조건 검증
#
# 이슈 #24 의 완료 조건을 확인한다.
#
# 이 스크립트의 대부분은 **실패를 확인한다.**
# 파드가 떴다는 것은 격리와 아무 관계가 없다. 넘어가려는 시도가 막혀야
# 나뉘었다고 말할 수 있다. 그래서 검증마다 경계를 실제로 넘어보고,
# 넘어가지면 FAIL 이다.
#
#   사용법:  scripts/71-verify-isolation.sh
#            scripts/71-verify-isolation.sh --skip-hq   본사 재검증 생략
set -euo pipefail

CLUSTER_NAME="erp-poc"
HARBOR_HOST="harbor.localtest.me"
HARBOR_ADMIN="admin"
HARBOR_PW="Harbor12345"
INGRESS_NODE="${CLUSTER_NAME}-worker"
SKOPEO_IMAGE="quay.io/skopeo/stable:v1.19.0"

A="partner-a"
B="partner-b"
EXPECTED_PODS=11

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "${REPO_ROOT}" == /* ]] \
  || REPO_ROOT="$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd)")"

PASS=0
FAIL=0

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
pass() { printf '  \033[0;32m✓ PASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[0;31m✗ FAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '          %s\n' "$*"; }

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 \
  || { echo "클러스터 kind-${CLUSTER_NAME} 가 없다." >&2; exit 1; }

INGRESS_IP="$(docker inspect "${INGRESS_NODE}" \
  --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' 2>/dev/null || true)"

IMAGE_TAG="$(grep -E '^\s+imageTag:' "${REPO_ROOT}/envs/dev/values.yaml" | head -1 | awk '{print $2}')"

# ── 조건 1. 파트너 스택이 각자의 레지스트리에서 떴는가 ───────────
log "조건 1 — 파트너 스택 기동과 이미지 출처"

for p in "${A}" "${B}"; do
  READY="$(kubectl get pods -n "${p}" --no-headers 2>/dev/null \
    | awk '{split($2,a,"/"); if (a[1]==a[2] && a[1]>0 && $3=="Running") c++} END {print c+0}')"
  TOTAL="$(kubectl get pods -n "${p}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"

  if [[ "${READY}" == "${EXPECTED_PODS}" && "${TOTAL}" == "${EXPECTED_PODS}" ]]; then
    pass "${p} — 파드 ${EXPECTED_PODS}개 Running·Ready"
  else
    fail "${p} — Ready ${READY} / 전체 ${TOTAL} (기대 ${EXPECTED_PODS})"
    kubectl get pods -n "${p}" --no-headers 2>/dev/null \
      | awk '{split($2,a,"/"); if (a[1]!=a[2] || $3!="Running") print}' | sed 's/^/          /'
  fi

  # 애플리케이션 이미지가 자기 프로젝트에서 왔는지 본다.
  # 인프라(postgres 등)는 공개 이미지라 대상이 아니다.
  OTHER="$(kubectl get pods -n "${p}" \
    -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
    | grep "^${HARBOR_HOST}/" | grep -vc "^${HARBOR_HOST}/${p}/" || true)"
  MINE="$(kubectl get pods -n "${p}" \
    -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
    | grep -c "^${HARBOR_HOST}/${p}/" || true)"

  if [[ "${OTHER}" == "0" && "${MINE}" -ge 6 ]]; then
    pass "${p} — 앱 이미지 ${MINE}개 전부 ${HARBOR_HOST}/${p} 출처"
  else
    fail "${p} — 자기 프로젝트 ${MINE}개, 다른 프로젝트 ${OTHER}개"
  fi
done

# ── 조건 2. 레지스트리 격리 ──────────────────────────────────────
#
# partner-a 의 robot 계정으로 partner-b 의 이미지를 받아본다.
# 이것이 되면 프로젝트를 나눈 의미가 없다.
log "조건 2 — 레지스트리 (robot 계정이 남의 프로젝트를 받는가)"

skopeo() {
  docker run --rm --network kind --add-host "${HARBOR_HOST}:${INGRESS_IP}" \
    "${SKOPEO_IMAGE}" "$@"
}

# Secret 에서 실제로 쓰이는 자격증명을 꺼낸다.
# 별도로 만들어 시험하면 진짜 쓰이는 계정을 확인하지 못한다.
read_creds() {
  kubectl get secret "harbor-$1" -n "$1" \
    -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null \
    | HOST="${HARBOR_HOST}" python3 -c "
import json, os, sys
auths = json.load(sys.stdin)['auths'][os.environ['HOST']]
print(f\"{auths['username']}:{auths['password']}\")
" 2>/dev/null || true
}

A_CREDS="$(read_creds "${A}")"

if [[ -z "${A_CREDS}" ]]; then
  fail "${A} 의 pull secret 을 읽지 못했다"
else
  info "${A} robot ${A_CREDS%%:*}"

  # 자기 것은 받아져야 한다. 이것이 안 되면 계정이 잘못된 것이지 격리가 아니다.
  if skopeo inspect --tls-verify=false --creds "${A_CREDS}" \
       "docker://${HARBOR_HOST}/${A}/catalog-api:${IMAGE_TAG}" >/dev/null 2>&1; then
    pass "${A} robot → ${A}/catalog-api 조회 성공 (정상 경로)"
  else
    fail "${A} robot 이 자기 프로젝트도 받지 못한다"
  fi

  # 남의 것은 막혀야 한다.
  if skopeo inspect --tls-verify=false --creds "${A_CREDS}" \
       "docker://${HARBOR_HOST}/${B}/catalog-api:${IMAGE_TAG}" >/dev/null 2>&1; then
    fail "${A} robot 이 ${B}/catalog-api 를 받았다 — 레지스트리 격리 실패"
  else
    pass "${A} robot → ${B}/catalog-api 거부됨"
  fi

  # 익명으로도 막혀야 한다. private 이 아니면 robot 을 나눈 의미가 없다.
  if skopeo inspect --tls-verify=false \
       "docker://${HARBOR_HOST}/${B}/catalog-api:${IMAGE_TAG}" >/dev/null 2>&1; then
    fail "${B} 프로젝트를 익명으로 받을 수 있다 — private 이 아니다"
  else
    pass "익명 → ${B}/catalog-api 거부됨"
  fi
fi

# ── 조건 3. 네트워크 격리 ────────────────────────────────────────
#
# partner-a 의 파드에서 partner-b 의 서비스를 불러본다.
log "조건 3 — 네트워크 (파트너끼리 통신되는가)"

NP_COUNT="$(kubectl get networkpolicy -n "${A}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${NP_COUNT}" -ge 4 ]]; then
  pass "${A} — NetworkPolicy ${NP_COUNT}개 적용"
else
  fail "${A} — NetworkPolicy ${NP_COUNT}개 (기대 4개 이상)"
fi

# 검증용 파드를 파트너 A 네임스페이스에 띄운다.
#
# busybox 를 쓴다. 애플리케이션 이미지(mcr.microsoft.com/dotnet/aspnet 계열)에는
# curl · wget · nc 가 없다. 그것으로 시험하면 명령이 없어서 실패한 것을
# 네트워크가 막힌 것으로 읽게 되고, 정책이 하나도 걸려 있지 않아도
# "차단됨" 이 나온다. 실제로 처음에 그렇게 통과했다.
#
# 차단을 확인하는 검증은 같은 방법으로 "열려야 하는 것" 도 함께 봐야 한다.
# 아래의 같은 네임스페이스 호출이 그 대조군이다.
PROBE="isolation-probe"
kubectl delete pod "${PROBE}" -n "${A}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl run "${PROBE}" -n "${A}" --image=busybox:1.37 \
  --command -- sleep 900 >/dev/null 2>&1 || true

if kubectl wait --for=condition=Ready "pod/${PROBE}" -n "${A}" --timeout=150s >/dev/null 2>&1; then
  # 대조군. 같은 네임스페이스 안은 통해야 한다.
  # 이것까지 막히면 정책이 과해서 애플리케이션이 못 도는 것이고,
  # 아래의 "차단됨" 들도 믿을 수 없게 된다.
  if kubectl exec "${PROBE}" -n "${A}" -- timeout 8 nc -z -w3 catalog-api 8080 >/dev/null 2>&1; then
    pass "${A} 안에서 catalog-api 연결 성공 (대조군 — 같은 테넌트 통신 정상)"
  else
    fail "${A} 안에서 catalog-api 에 닿지 못한다 — 정책이 과하다"
  fi

  # 다른 파트너는 막혀야 한다.
  if kubectl exec "${PROBE}" -n "${A}" -- timeout 8 \
       nc -z -w3 "catalog-api.${B}.svc.cluster.local" 8080 >/dev/null 2>&1; then
    fail "${A} 파드가 ${B} 의 catalog-api 에 연결했다 — 네트워크 격리 실패"
  else
    pass "${A} → ${B}/catalog-api 차단됨"
  fi

  # 본사도 막혀야 한다.
  # 파트너끼리만 막고 본사는 열어두면, 파트너가 본사 DB 에 닿는 경로가 남는다.
  if kubectl exec "${PROBE}" -n "${A}" -- timeout 8 \
       nc -z -w3 catalog-api.eshop.svc.cluster.local 8080 >/dev/null 2>&1; then
    fail "${A} 파드가 본사 catalog-api 에 연결했다"
  else
    pass "${A} → 본사(eshop)/catalog-api 차단됨"
  fi

  # 이름 해석은 되지만 연결이 안 되는 것이 정상이다.
  # 해석 자체가 안 되면 차단의 원인이 네트워크 정책인지 DNS 인지 구분할 수 없다.
  if kubectl exec "${PROBE}" -n "${A}" -- timeout 8 \
       nslookup "catalog-api.${B}.svc.cluster.local" 2>/dev/null | grep -q 'Address'; then
    pass "DNS 는 동작 (차단 지점이 네트워크 정책이지 이름 해석이 아니다)"
  else
    fail "DNS 해석이 안 된다 — tenant-allow-dns 정책을 확인할 것"
  fi
else
  fail "검증용 파드를 띄우지 못했다"
  kubectl describe pod "${PROBE}" -n "${A}" 2>/dev/null | grep -A3 Events | sed 's/^/          /' || true
fi

kubectl delete pod "${PROBE}" -n "${A}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

# ── 조건 4. RBAC ─────────────────────────────────────────────────
log "조건 4 — 권한 (파트너 계정이 남의 네임스페이스를 보는가)"

SA_A="system:serviceaccount:${A}:tenant-${A}"

if kubectl auth can-i get pods --as="${SA_A}" -n "${A}" 2>/dev/null | grep -qx yes; then
  pass "${A} 계정 → 자기 네임스페이스 조회 가능"
else
  fail "${A} 계정이 자기 네임스페이스도 못 본다"
fi

if kubectl auth can-i get pods --as="${SA_A}" -n "${B}" 2>/dev/null | grep -qx yes; then
  fail "${A} 계정이 ${B} 네임스페이스를 조회할 수 있다 — RBAC 격리 실패"
else
  pass "${A} 계정 → ${B} 네임스페이스 조회 거부됨"
fi

# Secret 은 자기 네임스페이스에서도 막아뒀다.
# pull secret 을 읽으면 그 자격증명으로 레지스트리에 직접 붙을 수 있다.
if kubectl auth can-i get secrets --as="${SA_A}" -n "${A}" 2>/dev/null | grep -qx yes; then
  fail "${A} 계정이 자기 네임스페이스의 Secret 을 읽을 수 있다"
else
  pass "${A} 계정 → Secret 읽기 거부됨 (자기 네임스페이스에서도)"
fi

if kubectl auth can-i delete namespace --as="${SA_A}" 2>/dev/null | grep -qx yes; then
  fail "${A} 계정이 네임스페이스를 지울 수 있다"
else
  pass "${A} 계정 → 클러스터 범위 작업 거부됨"
fi

# ── 조건 5. AppProject ───────────────────────────────────────────
#
# 파트너 A 의 프로젝트로 파트너 B 네임스페이스에 배포를 시도한다.
# 매니페스트를 고칠 수 있는 사람이 어디까지 갈 수 있는지를 보는 것이다.
log "조건 5 — GitOps (파트너 프로젝트가 남의 네임스페이스에 배포하는가)"

DEST="$(kubectl get appproject "${A}" -n argocd \
  -o jsonpath='{.spec.destinations[*].namespace}' 2>/dev/null || true)"
if [[ "${DEST}" == "${A}" ]]; then
  pass "AppProject ${A} — 배포 가능 네임스페이스가 ${A} 뿐"
else
  fail "AppProject ${A} 의 destinations 가 '${DEST}'"
fi

CLUSTER_RES="$(kubectl get appproject "${A}" -n argocd \
  -o jsonpath='{.spec.clusterResourceWhitelist}' 2>/dev/null || true)"
if [[ -z "${CLUSTER_RES}" || "${CLUSTER_RES}" == "[]" ]]; then
  pass "AppProject ${A} — 클러스터 범위 자원 생성 금지"
else
  fail "AppProject ${A} 가 클러스터 자원을 허용한다: ${CLUSTER_RES}"
fi

# 실제로 넘어가 본다.
PROBE_APP="isolation-probe-app"
kubectl delete application "${PROBE_APP}" -n argocd --ignore-not-found --wait=true >/dev/null 2>&1 || true
# 파트너 A 의 정상 Application 과 같은 형태로 만들되 목적지만 B 로 바꾼다.
# 다른 곳을 틀리게 적으면 AppProject 가 아니라 그것 때문에 실패할 수 있고,
# 그러면 막혔다는 결론이 엉뚱한 근거를 갖게 된다.
cat <<EOF | kubectl apply -f - >/dev/null 2>&1 || true
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${PROBE_APP}
  namespace: argocd
spec:
  project: ${A}
  sources:
    - repoURL: https://github.com/sunm2n/Kubernetes_devOps_Poc.git
      targetRevision: dev
      path: charts/eshop
      helm:
        valueFiles:
          - \$values/envs/${B}/values.yaml
    - repoURL: https://github.com/sunm2n/Kubernetes_devOps_Poc.git
      targetRevision: dev
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: ${B}
  syncPolicy:
    automated: {}
EOF

# ArgoCD 는 이렇게 답한다.
#
#   InvalidSpecError: application destination server '...' and namespace 'partner-b'
#   do not match any of the allowed destinations in project 'partner-a'
#
# 목적지 검증은 저장소를 읽기 전에 일어난다. 그래서 리비전이나 경로가
# 무엇이든 이 오류가 먼저 나온다.
VIOLATION=""
for _ in $(seq 1 20); do
  COND="$(kubectl get application "${PROBE_APP}" -n argocd \
    -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' 2>/dev/null || true)"
  if echo "${COND}" | grep -qiE 'do not match any of the allowed destinations|not permitted in project'; then
    VIOLATION="${COND}"
    break
  fi
  sleep 2
done

if [[ -n "${VIOLATION}" ]]; then
  pass "${A} 프로젝트로 ${B} 배포 시도 → ArgoCD 거부"
  echo "${VIOLATION}" | head -1 | sed 's/^/            /'
else
  # 거부 메시지가 없더라도 실제로 배포되지 않았으면 막힌 것이다.
  LEAKED="$(kubectl get all -n "${B}" -l app.kubernetes.io/instance="${PROBE_APP}" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${LEAKED}" == "0" ]]; then
    pass "${A} 프로젝트로 ${B} 에 배포되지 않음"
    info "거부 조건 메시지는 확인하지 못했다"
  else
    fail "${A} 프로젝트가 ${B} 에 자원 ${LEAKED}개를 만들었다 — AppProject 격리 실패"
  fi
fi

kubectl delete application "${PROBE_APP}" -n argocd --ignore-not-found --wait=false >/dev/null 2>&1 || true

# ── 조건 6. 본사 영향 없음 ───────────────────────────────────────
log "조건 6 — 본사(eshop)"

if [[ "${1:-}" == "--skip-hq" ]]; then
  info "생략됨 (--skip-hq)"
elif "${REPO_ROOT}/scripts/12-verify-eshop.sh" >/tmp/phase7-hq.log 2>&1; then
  pass "본사 검증 재통과 — 파트너 구성이 본사에 영향 없음"
else
  fail "본사 검증 실패 — /tmp/phase7-hq.log 확인"
  grep -E "FAIL" /tmp/phase7-hq.log | sed 's/^/          /' || true
fi

# ── 자원 사용량 ──────────────────────────────────────────────────
log "자원 사용량 (참고)"

docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}' 2>/dev/null \
  | grep -E "erp-poc" | sed 's/^/          /' || true

for ns in eshop "${A}" "${B}"; do
  N="$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  info "${ns} 파드 ${N}개"
done

# ── 결과 ─────────────────────────────────────────────────────────
printf '\n────────────────────────────────────\n'
printf '  통과 %d · 실패 %d\n' "${PASS}" "${FAIL}"
printf '────────────────────────────────────\n\n'

[[ "${FAIL}" -eq 0 ]] || exit 1
