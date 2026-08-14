# 009 — Phase 6a 폐쇄망 반출입 및 배포

이슈 [#22](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/22) · 브랜치 `feat/phase6a-airgap`

인터넷에 닿지 않는 클러스터에 **반입한 파일만으로** 애플리케이션을 배포했다.
검증 20개 전부 통과했고, **PoC 검증 목표 4번**(인터넷 없이 반입 이미지만으로 배포)이 여기서 성립한다.

---

## 무엇을 세웠나

```
개발계 (인터넷 O)                          폐쇄망 (인터넷 X)
  github.com/sunm2n/*                        gitlab.airgap        Git 서버
  kind-erp-poc          3노드                kind-erp-airgap      2노드
  harbor.localtest.me                        harbor.airgap        레지스트리
  ArgoCD                                     ArgoCD
                                             airgap-jump          점프 호스트
        │                                          ▲
        └──── .bundle/ 3.6GB ──── 반출입 ─────────┘
```

두 망 사이의 유일한 통로는 디렉터리 하나다. 그 밖의 경로는 존재하지 않는다.

| | 개발계 | 폐쇄망 |
|---|---|---|
| Git | github.com | GitLab CE 18.3 (컨테이너) |
| 레지스트리 | Harbor 2.15.2 | Harbor 2.15.2 |
| GitOps | ArgoCD 3.5.1 | ArgoCD 3.5.1 |
| 이미지 출처 | 인터넷 + Harbor | **폐쇄망 Harbor 뿐** |
| CI | GitHub Actions | 없음 (반입만) |

---

## 격리를 어떻게 만들었나

### `--internal` 네트워크는 쓸 수 없었다

이슈에 적었던 방법은 `docker network create --internal` 이었다. 노드가 부팅하지 못했다.

```
iptables-restore v1.8.11 (nf_tables): host/network `' not found
```

internal 네트워크에는 게이트웨이가 없는데, kind 의 진입 스크립트가 게이트웨이 주소를
참조해 iptables 규칙을 만든다. 주소가 빈 문자열이라 규칙 생성이 실패하고 노드가 죽는다.

### 대신 기본 경로를 지웠다

일반 네트워크에 클러스터를 올린 뒤 각 노드에서 기본 경로만 삭제한다.
서브넷 내부 경로는 남으므로 클러스터 통신은 그대로이고, 밖으로 나가는 길만 사라진다.

부수 효과로 호스트에서 `kubectl` 이 계속 동작한다. 관찰이 쉬워지는 반면,
**호스트에서 하는 어떤 확인도 증거가 되지 못한다**는 문제가 생긴다.
호스트는 인터넷에 연결돼 있고 폐쇄망 밖에 있기 때문이다. 그래서 점프 호스트를 뒀다.

### 서비스 CIDR 경로는 남겨야 한다

기본 경로를 지우자 Harbor 설치가 이렇게 실패했다.

```
failed calling webhook "validate.nginx.ingress.kubernetes.io":
dial tcp 10.96.97.48:443: connect: network is unreachable
```

ClusterIP(10.96.0.0/16)는 iptables 가 파드 IP 로 바꿔주지만, **그 전에 커널이 경로를 찾는다.**
맞는 경로가 하나도 없으면 그 자리에서 끊긴다. 기본 경로가 그 역할을 하고 있었던 것이다.

파드끼리는 멀쩡한데 API 서버만 막히는 형태라 원인을 찾기 까다로웠다.
`ip route replace 10.96.0.0/16 dev eth0` 한 줄로 해결된다.
CIDR 은 `kube-apiserver.yaml` 의 `--service-cluster-ip-range` 에서 읽는다.

### 컨테이너는 자기 라우팅 테이블도 못 고친다

GitLab 컨테이너에서 `ip route del default` 가 조용히 실패했다.

```
ip: RTNETLINK answers: Operation not permitted
```

kind 노드는 privileged 라 문제가 없었지만 일반 컨테이너는 `NET_ADMIN` 이 필요하다.
`|| true` 로 넘긴 명령이라 실패가 드러나지 않았고, **그 다음 줄에서 실제로 나가지는지
확인한 덕분에** 잡혔다. 명령의 성공이 아니라 결과를 확인해야 하는 이유다.

---

## 번들 — 무엇을 들고 들어가나

`scripts/61-export-bundle.sh` 가 `.bundle/` 을 만든다. **3.6GB.**

| 항목 | 크기 | 형식 | 쓰임 |
|---|---|---|---|
| `images/bootstrap-linux-amd64.tar` | 523MB | docker-archive | Harbor 8개 |
| `images/bootstrap-linux-arm64.tar` | 139MB | docker-archive | ingress-nginx 2개 |
| `images/payload/` | 1.3GB | OCI 레이아웃 | 앱 6 · 인프라 5 · ArgoCD 2 |
| `images/gitlab.tar` | 1.6GB | docker-archive | GitLab CE |
| `images/jump.tar` | 84MB | docker-archive | 점프 호스트 도구 |
| `charts/` | 348KB | tgz | Helm 차트 3종 |
| `gitops/repo.bundle` | 164KB | git bundle | 저장소 전체(커밋 31개) |
| `values/` | 12KB | yaml | 폐쇄망용 values |

이슈에서 10GB 를 넘을 것으로 봤는데 실제로는 그 3분의 1이었다.
OCI 레이아웃이 레이어를 다이제스트로 저장해 중복을 없애기 때문이다.
.NET 이미지 6개가 같은 베이스를 공유하므로 차이가 크다 —
개별 tar 로 담았다면 페이로드만 2.4GB 를 넘었을 것이다.

### 형식이 두 가지인 이유

`kind load image-archive` 는 docker-archive 만 받는다.
Harbor 가 서기 전에 노드로 직접 밀어 넣어야 하는 이미지는 그 형식이어야 한다.

나머지는 Harbor 를 거치므로 OCI 레이아웃을 쓴다. skopeo 가 읽고 쓸 수 있고,
이미지가 늘어나도 겹치는 레이어만큼 번들이 줄어든다.

### 무결성

`MANIFEST.txt` 가 파일 17개의 sha256 과 OCI blob 96개의 목록을 담는다.
blob 은 파일 이름 자체가 내용의 sha256 이라 목록만으로 확인이 된다.

반입할 때 `scripts/62-import-bundle.sh` 가 가장 먼저 이것을 검증한다.
`verify-only` 로 따로 돌릴 수도 있다.

---

## 반입 순서 — 닭과 달걀

Harbor 를 폐쇄망에 올리려면 Harbor 이미지가 먼저 노드에 있어야 하는데
그 이미지를 받을 레지스트리가 아직 없다. 그래서 두 단계다.

```
1단계  kind load     레지스트리 없이 노드 containerd 에 직접
       ingress-nginx 2개 · Harbor 8개
              ↓
2단계  skopeo        Harbor 가 선 뒤 정상 경로로
       앱 6개 · 인프라 5개 · ArgoCD 2개  →  harbor.airgap
```

실제 폐쇄망도 같다. 첫 레지스트리는 tar 로 서버에 직접 올리고 그 다음부터 레지스트리를 쓴다.

전체 순서는 이렇다.

1. 번들 무결성 확인
2. **격리 확인** — 막히지 않은 상태에서 통과하면 아무것도 증명하지 못한다
3. GitLab CE 기동 (컨테이너, 기본 경로 삭제)
4. 점프 호스트 기동 (번들을 읽기 전용으로 마운트, 기본 경로 삭제)
5. 부트스트랩 이미지 `kind load`
6. 노드에 `/etc/hosts` + containerd `certs.d`
7. ingress-nginx 설치 (번들의 차트)
8. Harbor 설치 → 프로젝트 `erp-hq`, `platform` 생성
9. 페이로드 이미지 13개 푸시
10. CoreDNS 에 `.airgap` 이름 등록
11. GitLab 토큰 발급 → 그룹·프로젝트 생성 → 저장소 푸시
12. ArgoCD 설치 (이미지는 `harbor.airgap/platform`)
13. Application 등록 → 동기화 대기

---

## 점프 호스트

폐쇄망 네트워크에 붙은 도구 컨테이너다. 기본 경로가 없어 인터넷에 나갈 수 없고,
번들이 `/bundle` 에 **읽기 전용**으로 마운트돼 있다.

```
alpine:3.21 + skopeo · helm · kubectl · git · python3
```

`docker exec` 로 들어가 반입·검증을 한다. 아키텍처 문서 16p 의 Jump Host 와 같은 역할이다.

**이것이 없으면 증명이 성립하지 않는다.** 호스트(맥)에서 `helm install` 이 성공하는 것은
호스트가 인터넷에 연결돼 있으므로 아무것도 말해주지 않는다.
설치와 검증이 모두 망 안에서 일어나야 "반입물만으로 됐다" 고 할 수 있다.

도구 자체도 반입 대상이라는 점이 폐쇄망의 성격을 잘 보여준다.
망 안에는 `apk add` 할 저장소가 없다. `kubectl` 조차 들고 들어가야 한다.

> apk 의 kubectl 은 1.31 이고 클러스터는 1.36 이다. 버전 차이는 ±1 마이너까지만
> 보장되므로 이미지 빌드 시점에 맞는 것을 직접 받는다.

---

## 이름 해석 — 세 군데를 맞춰야 한다

폐쇄망에는 공개 DNS 가 없다. `localtest.me` 를 그대로 쓸 수 없어 `.airgap` 으로 바꿨다.
어떤 이름이 망 안에서만 통하는지 한눈에 구분된다.

| 어디서 | 무엇이 해석하나 | 왜 필요한가 |
|---|---|---|
| 노드 | `/etc/hosts` | containerd 가 이미지를 받을 때 |
| 파드 | CoreDNS `hosts` 블록 | ArgoCD 가 `gitlab.airgap` 을 찾을 때 |
| 점프 호스트 | `--add-host` | 운영자가 접근할 때 |

셋 중 하나만 빠져도 증상이 다르게 나타난다.
CoreDNS 를 빠뜨리면 **이미지는 다 들어왔는데 GitOps 만 안 도는** 상태가 된다.

CoreDNS 는 기존 Corefile 을 읽어 `hosts` 블록만 끼워 넣는다.
통째로 새로 쓰면 kind 가 만든 설정과 미묘하게 달라질 수 있다.
`hosts` 는 `kubernetes` 플러그인보다 앞에 오되 `fallthrough` 가 있어야 하고,
이것이 빠지면 클러스터 내부 이름 해석이 통째로 멈춘다.

---

## 아키텍처가 그대로 통했다

폐쇄망을 위해 **차트를 고치지 않았다.** 바뀐 것은 환경 값 파일 하나다.

```yaml
# envs/airgap/values.yaml — envs/dev/values.yaml 과 다른 부분 전부
global:
  imageRegistry: harbor.airgap/erp-hq      # ← harbor.localtest.me/erp-hq
ingress:
  host: eshop.airgap                       # ← eshop.localtest.me
  gatewayHost: api.eshop.airgap
infra:
  catalogdb: { image: harbor.airgap/platform/postgres:17 }
  # … 인프라 5종
waitImage: harbor.airgap/platform/busybox:1.37
```

Phase 2에서 `charts/` 와 `envs/` 를 나눈 판단이 여기서 값을 했다.
차트를 폐쇄망용으로 따로 만들어야 했다면 환경 분리가 실패한 것이다.

`waitImage` 를 놓치기 쉽다. 애플리케이션은 다 반입했는데 파드가 Init 에서 멈춘다.

---

## 검증 결과

`scripts/63-verify-airgap.sh` — **20개 전부 통과.**
HTTP 요청은 전부 점프 호스트에서 나간다.

| 조건 | 결과 |
|---|---|
| 1. 노드 2대 · 점프 · GitLab 외부 차단, 레지스트리 pull 불가 | 통과 |
| 2. 번들 3.6GB 로 반입, 마운트 읽기 전용 | 통과 |
| 3. ArgoCD 가 `gitlab.airgap` 감시, `Synced/Healthy` | 통과 |
| 4. 파드 11개 Ready, **이미지 11종 전부 `harbor.airgap` 출처** | 통과 |
| 5. 주문 플로우 — HTTP · gRPC · AMQP | 통과 |
| 6. 개발계 검증 재통과 | 통과 |

조건 4가 이 단계의 실질이다. 파드가 떴다는 것만으로는 부족하고,
이미지가 어디서 왔는지가 증명 대상이다.

```
harbor.airgap/erp-hq/basket-api:2a960c41e21e
harbor.airgap/erp-hq/catalog-api:2a960c41e21e
harbor.airgap/erp-hq/discount-grpc:2a960c41e21e
harbor.airgap/erp-hq/ordering-api:2a960c41e21e
harbor.airgap/erp-hq/shopping-web:2a960c41e21e
harbor.airgap/erp-hq/yarp-apigateway:2a960c41e21e
harbor.airgap/platform/busybox:1.37
harbor.airgap/platform/mssql-server:2022-latest
harbor.airgap/platform/postgres:17
harbor.airgap/platform/rabbitmq:4.1-management
harbor.airgap/platform/redis:7.4-alpine
```

주문 플로우에서 정가 950 이 800 으로 저장되는 것이 Discount gRPC 가 실제로 불렸다는 뜻이고,
체크아웃 후 주문이 생기는 것이 RabbitMQ 경로가 성립했다는 뜻이다.
개발계에서 확인한 것과 같은 경로를 인터넷 없이 그대로 태웠다.

---

## 실측 자원

| 컨테이너 | 메모리 |
|---|---|
| `airgap-gitlab` | 3.29 GiB |
| `erp-airgap-worker` | 3.92 GiB |
| `erp-airgap-control-plane` | 1.17 GiB |
| `airgap-jump` | 0.01 GiB |
| **폐쇄망 합계** | **8.39 GiB** |
| 개발계 합계 | 6.00 GiB |
| **전체** | **14.4 / 23.4 GiB** |

**GitLab CE 가 폐쇄망 전체의 40% 를 쓴다.** Prometheus·Grafana·Registry·KAS 를 끄고
puma 워커를 2개로 줄인 뒤의 수치다. 기본값이면 4GB 를 넘는다.

Git 저장소 하나를 서비스하는 데 3.3GB 라는 것은, 이 역할에 적정한 선택인지
따져볼 만한 수치다. 다만 GitLab 은 Git 서버만이 아니라 CI·이슈·MR·레지스트리를
함께 제공하므로, 그것들을 쓸 계획이 있는지에 따라 판단이 달라진다.
**PoC 이후에 볼 항목으로 남긴다.**

시작하기 전 개발계에서 SonarQube 를 내려 약 2.2GB 를 확보했다.
Phase 6a 와 무관한 구성요소이고, `scripts/50-install-sonarqube.sh` 로 다시 세울 수 있다.
다만 차트가 PVC 를 함께 지우므로 **재설치 후에는 CI 를 한 번 돌려야 분석 결과가 다시 쌓인다.**

---

## 도구에서 겪은 것

### `docker save` 는 인덱스를 통째로 담는다

멀티아키텍처 이미지를 받아두면 인덱스에는 amd64·arm64 가 모두 적혀 있는데
실제 blob 은 받아온 하나뿐이다. 반입 쪽에서 이렇게 끊긴다.

```
ctr: content digest sha256:de8fd8f1...: not found
```

`--platform` 으로 고정하면 되는데, 하나로 고정할 수도 없었다.

| 이미지 | arm64 | 비고 |
|---|---|---|
| ingress-nginx | 있음 | |
| GitLab CE | 있음 | 17.x 이후 |
| **Harbor 8종** | **없음** | amd64 + Rosetta 로 동작 |

**Harbor 는 arm64 이미지를 내지 않는다.** 그래서 이미지마다 실제로 받아둔 플랫폼을
확인해 그 단위로 묶는다. 결과가 `bootstrap-linux-amd64.tar` 와 `bootstrap-linux-arm64.tar` 다.

운영 서버가 x86_64 라면 이 분기는 사라진다. 다만 **번들을 만든 곳과 푸는 곳의 아키텍처가
같아야 한다**는 제약은 남는다. 폐쇄망 반출입에서 흔히 놓치는 지점이다.

### 다이제스트 고정을 뗐다

ingress-nginx 차트는 `controller:v1.15.1@sha256:594cee...` 처럼 태그와 다이제스트를
함께 지정한다. `kind load` 로 넣은 이미지는 containerd 에 태그만 가진 기록으로 남아
`name@digest` 요청을 찾지 못한다.

검증 지점이 실행 시점에서 반입 시점으로 옮겨간 것이지 사라진 것은 아니다.
무엇을 받았는지는 `MANIFEST.txt` 가 sha256 으로 남긴다.

### GitLab 의 `/-/readiness` 는 밖에서 404 를 준다

`monitoring_whitelist`(기본 `127.0.0.0/8`)에 있는 주소에만 답한다.
점프 호스트에서 이것으로 기동을 판단하면 GitLab 이 멀쩡히 떠 있어도 영원히 기다리게 된다.
컨테이너 안에서 readiness 를, 점프 호스트에서 `/users/sign_in` 을 본다.

### `docker exec` 는 `-i` 없이 stdin 을 받지 않는다

같은 실수를 두 번 했다.

```bash
# 컨테이너 안에서 빈 입력을 읽고 조용히 실패한다
kubectl get cm -o yaml | docker exec JUMP kubectl apply -f -
docker exec JUMP curl ... | docker exec JUMP python3 -c '...'
```

첫 번째는 `no objects passed to apply` 로, 두 번째는 파싱 실패로 나타났다.
증명해야 할 것은 "요청이 폐쇄망 안에서 나갔는가" 이지 응답을 어디서 해석하는가가
아니므로, 검증 스크립트는 요청만 점프 호스트에서 하고 파싱은 호스트에서 한다.

---

## 남은 것

| 항목 | 어디로 |
|---|---|
| Trivy 취약점 DB 반입 | Phase 6b. 지금은 폐쇄망 Harbor 의 Trivy 를 껐다. 켜두면 DB 를 못 받아 CrashLoopBackOff 로 남는다 |
| 베이스 이미지 미러링 (`mcr.microsoft.com`) | Phase 6b. 폐쇄망에서 **빌드**하려면 필요하다. 6a 는 개발계에서 빌드한 결과물을 반입한다 |
| NuGet 패키지 미러링 (Nexus) | Phase 6b |
| Harbor 레플리케이션 | Phase 6b. 지금은 사람이 tar 를 옮긴다 |
| GitLab CI 전환 검토 | Phase 7 이후. 문서 9p 의 "GitLab CI 로 단일화" |
| TLS | Phase 8. 폐쇄망도 지금은 평문 HTTP 다 |
| 자격증명 | Phase 8(OpenBao). GitLab 프로젝트를 public 으로 둬 ArgoCD 가 자격증명 없이 읽는다 |

폐쇄망에는 CI 가 없다. `envs/airgap/values.yaml` 의 태그는 사람이 반입 절차로 옮긴
결과이지 파이프라인이 자동으로 쓴 값이 아니다. 이 차이가 운영에서 어떻게 관리될지는
Phase 7 이후에 볼 항목이다.

---

## 다시 만들기

```bash
scripts/60-create-airgap-cluster.sh     # 격리 클러스터
scripts/61-export-bundle.sh             # 반출 (약 10분, 3.6GB)
scripts/62-import-bundle.sh             # 반입 (약 15분)
scripts/63-verify-airgap.sh             # 검증 20개
```

노드를 재시작하면 Docker 가 기본 경로를 되살린다.
`scripts/60-create-airgap-cluster.sh isolate` 로 다시 끊는다.

정리는 `scripts/60-create-airgap-cluster.sh delete` 와
`docker rm -f airgap-jump airgap-gitlab` 이다.

호스트 브라우저로 보려면 `/etc/hosts` 에 아래를 넣고 `:8080` 으로 접근한다.

```
127.0.0.1  eshop.airgap harbor.airgap argocd.airgap gitlab.airgap
```
