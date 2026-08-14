#!/usr/bin/env bash
#
# Phase 6a — 폐쇄망 반입
#
# 번들 하나만 가지고 폐쇄망에 플랫폼을 세운다.
# 이 스크립트가 끝나면 망 안에 Git 서버·레지스트리·GitOps 가 모두 선다.
#
#   사용법:  scripts/62-import-bundle.sh
#            scripts/62-import-bundle.sh verify-only   번들 무결성만 확인
#
# ── 닭과 달걀 ────────────────────────────────────────────────────
#
# Harbor 를 폐쇄망에 올리려면 Harbor 이미지가 먼저 노드에 있어야 하는데
# 그 이미지를 받을 레지스트리가 아직 없다.
# 그래서 반입은 두 단계다.
#
#   1단계  kind load  — 레지스트리 없이 노드 containerd 에 직접 밀어 넣는다.
#                       ingress-nginx 와 Harbor 자신만 이렇게 들어간다.
#   2단계  skopeo     — Harbor 가 선 뒤 나머지를 정상 경로로 올린다.
#
# 실제 폐쇄망도 같다. 첫 레지스트리는 tar 로 서버에 직접 올리고,
# 그 다음부터 레지스트리를 쓴다.
#
# ── 모든 작업은 점프 호스트에서 한다 ──────────────────────────────
#
# 호스트(맥)는 인터넷에 연결돼 있다. 여기서 helm 이나 skopeo 를 돌리면
# "정말 반입물만으로 됐는가" 를 증명하지 못한다.
#
# 그래서 폐쇄망 네트워크에 도구 컨테이너를 하나 띄우고 기본 경로를 끊는다.
# 그 안에서 실행되는 것은 인터넷에 나갈 수 없다.
# 아키텍처 문서 16p 의 Jump Host 와 같은 역할이다.
set -euo pipefail

CLUSTER_NAME="erp-airgap"
NETWORK="erp-airgap-net"
INGRESS_NODE="${CLUSTER_NAME}-worker"

JUMP="airgap-jump"
GITLAB="airgap-gitlab"

HARBOR_HOST="harbor.airgap"
GITLAB_HOST="gitlab.airgap"
ARGOCD_HOST="argocd.airgap"

