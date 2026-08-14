#!/usr/bin/env bash
#
# Phase 6a — 반출 번들 생성
#
# 폐쇄망에 들고 들어갈 것을 전부 한 디렉터리에 모은다.
# 이 디렉터리 밖의 어떤 것도 망 안에서 쓸 수 없다는 전제로 만든다.
#
#   사용법:  scripts/61-export-bundle.sh
#            scripts/61-export-bundle.sh --skip-images   목록·차트만 갱신
#
# ── 담는 것 ──────────────────────────────────────────────────────
#
#   images/bootstrap.tar   Harbor 가 서기 전에 필요한 이미지.
#                          받아올 레지스트리가 아직 없으므로 kind load 로
#                          노드에 직접 밀어 넣는다. ingress-nginx 와 Harbor 자신.
#
#   images/payload/        나머지 전부. OCI 레이아웃이다.
#                          Harbor 가 선 뒤 점프 호스트가 여기서 밀어 올린다.
#
#   images/gitlab.tar      폐쇄망 Git 서버. 클러스터가 아니라 별도 컨테이너로 뜬다.
#   images/jump.tar        점프 호스트. 망 안에는 패키지 저장소가 없으므로
#                          운영자가 쓸 도구도 반입 대상이다.
#
#   charts/                Helm 차트 tgz. helm repo 에 접속할 수 없다.
#   gitops/repo.bundle     이 저장소 자체. 폐쇄망 GitLab 의 초기 내용이 된다.
#
# ── 형식이 두 가지인 이유 ────────────────────────────────────────
#
# bootstrap 은 docker-archive 다. kind load image-archive 가 그 형식만 받는다.
# payload 는 OCI 레이아웃이다. 이미지 수가 많고 레이어가 겹치는데
# OCI 레이아웃은 blob 을 다이제스트로 저장해 중복을 자동으로 없앤다.
# .NET 이미지 6개가 같은 베이스를 공유하므로 차이가 크다.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 번들 경로를 skopeo 컨테이너에 마운트한다. docker -v 는 절대 경로만 받는다.
# 상대 경로를 주면 그것을 볼륨 "이름" 으로 해석해, 번들 대신 빈 볼륨이 붙는다.
# 셸에 따라 pwd 가 상대 경로를 돌려주는 경우가 있어 한 번 더 확인한다.
[[ "${REPO_ROOT}" == /* ]] \
  || REPO_ROOT="$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd)")"

BUNDLE="${REPO_ROOT}/.bundle"

DEV_HARBOR="harbor.localtest.me"
DEV_PROJECT="erp-hq"

GITLAB_IMAGE="gitlab/gitlab-ce:18.3.0-ce.0"
JUMP_IMAGE="erp-airgap/jump:1.0"
SKOPEO_IMAGE="quay.io/skopeo/stable:v1.19.0"

# 차트. 개발계에 설치된 것과 같은 버전을 쓴다.
CHARTS=(
  "ingress-nginx/ingress-nginx:4.15.1:https://kubernetes.github.io/ingress-nginx"
  "harbor/harbor:1.19.2:https://helm.goharbor.io"
  "argo/argo-cd:10.3.3:https://argoproj.github.io/argo-helm"
)

# ── 부트스트랩 이미지 ────────────────────────────────────────────
#
# 다이제스트 고정을 뗀 태그로 저장한다.
# name@sha256:... 형태로 저장하면 kind load 후 containerd 가
# 태그로 해석하지 못해 파드가 이미지를 찾지 못한다.
# 무결성은 번들의 MANIFEST.txt 가 대신 보증한다.
BOOTSTRAP_IMAGES=(
  "registry.k8s.io/ingress-nginx/controller:v1.15.1"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9"
  "goharbor/harbor-core:v2.15.2"
  "goharbor/harbor-db:v2.15.2"
  "goharbor/harbor-jobservice:v2.15.2"
  "goharbor/harbor-portal:v2.15.2"
  "goharbor/harbor-registryctl:v2.15.2"
  "goharbor/registry-photon:v2.15.2"
  "goharbor/trivy-adapter-photon:v2.15.2"
  "goharbor/valkey-photon:v2.15.2"
)

# ── 페이로드 이미지 ──────────────────────────────────────────────
#
#   원본 주소 | 번들 안 이름 | 폐쇄망 Harbor 목적지
#
# 목적지를 두 프로젝트로 나눈다.
#   erp-hq    우리가 빌드한 것
#   platform  외부에서 가져온 것. 출처가 다르면 보관도 나눠야
#             나중에 무엇을 갱신해야 하는지 구분된다.
APP_IMAGES=(catalog-api basket-api discount-grpc ordering-api shopping-web yarp-apigateway)

THIRD_PARTY=(
  "docker.io/library/postgres:17|postgres:17|platform/postgres:17"
  "docker.io/library/redis:7.4-alpine|redis:7.4-alpine|platform/redis:7.4-alpine"
  "docker.io/library/rabbitmq:4.1-management|rabbitmq:4.1-management|platform/rabbitmq:4.1-management"
  "docker.io/library/busybox:1.37|busybox:1.37|platform/busybox:1.37"
  "mcr.microsoft.com/mssql/server:2022-latest|mssql-server:2022-latest|platform/mssql-server:2022-latest"
  "quay.io/argoproj/argocd:v3.5.1|argocd:v3.5.1|platform/argocd:v3.5.1"
  "ecr-public.aws.com/docker/library/redis:8.6.4-alpine|argocd-redis:8.6.4-alpine|platform/argocd-redis:8.6.4-alpine"
)

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[0;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

human() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

SKIP_IMAGES=""
[[ "${1:-}" == "--skip-images" ]] && SKIP_IMAGES="1"

for tool in docker helm git; do
  command -v "${tool}" >/dev/null 2>&1 || die "${tool} 가 필요하다."
done
docker info >/dev/null 2>&1 || die "Docker 데몬이 응답하지 않는다."

# skopeo 는 컨테이너로 돈다.
#
# 호스트에 설치하지 않는 이유는 앱 저장소의 scripts/ci-push.sh 와 같다.
# 러너가 도는 머신에 도구를 하나 더 얹지 않아도 되고, 버전이 고정된다.
#
# 개발계 Harbor 는 클러스터 안에 있다. harbor.localtest.me 는 공개 DNS 에서
# 127.0.0.1 로 해석되는데, 컨테이너 안에서 그것은 자기 자신이다.
# kind 네트워크에 붙이고 Ingress 노드를 직접 가리켜야 닿는다.
DEV_INGRESS_IP="$(docker inspect erp-poc-worker \
  --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' 2>/dev/null || true)"
[[ -n "${DEV_INGRESS_IP}" ]] || die "개발계 Ingress 노드(erp-poc-worker)를 찾을 수 없다.
  반출할 애플리케이션 이미지는 개발계 Harbor 에서 가져온다. 클러스터가 떠 있어야 한다."

skopeo() {
  docker run --rm --network kind \
    --add-host "${DEV_HARBOR}:${DEV_INGRESS_IP}" \
    -v "${BUNDLE}:/bundle" "${SKOPEO_IMAGE}" "$@"
}

# 배포 중인 태그를 Git 에서 읽는다.
# 여기서 손으로 적으면 개발계에 실제로 떠 있는 것과 어긋날 수 있다.
IMAGE_TAG="$(grep -E '^\s+imageTag:' "${REPO_ROOT}/envs/dev/values.yaml" | head -1 | awk '{print $2}')"
[[ -n "${IMAGE_TAG}" ]] || die "envs/dev/values.yaml 에서 imageTag 를 읽지 못했다."

log "번들 ${BUNDLE}"
mkdir -p "${BUNDLE}/images" "${BUNDLE}/charts" "${BUNDLE}/gitops"
ok "애플리케이션 태그 ${IMAGE_TAG}"

# ── 1. 부트스트랩 이미지 ─────────────────────────────────────────
if [[ -z "${SKIP_IMAGES}" ]]; then
  log "부트스트랩 이미지 ${#BOOTSTRAP_IMAGES[@]}개"

  rm -f "${BUNDLE}"/images/bootstrap-*.tar
  : > "${BUNDLE}/images/bootstrap.txt"

  # 플랫폼을 명시해 저장해야 한다.
  #
  # docker save 는 기본적으로 이미지 인덱스를 통째로 담는다.
  # 멀티아키텍처 이미지는 인덱스에 amd64·arm64 가 모두 적혀 있는데
  # 실제 blob 은 받아온 하나뿐이라, 반입 쪽에서 이렇게 끊긴다.
  #
  #   ctr: content digest sha256:de8fd8f1...: not found
  #
  # 그런데 --platform 을 하나로 고정할 수도 없다.
  # Harbor 는 arm64 이미지를 내지 않아 이 호스트에서도 amd64 로 받아 Rosetta 로 돈다.
  # ingress-nginx 와 GitLab 은 arm64 가 있다.
  #
  # 그래서 이미지마다 실제로 받아둔 플랫폼을 확인해 그 단위로 묶는다.
  # 폐쇄망 노드도 같은 호스트 위에 있으므로 같은 조합이 그대로 통한다.
  declare -a PLATFORMS=()
  declare -a PLAT_OF=()

  for ref in "${BOOTSTRAP_IMAGES[@]}"; do
    docker image inspect "${ref}" >/dev/null 2>&1 || docker pull -q "${ref}" >/dev/null
    plat="$(docker image inspect "${ref}" --format '{{.Os}}/{{.Architecture}}')"
    PLAT_OF+=("${plat}")
    printf '%s|%s\n' "${ref}" "${plat}" >> "${BUNDLE}/images/bootstrap.txt"

    found=""
    for p in ${PLATFORMS[@]+"${PLATFORMS[@]}"}; do [[ "${p}" == "${plat}" ]] && found="1"; done
    [[ -n "${found}" ]] || PLATFORMS+=("${plat}")

    ok "${ref}  (${plat})"
  done

  for plat in "${PLATFORMS[@]}"; do
    group=()
    for i in "${!BOOTSTRAP_IMAGES[@]}"; do
      [[ "${PLAT_OF[$i]}" == "${plat}" ]] && group+=("${BOOTSTRAP_IMAGES[$i]}")
    done
    tarname="bootstrap-${plat//\//-}.tar"
    docker save --platform "${plat}" -o "${BUNDLE}/images/${tarname}" "${group[@]}"
    ok "${tarname}  ${#group[@]}개  $(human "${BUNDLE}/images/${tarname}")"
  done
fi

# ── 2. 페이로드 이미지 ───────────────────────────────────────────
if [[ -z "${SKIP_IMAGES}" ]]; then
  log "페이로드 이미지"

  rm -rf "${BUNDLE}/images/payload"
  : > "${BUNDLE}/images/payload.txt"

  # 우리가 빌드한 이미지는 개발계 Harbor 에서 가져온다.
  #
  # docker pull 을 쓸 수 없다. 개발계 Harbor 가 평문 HTTP 라
  # Docker 데몬에 insecure-registries 를 등록해야 하는데,
  # 그 설정은 데몬 전역에 영향을 준다. skopeo 는 호출마다 정할 수 있다.
  for app in "${APP_IMAGES[@]}"; do
    skopeo copy --quiet --src-tls-verify=false \
      "docker://${DEV_HARBOR}/${DEV_PROJECT}/${app}:${IMAGE_TAG}" \
      "oci:/bundle/images/payload:${app}:${IMAGE_TAG}" \
      || die "${app} 반출 실패. 개발계 Harbor 가 살아 있는지 확인할 것."
    echo "${app}:${IMAGE_TAG}|${DEV_PROJECT}/${app}:${IMAGE_TAG}" >> "${BUNDLE}/images/payload.txt"
    ok "${app}:${IMAGE_TAG}"
  done

  for entry in "${THIRD_PARTY[@]}"; do
    IFS='|' read -r src name dest <<< "${entry}"
    skopeo copy --quiet "docker://${src}" "oci:/bundle/images/payload:${name}" \
      || die "${src} 반출 실패."
    echo "${name}|${dest}" >> "${BUNDLE}/images/payload.txt"
    ok "${name}"
  done

  ok "payload/  $(human "${BUNDLE}/images/payload")  — OCI 레이아웃, 레이어 중복 제거됨"
fi

# ── 3. GitLab · 점프 호스트 ──────────────────────────────────────
if [[ -z "${SKIP_IMAGES}" ]]; then
  log "GitLab CE"
  docker image inspect "${GITLAB_IMAGE}" >/dev/null 2>&1 || docker pull -q "${GITLAB_IMAGE}" >/dev/null
  docker save --platform "$(docker image inspect "${GITLAB_IMAGE}" --format '{{.Os}}/{{.Architecture}}')" \
    -o "${BUNDLE}/images/gitlab.tar" "${GITLAB_IMAGE}"
  echo "${GITLAB_IMAGE}" > "${BUNDLE}/images/gitlab.txt"
  ok "gitlab.tar  $(human "${BUNDLE}/images/gitlab.tar")"

  log "점프 호스트"
  docker build -q -t "${JUMP_IMAGE}" "${REPO_ROOT}/infra/airgap/jump" >/dev/null
  docker save -o "${BUNDLE}/images/jump.tar" "${JUMP_IMAGE}"
  echo "${JUMP_IMAGE}" > "${BUNDLE}/images/jump.txt"
  ok "jump.tar  $(human "${BUNDLE}/images/jump.tar")"
fi

# ── 4. Helm 차트 ─────────────────────────────────────────────────
log "Helm 차트"

for entry in "${CHARTS[@]}"; do
  chart="${entry%%:*}"
  rest="${entry#*:}"
  version="${rest%%:*}"
  url="${rest#*:}"
  repo="${chart%%/*}"

  helm repo add "${repo}" "${url}" >/dev/null 2>&1 || true
  helm repo update "${repo}" >/dev/null 2>&1 || true

  if [[ -f "${BUNDLE}/charts/${chart#*/}-${version}.tgz" ]]; then
    ok "${chart} ${version} (이미 있음)"
  else
    helm pull "${chart}" --version "${version}" --destination "${BUNDLE}/charts" >/dev/null
    ok "${chart} ${version}"
  fi
done

# 폐쇄망용 values 도 함께 넣는다. 망 안에서 이 저장소를 다시 꺼내기 전에 필요하다.
mkdir -p "${BUNDLE}/values"
cp "${REPO_ROOT}"/infra/airgap/*.yaml "${BUNDLE}/values/" 2>/dev/null || true
ok "values/ $(ls -1 "${BUNDLE}/values" 2>/dev/null | wc -l | tr -d ' ')개"

# ── 5. GitOps 저장소 ─────────────────────────────────────────────
log "GitOps 저장소"

# git bundle 은 저장소 전체를 파일 하나로 만든다.
# 폐쇄망에서 이 파일을 clone 해 GitLab 에 밀어 넣는다.
# 커밋 이력이 그대로 따라오므로 반입 후에도 무엇이 언제 바뀌었는지 남는다.
BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)"
git -C "${REPO_ROOT}" bundle create "${BUNDLE}/gitops/repo.bundle" --branches --tags >/dev/null 2>&1
echo "${BRANCH}" > "${BUNDLE}/gitops/branch.txt"
ok "repo.bundle  $(human "${BUNDLE}/gitops/repo.bundle")  (현재 브랜치 ${BRANCH})"

# ── 6. 명세 ──────────────────────────────────────────────────────
#
# 반출입에서 가장 중요한 파일이다.
# 무엇이 들어갔는지, 옮기는 동안 변하지 않았는지를 이것으로 확인한다.
log "MANIFEST.txt"

{
  echo "# Phase 6a 반출 번들"
  echo "# 생성 $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "# 원본 $(git -C "${REPO_ROOT}" rev-parse --short HEAD) (${BRANCH})"
  echo "# 앱 태그 ${IMAGE_TAG}"
  echo
  echo "## 파일"
  cd "${BUNDLE}"
  # OCI blob 은 파일 이름 자체가 내용의 sha256 이다.
  # 목록만 남겨도 무결성 확인이 된다. 별도로 해시를 다시 뜨지 않는다.
  # MANIFEST.txt 자신은 뺀다.
  # 리다이렉션이 먼저 빈 파일을 만들기 때문에, 넣으면 자기 자신의 해시를
  # 쓰기 전 상태로 기록하게 되어 검증이 반드시 실패한다.
  find . -type f ! -path './images/payload/blobs/*' ! -name MANIFEST.txt | sort | while read -r f; do
    printf '%s  %s  %s\n' "$(shasum -a 256 "${f}" | awk '{print $1}')" \
      "$(du -k "${f}" | awk '{printf "%8d KiB", $1}')" "${f#./}"
  done
  echo
  echo "## OCI blob $(find ./images/payload/blobs -type f 2>/dev/null | wc -l | tr -d ' ')개"
  echo "# 파일명이 곧 sha256 이다."
  find ./images/payload/blobs -type f 2>/dev/null | sed 's|.*/||' | sort
} > "${BUNDLE}/MANIFEST.txt"

ok "$(grep -c '' "${BUNDLE}/MANIFEST.txt") 줄"

# ── 결과 ─────────────────────────────────────────────────────────
TOTAL="$(human "${BUNDLE}")"

cat <<EOF

$(printf '\033[1;32m반출 번들 준비 완료\033[0m')

  위치   ${BUNDLE}
  크기   ${TOTAL}

$(cd "${BUNDLE}" && du -sh images/* charts gitops values 2>/dev/null | sed 's/^/  /')

  실제 폐쇄망이라면 이 디렉터리를 보안 USB 나 망연계 SW 에 올린다.
  여기서는 점프 호스트 컨테이너에 마운트해 같은 역할을 하게 한다.

  다음   scripts/62-import-bundle.sh

EOF
