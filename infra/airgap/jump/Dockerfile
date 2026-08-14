# 점프 호스트 — 폐쇄망 안에서 작업할 도구 모음
#
# 폐쇄망에는 패키지 저장소가 없다. 운영자가 쓸 도구도 반입 대상이다.
# 이 이미지를 개발계에서 만들어 번들에 담고, 망 안에서는 여기에 접속해
# 이미지 푸시·Helm 설치·Git 푸시를 한다.
#
# 아키텍처 문서 16p 의 "Jump Host" 에 해당한다.
#
# 빌드: scripts/61-export-bundle.sh 가 수행한다.
FROM alpine:3.21

# skopeo  번들 tar → 폐쇄망 Harbor 이미지 전송
# helm    반입한 차트 설치
# git     반입한 저장소를 폐쇄망 GitLab 에 푸시
ARG KUBECTL_VERSION=v1.36.1

# iproute2 는 기본 경로를 지우는 데 쓴다.
# busybox 의 ip 로도 되지만 오류 메시지가 부실해 원인을 찾기 어렵다.
RUN apk add --no-cache \
      bash ca-certificates coreutils curl git iproute2 jq python3 skopeo helm openssl

# apk 의 kubectl 은 1.31 이라 1.36 API 서버와 두 단계 이상 벌어진다.
# 버전 차이는 ±1 마이너까지만 보장되므로 맞는 것을 직접 받는다.
RUN curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && kubectl version --client=true -o yaml | grep gitVersion

# 번들은 /bundle 에 마운트한다. 보안 USB 에 담아 들고 들어온 것에 해당한다.
WORKDIR /bundle

# 컨테이너가 살아 있어야 docker exec 로 들어갈 수 있다.
CMD ["sleep", "infinity"]
