# 002. Phase 0 — 로컬 kind 클러스터 구축

이슈: [#1](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/1)
작업일: 2026-08-13

## 결과 요약

노드 3대 kind 클러스터와 Ingress 진입 경로를 구축했다. 완료 조건 4개를 모두 충족했다.

| 항목 | 값 |
|---|---|
| 클러스터 | `erp-poc` (control-plane 1 + worker 2) |
| Kubernetes | v1.36.1 |
| 컨테이너 런타임 | containerd 2.3.1 |
| 노드 OS | Debian 13 (trixie) · linux/arm64 |
| Ingress | ingress-nginx 4.15.1 (app 1.15.1) |
| 전체 재구축 시간 | 1분 43초 |

## 구성

```
호스트 (macOS)
  │  localhost:80, :443
  ▼
erp-poc-worker  ── ingress-nginx 컨트롤러 (hostPort 80/443, nodeSelector: ingress-ready=true)
                          │
                          ▼
                   Service → Pod  (erp-poc-worker, erp-poc-worker2 에 분산)

erp-poc-control-plane  제어 평면
```

## 결정 사항

### Docker Desktop 내장 Kubernetes 대신 kind

멀티 노드 구성과 클러스터 복수 운영이 뒤 단계에서 필요하기 때문이다.

- Phase 1 — `nodeSelector`, `topologySpreadConstraints` 등 실제 스케줄링 동작 검증
- Phase 6 — 개발계/운영계 클러스터 2개를 동시에 띄워 폐쇄망 반출입 시뮬레이션
- 설정을 `cluster.yaml`로 Git 관리 (GUI 체크박스와 달리 이력이 남는다)

### Ingress 노드를 제어 평면이 아닌 워커에 배치

kind 공식 예제는 단일 노드를 전제하므로 제어 평면에 `extraPortMappings`를 둔다.
노드가 3대인 이 구성에서는 워커에 두는 편이 단순하다.
제어 평면에는 `node-role.kubernetes.io/control-plane:NoSchedule` 테인트가 걸려 있어
toleration을 계속 관리해야 하는데, 워커를 쓰면 그 부담이 없다.

`erp-poc-worker` 가 호스트 80/443과 연결된 유일한 노드이므로,
컨트롤러는 `ingress-ready=true` 라벨로 이 노드에 고정된다.

### 노드 라벨을 `kubeadmConfigPatches` 대신 `kubectl label` 로 부여

kind 문서는 `kubeadmConfigPatches` 안에서 `kubeletExtraArgs.node-labels` 로 라벨을 준다.
그런데 kubeadm v1beta4(Kubernetes 1.31+)에서 `kubeletExtraArgs` 의 스키마가
맵에서 리스트로 바뀌었다. 이 클러스터는 v1.36이라 형식이 어긋날 여지가 있다.

라벨 부여는 클러스터 생성 이후 `kubectl label` 로 처리하는 편이 버전 변화에 영향을 덜 받는다.
부트스트랩 스크립트는 라벨을 붙인 뒤, 그 노드가 실제로 호스트 포트와 연결돼 있는지
`docker port` 로 교차 확인한다. 노드 이름과 포트 매핑이 어긋나면
Ingress는 정상으로 보이지만 브라우저 접속만 실패하는, 원인을 찾기 까다로운 상태가 되기 때문이다.

### 노드 이미지를 digest 까지 고정

```yaml
image: kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5
```

태그만 쓰면 업스트림이 갱신될 때 재구축 결과가 달라진다.
앱 저장소에서 `postgres:latest` 가 18로 올라가며 기존 볼륨과 맞지 않아
컨테이너가 재시작을 반복했던 것과 같은 유형의 문제다.
같은 이유로 ingress-nginx 차트 버전도 스크립트에 고정했다.

### `localtest.me` 로 호스트 기반 라우팅 검증

`localtest.me` 와 그 하위 도메인은 공개 DNS에서 `127.0.0.1` 로 해석된다.
`/etc/hosts` 를 건드리지 않고 Ingress 호스트 규칙을 시험할 수 있다.

## 산출물

| 파일 | 역할 |
|---|---|
| `infra/kind/cluster.yaml` | 클러스터 정의 — 노드 3대, 호스트 포트 매핑 |
| `infra/ingress-nginx/values.yaml` | ingress-nginx Helm values |
| `infra/samples/whoami.yaml` | 검증용 샘플 워크로드 (검증 후 삭제됨) |
| `scripts/00-bootstrap.sh` | 클러스터 생성 → Ingress 준비까지. 재실행 가능 |
| `scripts/01-verify.sh` | 완료 조건 4개 자동 검증 |
| `scripts/99-teardown.sh` | 클러스터 삭제 |

## 검증 결과

```
▶ 조건 1 — 노드 3대 Ready
  ✓ PASS  노드 3대 전부 Ready
          erp-poc-control-plane        Ready    control-plane
          erp-poc-worker               Ready    <none>
          erp-poc-worker2              Ready    <none>

▶ 조건 2 — Ingress 컨트롤러 배치
  ✓ PASS  컨트롤러가 erp-poc-worker 에 배치됨 (호스트 포트 매핑 노드)

▶ 조건 3 — 호스트 → Ingress → 파드 경로
  ✓ PASS  http://whoami.localtest.me/ → 200
          Hostname: whoami-746759696b-jrjgv
          RemoteAddr: 10.244.2.3:37848

▶ 조건 4 — 멀티 노드 스케줄링
  ✓ PASS  복제본 2개가 서로 다른 노드 2대에 배치됨
          whoami-746759696b-bmzg4   erp-poc-worker
          whoami-746759696b-jrjgv   erp-poc-worker2

  통과 4 · 실패 0
```

추가로 확인한 항목:

- **멱등성** — 클러스터가 있는 상태에서 `00-bootstrap.sh` 재실행 시 생성을 건너뛰고 정상 종료(0)
- **재구축** — `99-teardown.sh` 후 `00-bootstrap.sh` 로 1분 43초 만에 동일 상태 복원, 검증 4/4 통과
- **오류 처리** — 클러스터가 없는 상태에서 `01-verify.sh` 실행 시 안내 메시지 출력 후 종료 코드 1

## 발견된 문제 — Docker Desktop 메모리 할당

작업 중 확인한 사항이며, Phase 0 자체에는 영향이 없지만 뒤 단계에서 문제가 된다.

```
호스트                     64 GB
Docker Desktop VM         7.75 GB   ← 여기가 실제 상한
```

`~/Library/Group Containers/group.com.docker/settings-store.json` 에 메모리 관련 키가 없어
기본값을 쓰고 있다. 컨테이너가 쓸 수 있는 메모리는 호스트 전체가 아니라 이 VM 할당량이다.

현재 사용량은 여유가 있다.

| 노드 | 메모리 |
|---|---|
| `erp-poc-control-plane` | 721 MiB |
| `erp-poc-worker` | 336 MiB |
| `erp-poc-worker2` | 169 MiB |
| **합계** | **약 1.2 GiB / 7.75 GiB** |

문제는 앞으로 올라갈 것들이다.

| 단계 | 구성 | 예상 |
|---|---|---|
| Phase 1 | 앱 6개 + Postgres 2 + Redis + RabbitMQ + SQL Server | 약 3.5~4 GiB |
| Phase 2 | ArgoCD | 약 0.5~1 GiB |
| Phase 3 | Harbor | 약 2 GiB |
| | 클러스터 자체 | 약 1.2 GiB |
| | **누적** | **약 7~8 GiB** |

Phase 3 시점에 한계에 닿는다. SQL Server 컨테이너 하나가 1.5~2 GiB를 쓰는 것이 특히 크다.
Phase 6은 클러스터를 2개 띄우므로 현재 할당량으로는 불가능하다.

후속 이슈 [#2](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/2) 로 분리했다.
Docker Desktop 설정 변경은 GUI 조작과 데몬 재시작이 필요해 이 작업 범위에서 처리하지 않았다.

## 다음 단계

Phase 1 — EShopMicroservices Helm 차트화.
착수 전 [PLAN.md의 Phase 1 리스크](../PLAN.md#phase-1-리스크-착수-전-결정-필요) R1(SQL Server arm64 이미지 부재) 결정이 필요하다.