HARBOR_PW="Harbor12345"
GITLAB_ROOT_PW="AirgapPoC12345!"
GITLAB_TOKEN="airgap-poc-token-000001"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 번들 경로를 점프 호스트에 마운트한다. docker -v 는 절대 경로만 받는다.
# 상대 경로를 주면 그것을 볼륨 "이름" 으로 해석해, 번들 대신 빈 볼륨이 붙는다.
# 셸에 따라 pwd 가 상대 경로를 돌려주는 경우가 있어 한 번 더 확인한다.
[[ "${REPO_ROOT}" == /* ]] \
  || REPO_ROOT="$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd)")"

BUNDLE="${REPO_ROOT}/.bundle"

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[0;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
step() { printf '    %s\n' "$*"; }

jump()  { docker exec "${JUMP}" "$@"; }
jumpsh() { docker exec -i "${JUMP}" sh -c "$1"; }

# ── 0. 번들 무결성 ───────────────────────────────────────────────
#
# 망을 넘어온 파일이 넘어오기 전과 같은지 확인한다.
# 이 확인 없이는 반입 절차라고 부를 수 없다.
verify_bundle() {
  log "번들 무결성"

  [[ -d "${BUNDLE}" ]] || die "번들이 없다: ${BUNDLE}
  scripts/61-export-bundle.sh 를 먼저 실행할 것."
  [[ -f "${BUNDLE}/MANIFEST.txt" ]] || die "MANIFEST.txt 가 없다."

  local bad=0 checked=0
  while read -r want _size _unit path; do
    [[ -n "${path}" ]] || continue
    local full="${BUNDLE}/${path}"
    [[ -f "${full}" ]] || { warn "없음: ${path}"; bad=$((bad + 1)); continue; }
    local got
    got="$(shasum -a 256 "${full}" | awk '{print $1}')"
    if [[ "${got}" != "${want}" ]]; then
      warn "해시 불일치: ${path}"
      bad=$((bad + 1))
    fi
    checked=$((checked + 1))
  done < <(sed -n '/^## 파일$/,/^$/p' "${BUNDLE}/MANIFEST.txt" | grep -E '^[0-9a-f]{64} ')

  [[ "${bad}" -eq 0 ]] || die "번들이 손상됐다. 불일치 ${bad}건."
  ok "파일 ${checked}개 sha256 일치"

  # OCI blob 은 파일 이름이 곧 내용의 sha256 이다.
  # 목록과 실제가 같은지만 보면 된다.
  local listed present
  listed="$(sed -n '/^## OCI blob/,$p' "${BUNDLE}/MANIFEST.txt" | grep -cE '^[0-9a-f]{64}$' || true)"
  present="$(find "${BUNDLE}/images/payload/blobs" -type f 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${listed}" == "${present}" ]] || die "OCI blob 수가 다르다 (명세 ${listed}, 실제 ${present})."
  ok "OCI blob ${present}개 일치"

  ok "번들 크기 $(du -sh "${BUNDLE}" | awk '{print $1}')"
}

if [[ "${1:-}" == "verify-only" ]]; then
  verify_bundle
  exit 0
fi

command -v kind >/dev/null 2>&1 || die "kind 가 필요하다."
kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}" \
  || die "폐쇄망 클러스터가 없다. scripts/60-create-airgap-cluster.sh 를 먼저 실행할 것."

verify_bundle

# ── 1. 격리 확인 ─────────────────────────────────────────────────
#
# 막히지 않은 상태에서 성공하면 아무것도 증명하지 못한다.
# 반입을 시작하기 전에 먼저 이것부터 본다.
log "격리 상태 확인"

for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  if docker exec "${node}" timeout 8 curl -sf -o /dev/null https://www.google.com >/dev/null 2>&1; then
    die "${node} 가 외부에 닿는다. scripts/60-create-airgap-cluster.sh isolate 로 다시 끊을 것."
  fi
done
ok "클러스터 노드 전부 외부 접근 불가"

INGRESS_IP="$(docker inspect "${INGRESS_NODE}" \
  --format "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}")"
ok "Ingress 노드 ${INGRESS_NODE} → ${INGRESS_IP}"

# ── 2. GitLab CE ─────────────────────────────────────────────────
#
# 클러스터 밖 컨테이너로 띄운다.
#
# 폐쇄망 클러스터에 넣지 않는 이유:
#   - GitLab omnibus 는 한 컨테이너 안에 Postgres·Redis·Gitaly·Puma·Sidekiq 을
#     전부 담고 있어 Kubernetes 의 자원 관리와 잘 맞지 않는다.
#     GitLab 자신도 운영 환경에서는 별도 노드를 권한다.
#   - 3GB 대 이미지를 kind load 로 두 노드에 밀어 넣지 않아도 된다.
#   - 실제 폐쇄망에서도 Git 서버는 보통 별도 VM 이다.
#
# 이 컨테이너도 기본 경로를 끊어 망 안에 둔다.
log "GitLab CE"

if docker inspect "${GITLAB}" >/dev/null 2>&1; then
  docker start "${GITLAB}" >/dev/null 2>&1 || true
  ok "이미 존재 — 기동 확인"
else
  docker load -q -i "${BUNDLE}/images/gitlab.tar" >/dev/null
  GITLAB_IMAGE="$(cat "${BUNDLE}/images/gitlab.txt")"
  ok "이미지 반입 ${GITLAB_IMAGE}"

  # PoC 에 필요 없는 구성요소를 끈다. 기본값으로 두면 메모리가 4GB 를 넘는다.
  # NET_ADMIN 이 필요하다.
  #
  # 컨테이너는 기본적으로 자기 라우팅 테이블도 고치지 못한다.
  # 이 권한이 없으면 아래의 ip route del 이 조용히 실패하고
  # (RTNETLINK answers: Operation not permitted) 격리되지 않은 채로 넘어간다.
  # kind 노드는 privileged 로 돌아 이 문제가 없었다.
  docker run -d --name "${GITLAB}" \
    --network "${NETWORK}" \
    --hostname "${GITLAB_HOST}" \
    --cap-add NET_ADMIN \
    --shm-size 256m \
    -e GITLAB_OMNIBUS_CONFIG="external_url 'http://${GITLAB_HOST}'; \
gitlab_rails['initial_root_password']='${GITLAB_ROOT_PW}'; \
prometheus_monitoring['enable']=false; \
registry['enable']=false; \
gitlab_kas['enable']=false; \
puma['worker_processes']=2; \
sidekiq['max_concurrency']=5;" \
    "${GITLAB_IMAGE}" >/dev/null
  ok "컨테이너 기동"
fi

docker exec "${GITLAB}" ip route del default >/dev/null 2>&1 || true
if docker exec "${GITLAB}" timeout 8 curl -sf -o /dev/null https://www.google.com >/dev/null 2>&1; then
  die "GitLab 컨테이너가 외부에 닿는다."
fi
ok "외부 접근 불가"

GITLAB_IP="$(docker inspect "${GITLAB}" \
  --format "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}")"
ok "${GITLAB_HOST} → ${GITLAB_IP}"

# ── 3. 점프 호스트 ───────────────────────────────────────────────
log "점프 호스트"

docker rm -f "${JUMP}" >/dev/null 2>&1 || true
docker load -q -i "${BUNDLE}/images/jump.tar" >/dev/null
JUMP_IMAGE="$(cat "${BUNDLE}/images/jump.txt")"

docker run -d --name "${JUMP}" \
  --network "${NETWORK}" \
  --cap-add NET_ADMIN \
  --add-host "${HARBOR_HOST}:${INGRESS_IP}" \
  --add-host "${GITLAB_HOST}:${GITLAB_IP}" \
  --add-host "${ARGOCD_HOST}:${INGRESS_IP}" \
  --add-host "eshop.airgap:${INGRESS_IP}" \
  --add-host "api.eshop.airgap:${INGRESS_IP}" \
  -v "${BUNDLE}:/bundle:ro" \
  "${JUMP_IMAGE}" >/dev/null

docker exec "${JUMP}" ip route del default >/dev/null 2>&1 || true
if jump timeout 8 curl -sf -o /dev/null https://www.google.com >/dev/null 2>&1; then
  die "점프 호스트가 외부에 닿는다. 여기서 하는 작업이 반입물만으로 이뤄졌다고 볼 수 없다."
fi
ok "기동 · 외부 접근 불가 · 번들 마운트(/bundle, 읽기 전용)"

# kubeconfig 는 --internal 로 뽑는다.
# 기본값은 127.0.0.1:<호스트포트> 를 가리키는데, 그 주소는 호스트에서만 통한다.
# --internal 은 제어 평면 컨테이너의 IP 를 쓴다.
kind get kubeconfig --internal --name "${CLUSTER_NAME}" \
  | docker exec -i "${JUMP}" sh -c 'mkdir -p /root/.kube && cat > /root/.kube/config'
jump kubectl get nodes >/dev/null 2>&1 || die "점프 호스트에서 API 서버에 닿지 못한다."
ok "kubectl 연결 확인 — 노드 $(jump kubectl get nodes --no-headers | wc -l | tr -d ' ')대"

# ── 4. 부트스트랩 이미지 ─────────────────────────────────────────
log "부트스트랩 이미지 — 레지스트리 없이 노드에 직접"

BOOT_COUNT="$(grep -c '' "${BUNDLE}/images/bootstrap.txt")"

# 아카이브가 플랫폼별로 나뉘어 있다.
# Harbor 는 amd64 만 내고 ingress-nginx 는 arm64 가 있어 한 파일에 담기지 않는다.
# 자세한 이유는 scripts/61-export-bundle.sh 의 주석 참고.
for archive in "${BUNDLE}"/images/bootstrap-*.tar; do
  [[ -f "${archive}" ]] || die "부트스트랩 아카이브가 없다. scripts/61-export-bundle.sh 를 먼저 실행할 것."
  kind load image-archive "${archive}" --name "${CLUSTER_NAME}" >/dev/null 2>&1 \
    || die "kind load 실패: $(basename "${archive}")"
  ok "$(basename "${archive}")"
done
ok "${BOOT_COUNT}개 반입 (ingress-nginx · Harbor)"

# 정말 노드에 들어갔는지 본다. kind load 는 조용히 일부만 넣는 경우가 있다.
LOADED="$(docker exec "${INGRESS_NODE}" crictl images 2>/dev/null | grep -cE 'ingress-nginx|goharbor' || true)"
[[ "${LOADED}" -ge "${BOOT_COUNT}" ]] || warn "노드에서 확인된 이미지 ${LOADED}개 (기대 ${BOOT_COUNT})"
ok "노드 containerd 에서 ${LOADED}개 확인"

# ── 5. 노드 레지스트리 신뢰 설정 ─────────────────────────────────
#
# Phase 3 개발계와 같은 문제를 여기서도 푼다.
#   - .airgap 은 어떤 DNS 에도 없다 → /etc/hosts
#   - Harbor 가 평문 HTTP 다 → containerd certs.d
#
# 개발계와 다른 점은 이름이 공개 DNS 에 의존하지 않는다는 것이다.
# localtest.me 를 썼다면 폐쇄망에서 해석 자체가 안 된다.
log "노드 레지스트리 설정"

for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" sh -c \
    "grep -q ' ${HARBOR_HOST}\$' /etc/hosts || echo '${INGRESS_IP} ${HARBOR_HOST}' >> /etc/hosts"
  docker exec "${node}" sh -c \
    "grep -q ' ${GITLAB_HOST}\$' /etc/hosts || echo '${GITLAB_IP} ${GITLAB_HOST}' >> /etc/hosts"

  docker exec "${node}" mkdir -p "/etc/containerd/certs.d/${HARBOR_HOST}"
  docker exec -i "${node}" sh -c "cat > /etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml" <<EOF
server = "http://${HARBOR_HOST}"

[host."http://${HARBOR_HOST}"]
  capabilities = ["pull", "resolve"]
EOF
  ok "${node}"
done

# ── 6. ingress-nginx ─────────────────────────────────────────────
log "ingress-nginx"

jump helm upgrade --install ingress-nginx \
  "/bundle/charts/ingress-nginx-4.15.1.tgz" \
  --namespace ingress-nginx --create-namespace \
  --values /bundle/values/ingress-nginx-values.yaml \
  --wait --timeout 10m >/dev/null || die "ingress-nginx 설치 실패."
ok "설치 완료 (번들의 차트로)"

# ── 7. Harbor ────────────────────────────────────────────────────
log "Harbor"

jump helm upgrade --install harbor \
  "/bundle/charts/harbor-1.19.2.tgz" \
  --namespace harbor --create-namespace \
  --values /bundle/values/harbor-values.yaml \
  --wait --timeout 20m >/dev/null || die "Harbor 설치 실패."
ok "설치 완료"

for i in $(seq 1 90); do
  if jump curl -sf -o /dev/null --max-time 5 "http://${HARBOR_HOST}/api/v2.0/systeminfo" 2>/dev/null; then
    break
  fi
  printf '\r    API 대기 %3ds' "$((i * 5))"
  sleep 5
done
echo
jump curl -sf -o /dev/null --max-time 5 "http://${HARBOR_HOST}/api/v2.0/systeminfo" \
  || die "Harbor API 가 응답하지 않는다."
ok "API 응답 — 폐쇄망 레지스트리 가동"

# 프로젝트 두 개.
#   erp-hq    반입한 우리 빌드 결과물
#   platform  반입한 외부 이미지
for project in erp-hq platform; do
  CODE="$(jump curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -u "admin:${HARBOR_PW}" -H 'Content-Type: application/json' \
    -X POST "http://${HARBOR_HOST}/api/v2.0/projects" \
    -d "{\"project_name\":\"${project}\",\"public\":true,\"metadata\":{\"public\":\"true\"}}" || true)"
  case "${CODE}" in
    201) ok "프로젝트 ${project}" ;;
    409) ok "프로젝트 ${project} (이미 존재)" ;;
    *)   die "프로젝트 ${project} 생성 실패 HTTP ${CODE}" ;;
  esac
done

# ── 8. 페이로드 이미지 ───────────────────────────────────────────
#
# 여기부터는 정상 경로다. 점프 호스트가 번들에서 읽어 Harbor 에 올린다.
log "페이로드 이미지 → ${HARBOR_HOST}"

PUSHED=0
while IFS='|' read -r name dest; do
  [[ -n "${name}" ]] || continue
  jump skopeo copy --quiet \
    --dest-tls-verify=false \
    --dest-creds "admin:${HARBOR_PW}" \
    "oci:/bundle/images/payload:${name}" \
    "docker://${HARBOR_HOST}/${dest}" >/dev/null 2>&1 \
    || die "푸시 실패: ${dest}"
  PUSHED=$((PUSHED + 1))
  ok "${dest}"
done < "${BUNDLE}/images/payload.txt"

ok "${PUSHED}개 반입 완료"

# ── 9. 클러스터 DNS ──────────────────────────────────────────────
#
# 노드의 /etc/hosts 는 containerd 가 이미지를 받을 때만 쓰인다.
# 파드 안에서의 이름 해석은 CoreDNS 가 맡는다.
#
# ArgoCD repo-server 가 gitlab.airgap 을 찾지 못하면 동기화가 시작되지 않는다.
# 이것을 빠뜨리면 이미지는 다 들어왔는데 GitOps 만 안 도는 상태가 된다.
log "클러스터 DNS — .airgap 이름 등록"

# Corefile 을 통째로 새로 쓰지 않는다.
#
# kind 가 만든 내용에는 이 클러스터에 필요한 설정이 들어 있고,
# 버전에 따라 조금씩 다르다. 손으로 옮겨 적으면 그 차이를 놓친다.
# 기존 내용을 읽어 hosts 블록만 끼워 넣는다.
#
# hosts 블록은 kubernetes 플러그인보다 앞에 와야 하고,
# fallthrough 가 있어야 나머지 질의가 그대로 흘러간다.
# 이것이 빠지면 클러스터 내부 이름 해석이 통째로 멈춘다.
jump kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' > /tmp/corefile.orig

HOSTS_BLOCK="    hosts {
       ${INGRESS_IP} ${HARBOR_HOST}
       ${INGRESS_IP} ${ARGOCD_HOST}
       ${INGRESS_IP} eshop.airgap
       ${INGRESS_IP} api.eshop.airgap
       ${GITLAB_IP} ${GITLAB_HOST}
       fallthrough
    }"

# 원본은 인자로 넘긴다.
# python3 - 는 스크립트를 stdin 으로 읽으므로, 같은 stdin 으로 데이터까지
# 넘길 수 없다. heredoc 이 stdin 을 차지해 데이터는 빈 문자열이 된다.
python3 - "${HOSTS_BLOCK}" /tmp/corefile.orig > /tmp/corefile.new <<'PY'
import re, sys
block = sys.argv[1]
with open(sys.argv[2]) as f:
    src = f.read()
# 이미 넣어둔 것이 있으면 걷어내고 새로 넣는다(재실행 가능해야 한다).
src = re.sub(r'\n\s*hosts \{.*?\n\s*\}', '', src, flags=re.S)
out = re.sub(r'(\n)(\s*kubernetes cluster\.local)', '\n' + block + r'\1\2', src, count=1)
if 'hosts {' not in out:
    raise SystemExit('Corefile 에 kubernetes 블록이 없어 hosts 를 넣을 위치를 찾지 못했다.')
sys.stdout.write(out)
PY

# 파일을 컨테이너 안으로 옮긴 뒤 거기서 끝낸다.
# docker exec 는 -i 없이 stdin 을 전달하지 않는다.
# 호스트에서 파이프로 밀어 넣으면 컨테이너 안에서는 빈 입력이 되어
# "no objects passed to apply" 로 조용히 실패한다.
docker exec -i "${JUMP}" sh -c 'cat > /tmp/corefile.new' < /tmp/corefile.new

jumpsh "kubectl -n kube-system create configmap coredns \
  --from-file=Corefile=/tmp/corefile.new --dry-run=client -o yaml \
  | kubectl -n kube-system apply -f -" >/dev/null
jump kubectl -n kube-system rollout restart deployment coredns >/dev/null
jump kubectl -n kube-system rollout status deployment coredns --timeout=120s >/dev/null
ok "CoreDNS 에 .airgap 5개 등록"

# ── 10. GitLab 준비 ──────────────────────────────────────────────
log "GitLab 기동 대기"

# omnibus 는 한 컨테이너에서 여러 구성요소를 순서대로 올린다. 수 분 걸린다.
#
# /-/readiness 는 컨테이너 안에서만 본다.
# 이 경로는 monitoring_whitelist(기본 127.0.0.0/8)에 있는 주소에만 답하고
# 그 밖에서는 404 를 준다. 점프 호스트에서 이것으로 판단하면
# GitLab 이 멀쩡히 떠 있어도 영원히 기다리게 된다.
for i in $(seq 1 120); do
  if docker exec "${GITLAB}" curl -sf -o /dev/null --max-time 5 \
       http://localhost/-/readiness >/dev/null 2>&1; then
    break
  fi
  printf '\r    %3ds  %s' "$((i * 5))" "$(docker inspect --format '{{.State.Health.Status}}' "${GITLAB}" 2>/dev/null || echo starting)"
  sleep 5
done
echo
docker exec "${GITLAB}" curl -sf -o /dev/null --max-time 10 http://localhost/-/readiness >/dev/null 2>&1 \
  || die "GitLab 이 준비되지 않았다. docker logs ${GITLAB} 확인."
ok "GitLab 준비 완료"

# 망 안에서 실제로 닿는지는 따로 본다.
# 위 확인은 GitLab 자신에게 물어본 것이라, 이름 해석이나 경로 문제를 잡지 못한다.
jump curl -sf -o /dev/null --max-time 10 "http://${GITLAB_HOST}/users/sign_in" \
  || die "점프 호스트에서 http://${GITLAB_HOST} 에 닿지 못한다."
ok "점프 호스트에서 접근 확인 — 폐쇄망 Git 서버 가동"

# 접근 토큰.
#
# API 로는 토큰을 만들 수 없다(토큰이 있어야 API 를 쓰니까).
# 첫 토큰은 서버 안에서 직접 만든다. 실제 폐쇄망 구축에서도 같은 순서다.
log "GitLab 초기 설정"

docker exec "${GITLAB}" gitlab-rails runner "
u = User.find_by_username('root')
u.personal_access_tokens.where(name: 'airgap-import').delete_all
t = u.personal_access_tokens.create!(name: 'airgap-import',
                                     scopes: ['api', 'write_repository'],
                                     expires_at: 300.days.from_now)
t.set_token('${GITLAB_TOKEN}')
t.save!
" >/dev/null 2>&1 || die "GitLab 토큰 생성 실패."
ok "관리자 토큰 발급"

gitlab_api() {
  jump curl -s --max-time 30 -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "$@"
}

# 그룹과 프로젝트를 public 으로 만든다.
#
# ArgoCD 가 자격증명 없이 clone 할 수 있게 하려는 것이다.
# 개발계에서 저장소를 public 으로 두고 pull secret 을 피한 것과 같은 선택이며,
# 자격증명 관리는 Phase 8(OpenBao)에서 함께 다룬다.
GROUP_ID="$(gitlab_api "http://${GITLAB_HOST}/api/v4/groups/erp" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)"

if [[ -z "${GROUP_ID}" ]]; then
  GROUP_ID="$(gitlab_api -X POST "http://${GITLAB_HOST}/api/v4/groups" \
    -H 'Content-Type: application/json' \
    -d '{"name":"erp","path":"erp","visibility":"public"}' \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)"
fi
[[ -n "${GROUP_ID}" ]] || die "그룹 erp 생성 실패."
ok "그룹 erp (id ${GROUP_ID})"

PROJECT_URL="$(gitlab_api "http://${GITLAB_HOST}/api/v4/projects/erp%2Fgitops" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('http_url_to_repo',''))" 2>/dev/null || true)"

if [[ -z "${PROJECT_URL}" ]]; then
  PROJECT_URL="$(gitlab_api -X POST "http://${GITLAB_HOST}/api/v4/projects" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"gitops\",\"path\":\"gitops\",\"namespace_id\":${GROUP_ID},\"visibility\":\"public\",\"initialize_with_readme\":false}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('http_url_to_repo',''))" 2>/dev/null || true)"
fi
[[ -n "${PROJECT_URL}" ]] || die "프로젝트 erp/gitops 생성 실패."
ok "프로젝트 erp/gitops (public — ArgoCD 가 자격증명 없이 읽는다)"

# ── 11. 저장소 반입 ──────────────────────────────────────────────
#
# git bundle 에서 복원해 폐쇄망 GitLab 에 올린다.
# 커밋 이력이 그대로 따라온다. 반입된 것이 어느 시점의 무엇인지 남는다.
log "GitOps 저장소 반입"

SRC_BRANCH="$(cat "${BUNDLE}/gitops/branch.txt")"

jumpsh "
set -e
rm -rf /tmp/gitops
git clone -q --branch '${SRC_BRANCH}' /bundle/gitops/repo.bundle /tmp/gitops
cd /tmp/gitops
git config user.email 'import@airgap.local'
git config user.name 'Airgap Import'
git branch -M main
git remote remove airgap 2>/dev/null || true
git remote add airgap 'http://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST}/erp/gitops.git'
git push -q --force airgap main
" || die "저장소 푸시 실패."

COMMITS="$(jumpsh "cd /tmp/gitops && git rev-list --count main")"
HEAD_SHA="$(jumpsh "cd /tmp/gitops && git rev-parse --short main")"
ok "http://${GITLAB_HOST}/erp/gitops  — 커밋 ${COMMITS}개, HEAD ${HEAD_SHA}"

# ── 12. ArgoCD ───────────────────────────────────────────────────
log "ArgoCD"

jump helm upgrade --install argocd \
  "/bundle/charts/argo-cd-10.3.3.tgz" \
  --namespace argocd --create-namespace \
  --values /bundle/values/argocd-values.yaml \
  --wait --timeout 15m >/dev/null || die "ArgoCD 설치 실패."
ok "설치 완료 — 이미지는 ${HARBOR_HOST}/platform 에서"

jump kubectl apply -f /tmp/gitops/argocd/applications/eshop-airgap.yaml >/dev/null
ok "Application eshop-airgap 등록"

# ── 13. 동기화 대기 ──────────────────────────────────────────────
log "동기화"

for i in $(seq 1 100); do
  STATUS="$(jump kubectl -n argocd get application eshop-airgap \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  READY="$(jump kubectl get pods -n eshop --no-headers 2>/dev/null \
    | awk '{split($2,a,"/"); if (a[1]==a[2] && a[1]>0 && $3=="Running") c++} END {print c+0}')"
  printf '\r    %3ds  %-22s 파드 %s/11' "$((i * 6))" "${STATUS:-대기}" "${READY}"
  [[ "${STATUS}" == "Synced/Healthy" && "${READY}" == "11" ]] && break
  sleep 6
done
echo

[[ "${STATUS}" == "Synced/Healthy" ]] || warn "Application 상태 ${STATUS} — scripts/63-verify-airgap.sh 로 원인을 확인할 것."

# ── 결과 ─────────────────────────────────────────────────────────
cat <<EOF

$(printf '\033[1;32m폐쇄망 반입 완료\033[0m')

  Git 서버     http://${GITLAB_HOST}/erp/gitops   (root / ${GITLAB_ROOT_PW})
  레지스트리   http://${HARBOR_HOST}              (admin / ${HARBOR_PW})
  GitOps       http://${ARGOCD_HOST}
  애플리케이션 http://eshop.airgap

  이 이름들은 폐쇄망 안에서만 해석된다.
  점프 호스트에서 확인한다.

    docker exec -it ${JUMP} sh
    curl -s http://eshop.airgap/ | head

  호스트 브라우저로 보려면 /etc/hosts 에 아래를 넣고 :8080 으로 접근한다.
    127.0.0.1  eshop.airgap harbor.airgap argocd.airgap gitlab.airgap

  다음   scripts/63-verify-airgap.sh

EOF
