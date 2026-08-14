# 007. 앱 저장소 정리 — CVE · health 엔드포인트 · CI 재시도

이슈: [#5](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/5) · [#11](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/11) · [#14](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/14)
앱 저장소 PR: [net8_Microservices#2](https://github.com/sunm2n/net8_Microservices/pull/2)
작업일: 2026-08-14

## 결과 요약

Phase 1~4을 진행하며 쌓인 앱 저장소 숙제 세 건을 정리했다.
Phase 5(품질·보안 게이트)에 들어가기 전에 치워야 할 것들이다.

| 항목 | 이전 | 이후 |
|---|---|---|
| 애플리케이션 Critical CVE | 2건 (Marten · Refit) | **0건** |
| CVE 허용목록 | 7건 | **5건** (베이스 이미지만) |
| 실질적 health 프로브 | 3개 서비스 | **6개 전부** |
| CI 빌드 재시도 | 없음 | 3회 (5초 → 20초) |

## Critical CVE 해소

Harbor 의 Trivy 스캔에서 걸리던 두 건이다.
베이스 이미지가 아니라 애플리케이션이 직접 쓰는 패키지라 버전 상향으로 해결된다.

| 패키지 | 변경 | CVE | 내용 |
|---|---|---|---|
| Marten | 6.4.1 → **8.37.4** | CVE-2026-45288 | 전문 검색 `regConfig` 파라미터 인젝션. 8.36 이하 영향 |
| Refit.HttpClientFactory | 7.0.0 → **7.2.22** | CVE-2024-51501 | `[Header]`·`[HeaderCollection]`·`[Authorize]` 의 CRLF 인젝션 |

수정 버전은 GitHub Advisory 에서 확인했다.
Marten 은 `first_patched_version` 이 8.37.0 이라 6.x 나 7.x 로는 해결되지 않는다.

**메이저 2단계 상향인데 소스 수정 없이 컴파일됐다.**
`AddMarten` · `UseLightweightSessions` · `Schema.For<T>().Identity` · `IInitialData` 등
안정 API 만 쓰고 있었다. 주문 플로우 검증도 그대로 통과했다.

### 판단 근거를 어디서 얻었나

Trivy 는 무엇이 취약한지 알려주지만 어느 버전으로 올려야 하는지는 알려주지 않는다.
두 도구를 함께 썼다.

```bash
dotnet list <프로젝트> package --vulnerable --include-transitive
gh api advisories/GHSA-vmw2-qwm8-x84c
```

앞의 것은 프로젝트별 취약 패키지와 GHSA ID 를,
뒤의 것은 영향 범위와 최초 수정 버전을 준다.

`.sln` 전체로 돌리면 `docker-compose.dcproj` 에서 멈춘다.
NuGet 패키지 참조 프로젝트가 아니라며 그 뒤 프로젝트를 건너뛴다.
프로젝트별로 따로 돌려야 전부 나온다. 이것 때문에 처음에 Catalog 만 보고
Refit 을 놓칠 뻔했다.

## health 엔드포인트

`/health` 가 `catalog-api` · `basket-api` · `ordering-api` 에만 있었다.
나머지 셋은 TCP 프로브로 대체 중이었는데, 포트 개방만 확인하므로
**"떠 있지만 동작하지 않는" 상태를 걸러내지 못한다.**

| 서비스 | 이전 | 이후 |
|---|---|---|
| `yarp-apigateway` | tcpSocket | httpGet `/health` |
| `shopping-web` | tcpSocket | httpGet `/health` |
| `discount-grpc` | tcpSocket | **grpc** `grpc.health.v1.Health` |

### `discount-grpc` 는 gRPC 표준 프로토콜로

HTTP/2 전용이라 일반 HTTP 프로브를 붙일 수 없다.
Kubernetes 는 1.24부터 `grpc` 프로브를 기본 제공하며,
서버가 `grpc.health.v1.Health` 를 구현하면 kubelet 이 직접 호출한다.

```csharp
builder.Services.AddGrpcHealthChecks()
    .AddDbContextCheck<DiscountContext>("discountdb");
...
app.MapGrpcHealthChecksService();
```

**DbContext 검사를 함께 걸었다.** 이 서비스에서 가장 실질적인 부분이다.
포트만 보는 프로브로는 SQLite 마이그레이션이 실패해도 Ready 로 잡히고,
그러면 Basket 이 할인을 받지 못하는데 **예외 없이 정가가 적용된다.**
응답 코드로는 드러나지 않아 검증 스크립트가 가격을 직접 비교하고 있던 이유다.

차트 템플릿에 `grpc` 프로브 분기를 추가했다.

```yaml
{{- else if eq $app.probe.type "grpc" }}
readinessProbe:
  grpc:
    port: {{ $app.port }}
```

### 두 가지 설계 판단

**YARP 는 `/health` 를 `MapReverseProxy` 보다 먼저 등록한다.**
순서가 뒤면 프록시가 `/health` 를 업스트림으로 넘겨 프로브가 엉뚱한 응답을 받는다.

**게이트웨이와 화면의 health 는 업스트림 상태를 보지 않는다.**
자기 자신이 요청을 받을 수 있는지만 판단한다.
업스트림 장애가 이 파드들의 재시작으로 번지면 복구가 오히려 느려진다.
각 서비스는 자기 `/health` 로 판단하면 된다.

## CI 빌드 재시도

`mcr.microsoft.com` 에서 베이스 이미지를 받는 과정이 간헐적으로 실패해
파이프라인이 멈추고 사람이 재실행해야 했다.

```
Head "https://mcr.microsoft.com/v2/dotnet/aspnet/manifests/8.0": EOF
```

`ci-build.sh` 에 3회 재시도(5초 → 20초 백오프)를 넣었다.

컴파일 오류와 네트워크 오류를 종료 코드로 구분할 수 없어 단순 재시도로 둔다.
컴파일 오류라면 세 번 모두 같은 이유로 실패하고 파이프라인은 정상적으로 멈춘다.

근본 해결은 베이스 이미지를 내부 레지스트리로 미러링하는 것이다.
폐쇄망 단계에서는 외부 접근이 불가능해 미러링이 **선택이 아니라 필수**가 된다.

## 허용목록을 줄인 이유

CVE 허용목록을 7건에서 5건으로 줄였다.

```
제거  CVE-2026-45288  Marten   → 8.37.4 로 해소
제거  CVE-2024-51501  Refit    → 7.2.22 로 해소
남김  perl-base 4건 · zlib1g 1건  → 베이스 이미지, 손댈 수 없음
```

**허용목록은 손댈 수 없는 것만 담아야 한다.**
고칠 수 있는 것을 넣어두면 목록이 쌓이기만 하고 게이트가 아무것도 막지 않게 된다.
Phase 3에서 두 건을 넣은 것은 파이프라인을 막지 않기 위한 임시 조치였고,
이번에 원래 자리로 되돌렸다.

남은 5건은 `mcr.microsoft.com/dotnet/aspnet:8.0` 이 딸고 오는 Debian 패키지다.
PLAN.md R4(.NET 8 → .NET Core 10)와 함께 볼 항목이다.

## 검증 결과

**앱 저장소**

```
dotnet build                          오류 0개
dotnet list package --vulnerable
  Catalog.API     Critical 없음
  Basket.API      Critical 없음
  Shopping.Web    Critical 없음

컨테이너 기동 후
  yarp-apigateway  GET /health        → 200
  shopping-web     GET /health        → 200
  discount-grpc    grpc_health_probe  → status: SERVING
```

**Harbor 게이트** — 허용목록을 5건으로 줄인 뒤

| 이미지 | 결과 |
|---|---|
| 새 이미지 6개 (`e0be959de38d`) | 통과 |
| 옛 이미지 (`:local`, Marten·Refit CVE 있음) | **차단** |

같은 정책에서 고친 것은 통과하고 안 고친 것은 막힌다.
게이트가 CVE 단위로 정확히 판단한다는 뜻이다.

**클러스터**

```
적용된 프로브
  basket-api           httpGet    /health
  catalog-api          httpGet    /health
  discount-grpc        grpc       port 8080
  ordering-api         httpGet    /health
  shopping-web         httpGet    /health
  yarp-apigateway      httpGet    /health

주문 플로우   9개 항목 통과
GitOps 검증   6개 항목 통과
```

`discount-grpc` 파드가 Ready 라는 것 자체가 kubelet 이 gRPC 로 `SERVING` 을 받았다는 증거다.

## 작업 중 겪은 것

### 앱 저장소 로컬 체크아웃이 샌드박스에 막혔다

`EShopMicroservices-main/.git/config` 접근이 `Operation not permitted` 로 거부됐다.
PoC 저장소는 정상이었고 그 디렉터리만 막혔다.

권한을 우회하는 대신 별도 위치에 새로 클론해 작업했다.
권위 있는 사본은 GitHub 이고 로컬 체크아웃은 편의용이라 잃을 것이 없었다.
CI 도 GitHub 에서 받아 빌드한다.

### 검증 명령의 zsh 파라미터 수정자

이미지 태그 검사가 전부 "차단"으로 나와 게이트 설정을 의심했다.
실제로는 검사 명령의 문제였다.

```bash
check "$r:local"     # zsh 가 ${r:l} (소문자 변환) + "ocal" 로 해석
check "${r}:local"   # 의도한 대로
```

zsh 에서 `:l` `:e` 등은 파라미터 수정자다.
`catalog-api:local` 이 `catalog-apiocal` 이라는 없는 태그가 되어 조회에 실패했다.
출력에 `catalog-apiocal` 이 찍혀 있었는데 처음에는 표시 문제로 넘겼다.

커밋된 스크립트가 아니라 임시 검사 명령에서 난 문제지만,
**도구 설정을 의심하기 전에 검사 자체를 의심해야 한다는 사례**로 남긴다.

## 남은 것 — High 등급

`dotnet list package --vulnerable` 은 High 등급도 여럿 보고한다.

| 패키지 | 등급 | 영향 |
|---|---|---|
| `System.Text.Json` 8.0.0 | High | 6개 서비스 전부 |
| `Npgsql` 8.0.0 | High | Catalog · Basket |
| `Microsoft.Extensions.Caching.Memory` 8.0.0 | High | Ordering · Discount |
| `SQLitePCLRaw.lib.e_sqlite3` 2.1.6 | High | Discount |
| `System.Formats.Asn1` 5.0.0 | High | Ordering |
| `Azure.Identity` · `Microsoft.Identity*` | Moderate·Low | Ordering |

대부분 전이 의존성이라 직접 참조를 추가해 고정해야 한다.
Harbor 게이트는 Critical 만 차단하므로 배포에는 지장이 없어 이번 범위에서 제외했다.
별도 이슈로 정리했다.

## 다음 단계

Phase 5 — 품질·보안 게이트.
CI 워크플로에 자리만 만들어 둔 테스트·정적분석을 채운다.
