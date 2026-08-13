# 003. Phase 1 — EShopMicroservices Helm 차트화

이슈: [#4](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/4)
작업일: 2026-08-13

## 결과 요약

Docker Compose로 돌던 마이크로서비스 11개를 Helm 차트로 옮겨 kind 클러스터에 배포했다.
완료 조건을 모두 충족했다.

| 항목 | 값 |
|---|---|
| 파드 | 11개 (앱 6 · 인프라 5) 전부 Running·Ready |
| 누적 재시작 | 0회 |
| 완전 삭제 후 재배포 | 36초 |
| 검증 항목 | 9개 전부 통과 |
| 클러스터 메모리 사용 | 약 4.4 GiB / 23.43 GiB |

## 구성

```
                    http://eshop.localtest.me
                              │
                    ┌─────────▼─────────┐
                    │   ingress-nginx   │
                    └────┬─────────┬────┘
       api.eshop.localtest.me      │
                         │         │
                ┌────────▼───┐  ┌──▼──────────┐
                │yarp-api    │◄─┤shopping-web │
                │gateway     │  └─────────────┘
                └──┬───┬───┬─┘
        ┌──────────┘   │   └──────────┐
   ┌────▼─────┐  ┌─────▼────┐   ┌─────▼──────┐
   │catalog   │  │basket    │   │ordering    │
   │-api      │  │-api      │   │-api        │
   └────┬─────┘  └─┬──┬──┬──┘   └──┬──────┬──┘
        │          │  │  │ gRPC    │      │
   ┌────▼─────┐    │  │  └─────────┼──┐   │
   │catalogdb │    │  │            │  │   │
   │(postgres)│    │  │      ┌─────▼──▼─┐ │
   └──────────┘    │  │      │discount  │ │
              ┌────▼┐ │      │-grpc     │ │
              │basket│ │     └──────────┘ │
              │db    │ │                  │
              └──────┘ │   ┌──────────┐   │
              ┌────────▼┐  │orderdb   │◄──┘
              │distri   │  │(mssql)   │
              │butedcache│ └──────────┘
              └──────────┘
                    │  AMQP  ┌──────────────┐
                    └───────►│messagebroker │
                             │(rabbitmq)    │
                             └──────────────┘
```

## Compose 에서 달라진 것

| 항목 | Docker Compose | Kubernetes |
|---|---|---|
| 서비스 이름 | `catalog.api` | `catalog-api` |
| 외부 노출 | 서비스마다 호스트 포트 6000~6005 | Ingress 2개 호스트로 통일 |
| 설정 | `environment` 한 곳 | ConfigMap(일반) + Secret(접속 문자열) |
| 기동 순서 | `depends_on` | initContainer 가 TCP 로 대기 |
| DB 영속성 | named volume | StatefulSet + PVC |

### 서비스 이름에서 점을 뺀 이유

Kubernetes Service 이름은 DNS-1035 레이블이라 점을 쓸 수 없다.
`catalog.api` 는 유효하지 않으므로 `catalog-api` 로 바꿨다.

문제는 YARP 게이트웨이의 `appsettings.json` 이 목적지를 `http://catalog.api:8080` 으로
하드코딩하고 있다는 점이다. 이미지를 다시 빌드하지 않기 위해 환경변수로 덮어썼다.
ASP.NET Core 설정에서 `__` 는 `:` 에 해당한다.

```
ReverseProxy__Clusters__catalog-cluster__Destinations__destination1__Address=http://catalog-api:8080
```

Basket 의 `GrpcSettings__DiscountUrl`, Shopping.Web 의 `ApiSettings__GatewayAddress` 도 같은 방식으로 처리했다.

### `ASPNETCORE_ENVIRONMENT=Development` 가 필요한 이유

두 가지가 이 값에 걸려 있다. Production 으로 두면 DB 가 비어 화면에 아무것도 뜨지 않는다.

- `Catalog.API` — `InitializeMartenWith<CatalogInitialData>()` 로 상품 6종 시드
- `Ordering.API` — `InitialiseDatabaseAsync()` 로 스키마 생성 및 시드

운영 환경이라면 시드를 마이그레이션 Job 으로 분리해야 하지만, 이 PoC 는
배포 파이프라인 검증이 목적이라 원 구성을 그대로 두었다.

### initContainer 로 의존 서비스를 기다린다

Compose 의 `depends_on` 은 컨테이너 기동 순서만 정하고 준비 상태는 보지 않는다.
Kubernetes 에는 그마저도 없어서, 애플리케이션이 DB 보다 먼저 떠서 예외로 죽고
재시작을 반복하게 된다. 결국은 정상화되지만 그 사이 로그가 예외로 뒤덮여
진짜 문제를 가린다.

`busybox` 로 TCP 연결만 확인하는 initContainer 를 붙였다.

| 서비스 | 대기 대상 |
|---|---|
| `catalog-api` | `catalogdb:5432` |
| `basket-api` | `basketdb:5432` · `distributedcache:6379` · `messagebroker:5672` · `discount-grpc:8080` |
| `ordering-api` | `orderdb:1433` · `messagebroker:5672` |

## 결정 사항

### 인프라를 서드파티 차트 대신 직접 정의

Bitnami 같은 기성 차트를 쓰지 않고 StatefulSet 을 직접 작성했다.

- Phase 6 폐쇄망에서 반입할 이미지가 늘어나지 않는다
- 차트 의존성의 라이선스를 따로 감사하지 않아도 된다 (아키텍처 문서 12p 의 관심사)
- 구성이 단순해 문제가 생겼을 때 원인을 찾기 쉽다

### health probe — `/health` 가 없는 서비스는 TCP 로 확인

`/health` 는 `catalog-api` · `basket-api` · `ordering-api` 에만 구현돼 있다.
나머지 셋은 포트 개방만 확인하는 TCP 프로브를 썼다.

| 서비스 | 프로브 | 이유 |
|---|---|---|
| `catalog-api` `basket-api` `ordering-api` | HTTP `/health` | 구현돼 있고 DB 연결까지 확인한다 |
| `discount-grpc` | TCP | HTTP/2 전용이라 HTTP 프로브를 쓸 수 없다 |
| `yarp-apigateway` | TCP | health 엔드포인트가 없다 |
| `shopping-web` | TCP | health 엔드포인트가 없다. `/` 로 검사하면 게이트웨이 장애가 이 파드의 재시작으로 번진다 |

제대로 된 health 엔드포인트를 넣으려면 앱 저장소를 고쳐야 한다.
Phase 4 에서 단위 테스트를 추가하며 앱 저장소를 손댈 때 함께 처리하는 것이 맞다고 보고
이번 범위에서는 제외했다. 후속 이슈로 분리했다.

### Discount 의 SQLite 에 볼륨을 붙이지 않음

`Data Source=discountdb` 는 컨테이너 안의 파일이라 파드가 사라지면 함께 사라진다.
그런데 `DiscountContext.OnModelCreating` 이 `HasData` 로 쿠폰 2건을 심어두었고
기동 시 `MigrateAsync()` 가 돌기 때문에, 새 파드는 항상 같은 초기 상태로 복구된다.

런타임에 갱신한 쿠폰은 유실되지만 PoC 범위에서는 문제가 되지 않는다.
볼륨을 붙이면 오히려 Phase 6 에서 반출입 대상이 하나 늘어난다.

### fsGroup 지정

kind 의 기본 스토리지(local-path)는 호스트 디렉터리를 root 소유로 만든다.
컨테이너가 비 root 사용자로 동작하면 볼륨에 쓸 수 없어 기동에 실패한다.

| 구성요소 | fsGroup |
|---|---|
| Postgres | 999 |
| SQL Server | 10001 |
| RabbitMQ | 999 |

## R1 정정 — SQL Server arm64

PLAN.md 의 R1 은 "kind 노드 안의 containerd 에는 에뮬레이션이 없어 `exec format error` 가 난다"고
서술하고 있었으나 사실이 아니었다. 실제로 확인한 결과는 다음과 같다.

| 확인 항목 | 결과 |
|---|---|
| 이미지 manifest | 단일 manifest — amd64 전용이 맞다 |
| `/run/rosetta` 마운트 (kind 노드 내부) | 없음 |
| `binfmt_misc` 핸들러 | 노드 내부에서도 보임 |
| `rosetta` 등록 플래그 | `POCF` |
| alpine amd64 파드 | `x86_64` 출력, 정상 종료 |
| SQL Server 2022 파드 | 기동 완료, `SELECT @@VERSION` 응답 |

`binfmt_misc` 는 마운트 네임스페이스로 격리되지 않는 커널 전역 상태라
kind 노드 컨테이너 안에서도 등록 내용이 그대로 보인다.
그리고 `F`(fix binary) 플래그가 붙어 있어 커널이 등록 시점에 인터프리터를 열어
파일 디스크립터를 유지하므로, `/run/rosetta` 가 보이지 않는 네임스페이스에서도 변환이 동작한다.

따라서 SQL Server 를 클러스터 내부에 그대로 배치했다. 남는 비용은 PLAN.md 의 R1 항목에 정리했다.

## 산출물

| 파일 | 역할 |
|---|---|
| `charts/eshop/Chart.yaml` | 차트 메타데이터 |
| `charts/eshop/values.yaml` | 서비스 11종의 이미지·설정·의존관계 |
| `charts/eshop/templates/_helpers.tpl` | 공통 라벨, 대기 initContainer |
| `charts/eshop/templates/apps.yaml` | 앱 6개의 ConfigMap·Secret·Deployment·Service |
| `charts/eshop/templates/infra-postgres.yaml` | Postgres 2대 |
| `charts/eshop/templates/infra-others.yaml` | Redis · SQL Server · RabbitMQ |
| `charts/eshop/templates/ingress.yaml` | 외부 진입점 2개 |
| `scripts/10-build-images.sh` | 이미지 6개 빌드 후 kind 주입 |
| `scripts/11-deploy-eshop.sh` | Helm 배포 |
| `scripts/12-verify-eshop.sh` | 완료 조건 자동 검증 |

## 검증 결과

```
▶ 조건 1 — 파드 11개 Ready
  ✓ PASS  파드 11개 전부 Running·Ready
          누적 재시작 0회

▶ 조건 2 — Ingress → shopping-web
  ✓ PASS  http://eshop.localtest.me/ → 200
  ✓ PASS  화면에 상품이 렌더링됨 (web → gateway → catalog 경로 성립)

▶ 조건 3 — 상품 조회 → 장바구니 → 주문
  ✓ PASS  상품 조회 — Catalog API 응답
  ✓ PASS  장바구니 담기 → 201
  ✓ PASS  Discount gRPC 적용 — 950 → 800 (평문 HTTP/2 경로 성립)

▶ 조건 4 — 체크아웃 → RabbitMQ → 주문 생성
  ✓ PASS  체크아웃 → 이벤트 발행
  ✓ PASS  주문 생성 확인 — Basket → RabbitMQ → Ordering 비동기 경로 성립
  ✓ PASS  체크아웃 후 장바구니 삭제됨 (HTTP 404)

  통과 9 · 실패 0
```

이 검증이 확인하는 통신 경로는 다음 세 가지다.

1. **HTTP** — 화면 → 게이트웨이 → Catalog
2. **gRPC(h2c)** — Basket → Discount.
   정가 950 이 할인가 800 으로 저장되는지로 판단한다.
   gRPC 호출이 실패하면 예외 없이 원가가 쓰이므로, 응답 코드만 봐서는 알 수 없다.
3. **AMQP** — Basket → RabbitMQ → Ordering.
   체크아웃 후 주문이 생기는지로 판단한다.

**재현성** — `helm uninstall` 과 네임스페이스 삭제로 PVC 까지 지운 뒤
`scripts/11-deploy-eshop.sh` 로 36초 만에 복원하고 검증 9개를 다시 통과했다.

## 작업 중 수정한 결함

### `scripts/12-verify-eshop.sh` — awk 역참조

파드가 모두 정상인데 준비 개수가 0으로 집계됐다.

```bash
# 잘못된 코드
awk '$2 ~ /^([0-9]+)\/\1$/ && $3 == "Running"'
```

awk 의 정규식은 POSIX ERE 라 역참조(`\1`)를 지원하지 않는다.
`READY` 열의 `1/1` 을 앞뒤 비교하려던 의도였으나 아무것도 매치되지 않았다.
`split` 으로 나눠 비교하도록 고쳤다.

### `scripts/11-deploy-eshop.sh` — pipefail 과 `grep -q`

노드에 이미지가 있는데도 "없다"고 보고했고, 실행할 때마다 다른 서비스가 지목됐다.

```bash
# 잘못된 코드
docker exec "${NODE}" crictl images | grep -q "eshop/${svc} " || MISSING+=("${svc}")
```

`grep -q` 는 첫 매치에서 즉시 종료하며 파이프를 닫는다.
그러면 아직 출력 중이던 `docker exec` 가 SIGPIPE 로 죽고,
`set -o pipefail` 때문에 grep 이 성공했는데도 파이프라인 전체가 실패로 처리된다.
어느 서비스에서 터질지는 출력 순서와 타이밍에 따라 달라진다.

목록을 한 번만 받아 변수에 담고 그 안에서 찾도록 고쳤다.
`docker exec` 호출도 6회에서 1회로 줄었다.

## 실측치

| 노드 | 메모리 |
|---|---|
| `erp-poc-control-plane` | 1.148 GiB |
| `erp-poc-worker` | 1.135 GiB |
| `erp-poc-worker2` | 2.122 GiB |
| **합계** | **약 4.4 GiB / 23.43 GiB** |

애플리케이션 이미지는 351~413 MB 다.
`mcr.microsoft.com/dotnet/aspnet:8.0` 베이스가 대부분을 차지한다.
Phase 6 반출입 번들 크기를 산정할 때 SQL Server 이미지(1.5 GB)와 함께 고려해야 한다.

## 다음 단계

Phase 2 — ArgoCD GitOps.
이 차트를 Git 저장소에서 감시하게 만들고, `selfHeal` 로 수동 변경분이 되돌아오는지 확인한다.
