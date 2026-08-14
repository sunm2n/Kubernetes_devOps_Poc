# 008. Phase 5 — 품질·보안 게이트

이슈: [#18](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/18)
앱 저장소 PR: [#3](https://github.com/sunm2n/net8_Microservices/pull/3) · [#4](https://github.com/sunm2n/net8_Microservices/pull/4) · [#5](https://github.com/sunm2n/net8_Microservices/pull/5)
작업일: 2026-08-14

## 결과 요약

Phase 4에서 파이프라인이 **도는 것**을 증명했다. 이번에는 **막아야 할 때 막는 것**을 증명했다.

| 항목 | 값 |
|---|---|
| 단위 테스트 | **33개** (Ordering.Domain 24 · Catalog.API 9) |
| 정적분석 | SonarQube 2026.4.1 Community |
| 파이프라인 단계 | 6단계 (테스트 → 정적분석 → 빌드 → 푸시 → 스캔 → 매니페스트) |
| 검증 | 8개 항목 전부 통과 |

## 파이프라인

```
단위 테스트  →  정적분석  →  이미지 빌드  →  Harbor 푸시  →  스캔 확인  →  매니페스트 갱신
   33개         품질 게이트      6개          erp-hq        Critical      ArgoCD 트리거
```

**싼 검사를 먼저 둔다.** 테스트는 수십 ms, 이미지 빌드는 수 분이다.
테스트가 깨지면 이미지를 만들지 않는다.

## 게이트가 실제로 막는다

이 단계의 실질이다. 통과 이력만으로는 게이트를 증명하지 못한다.
테스트 하나를 일부러 틀리게 고쳐 `main` 에 올렸다.

```csharp
// order.TotalPrice.Should().Be(2200);
   order.TotalPrice.Should().Be(9999);
```

결과:

```
success  이미지 태그 결정
failure  단위 테스트          ← 통과 32 / 전체 33, 실패 1
skipped  정적분석
skipped  이미지 빌드
skipped  Harbor 푸시
skipped  취약점 스캔 확인
skipped  매니페스트 갱신
```

확인한 것은 세 가지다.

| 확인 | 결과 |
|---|---|
| 이후 단계가 전부 건너뛰어졌는가 | 5단계 skipped |
| 실패한 커밋의 이미지가 Harbor 에 올라갔는가 | **없음** (`dcc5d2da7110` 태그 부재) |
| 매니페스트가 실패 커밋을 가리키는가 | 아니오 (직전 성공분 유지) |

되돌린 뒤 같은 파이프라인이 6단계 전부 통과했다.

**실패가 배포로 이어지지 않는다는 것**은 파이프라인이 도는 것과 별개의 사실이고,
따로 확인하지 않으면 알 수 없다.

## 단위 테스트

인프라가 필요 없는 순수 로직만 다룬다.
서비스 간 통신은 `scripts/12-verify-eshop.sh` 가 배포 후에 확인한다.

| 프로젝트 | 개수 | 대상 |
|---|---|---|
| `Ordering.Domain.Tests` | 24 | 값 객체 생성 규칙, `Order` 집계 불변식, 총액 계산, 도메인 이벤트 |
| `Catalog.API.Tests` | 9 | 상품 생성 명령의 검증 규칙 |

`Ordering.Domain` 을 고른 이유는 이 계층이 결제로 이어지는 값을 다루기 때문이다.
`Order.Add` 가 수량·가격 0 이하를 거부하는지, `TotalPrice` 가 맞게 계산되는지 같은 것들은
잘못된 상태가 저장된 뒤에는 되돌리기 어렵다.

커버리지 임계값은 두지 않았다. 테스트가 이제 막 생긴 시점에 숫자를 먼저 정하면
형식만 남는다.

## 정적분석

`dotnet-sonarscanner` 로 분석하고 `sonar.qualitygate.wait` 로 판정이 나올 때까지 기다린다.

현재 측정치:

```
코드 라인 3024   버그 0   취약점 16   코드 스멜 72
```

품질 게이트는 기본 프로파일(Sonar way)을 쓴다.
신규 코드 기준으로 판정하므로 기존 코드의 누적치는 게이트를 막지 않는다.

### 호스트 빌드를 한 번 더 돌린다

스캐너는 `begin → build → end` 로 빌드를 감싸야 한다.
컴파일 과정을 가로채 분석 데이터를 모으는 구조라 그 사이의 빌드가 필요하다.

이미지 빌드(`ci-build.sh`)는 Docker 안에서 일어나 이 감싸기가 통하지 않는다.
그래서 `ci-analyze.sh` 가 호스트에서 `dotnet build` 를 한 번 더 돌린다.

중복이지만 대안이 더 비싸다. Docker 안에 스캐너를 넣으면
이미지에 분석 도구가 섞이고 레이어 캐시가 매번 깨진다.

### 토큰이 없으면 건너뛴다

분석 서버는 로컬 클러스터에만 있다.
다른 환경에서 이 스크립트를 돌릴 때 토큰이 없다고 파이프라인을 세우는 것은 과하다.
다만 조용히 넘어가지 않도록 경고는 남긴다.

## Harbor 스캔을 CI 단계로 당겼다

Phase 4에서 겪은 문제를 고쳤다.
`shopping-web` 의 CVE 가 **빌드·푸시·매니페스트 갱신이 모두 성공하고 ArgoCD 가 동기화한 뒤**
파드가 `ImagePullBackOff` 로 뜨지 못하는 형태로 알려졌다.
containerd 는 `412 Precondition Failed` 만 남겨 원인을 알기 어려웠다.

`ci-scan.sh` 가 푸시 직후 Trivy 스캔 완료를 기다리고 판정한다.

**허용목록을 Harbor 에서 직접 읽는다.**
스크립트에 복사해두면 Harbor 쪽 설정과 조용히 어긋나,
CI 는 통과시켰는데 배포에서 막히거나 그 반대가 된다.

`reuse_sys_cve_allowlist` 가 `true` 면 Harbor 가 프로젝트 허용목록이 아니라
시스템 전역 목록을 보므로, 그 경우 경고를 남긴다.
Phase 3에서 이 설정 때문에 허용목록이 조용히 무시됐던 적이 있다.

차단 동작도 확인했다. 허용목록에서 `CVE-2023-45853` 을 임시로 빼자
`ci-scan.sh` 가 해당 CVE 와 패키지(`zlib1g`)를 지목하고 종료 코드 1 로 멈췄다.

## 막혔던 지점

세 번의 실패를 거쳐 파이프라인이 완성됐다. 모두 러너 환경의 문제였다.

### 1. 러너 PATH 에 .NET SDK 가 없었다

```
✗ dotnet SDK 가 필요하다.
```

러너는 로그인 셸이 아닌 환경에서 돌아 PATH 가 최소 상태다.
macOS 의 .NET SDK 는 `/usr/local/share/dotnet` 에 설치되면서
`/usr/local/bin` 에 링크를 만들지 않는다.

```
$ command -v dotnet
/usr/local/share/dotnet/dotnet     ← 링크 없이 여기에만 있다
```

워크플로 `env.PATH` 에 경로를 넣고 `DOTNET_ROOT` 를 설정해 해결했다.

**게이트 자체는 이때도 의도대로 동작했다.**
첫 단계가 실패하자 이후가 전부 건너뛰어졌고 Harbor 에 아무것도 올라가지 않았다.
실패 이유는 의도한 것이 아니었지만 차단 경로는 그대로 확인됐다.

### 2. 토큰 재발급이 CI 시크릿을 죽였다

정적분석이 이 한 줄만 남기고 멈췄다.

```
Pre-processing failed. Exit code: 1
```

`begin` 출력을 `>/dev/null` 로 버리고 있어 원인을 알 수 없었다.

실제 원인은 **토큰 만료**였다.
`50-install-sonarqube.sh` 는 토큰을 발급할 때 같은 이름의 기존 토큰을 revoke 한다.
SonarQube 가 토큰 값을 생성 시점에만 돌려주고 이후 조회할 수 없어 다른 방법이 없다.

로컬에서 `ci-analyze.sh` 를 시험하려고 `token` 을 두 번 호출하는 사이
GitHub 시크릿에 저장돼 있던 토큰이 죽었다.

두 곳을 고쳤다.

- `50-install-sonarqube.sh` — 발급과 동시에 `gh secret set` 으로 시크릿을 갱신한다
- `ci-analyze.sh` — `begin` 출력을 파일에 남기고 실패 시 마지막 30줄을 보여준다.
  인증 오류일 때 어디서 재발급하는지도 안내한다

**출력을 버리면 실패를 진단할 수 없다.**
성공 경로만 보고 만든 스크립트에서 반복해서 나오는 문제다.

### 3. SonarQube 차트가 values 를 거부했다

두 번 연속 설치가 막혔다.

```
Please provide a passcode either setting "monitoringPasscode" ...
'community' is not a valid edition. ... set 'community.enabled=true' instead
```

`monitoringPasscode` 는 쓰지 않아도 비워둘 수 없고,
Community Build 는 `edition` 이 아니라 `community.enabled` 로만 지정해야 한다.
차트의 `validation.yaml` 이 설치 전에 검사한다.

## 산출물

| 저장소 | 파일 | 역할 |
|---|---|---|
| 앱 | `src/Tests/Ordering.Domain.Tests/` | 값 객체·집계 테스트 24개 |
| 앱 | `src/Tests/Catalog.API.Tests/` | 검증기 테스트 9개 |
| 앱 | `scripts/ci-test.sh` | 단위 테스트 실행 및 집계 |
| 앱 | `scripts/ci-analyze.sh` | SonarQube 분석 및 품질 게이트 확인 |
| 앱 | `scripts/ci-scan.sh` | Harbor 스캔 결과 판정 |
| 앱 | `.github/workflows/ci.yml` | 6단계 파이프라인 |
| 이 저장소 | `infra/sonarqube/values.yaml` | SonarQube Helm values |
| 이 저장소 | `scripts/50-install-sonarqube.sh` | 설치·프로젝트 생성·토큰 발급 |
| 이 저장소 | `scripts/51-verify-gates.sh` | 완료 조건 자동 검증 |

## 검증 결과

```
▶ 조건 1 — SonarQube
  ✓ PASS  서버 UP
  ✓ PASS  파드 1개 Running·Ready

▶ 조건 2 — 파이프라인 단계
  ✓ PASS  6단계 전부 성공 (2a960c41e21e)

▶ 조건 3 — 실패 시 차단 (이 단계의 실질)
  ✓ PASS  '단위 테스트' 실패 → 이후 5단계 건너뜀 (dcc5d2da7110)
  ✓ PASS  실패한 커밋의 이미지가 Harbor 에 없다

▶ 조건 4 — 매니페스트 무결성
  ✓ PASS  매니페스트 태그 2a960c41e21e — 실패 커밋이 아니다

▶ 조건 5 — 품질 게이트 판정
  ✓ PASS  품질 게이트 OK
          버그 0  코드 스멜 72  코드 라인 3024  취약점 16

▶ 조건 6 — 배포된 애플리케이션
  ✓ PASS  CI 전 구간 검증 통과

  통과 8 · 실패 0
```

`51-verify-gates.sh` 는 **실패 이력을 근거로** 조건 3을 판정한다.
현재 상태만 봐서는 게이트가 있는지 알 수 없기 때문이다.

## 남은 것

**커버리지 측정.** 테스트는 생겼지만 얼마나 덮고 있는지는 모른다.
`coverlet` 으로 수집해 SonarQube 에 보내면 게이트 조건으로 쓸 수 있다.

**High 등급 취약점 16건.** SonarQube 가 보고하는 수치이며 Harbor 의 CVE 와는 다른 축이다
(코드 패턴 기반). #16 의 패키지 취약점과 함께 볼 항목이다.

**Polaris 매니페스트 검증.** 아키텍처 문서 6p·7p 에 있는 도구다.
컨테이너 이미지가 아니라 Kubernetes 매니페스트를 검사한다.
Phase 7 파트너 격리와 함께 보는 편이 맞다.

## 다음 단계

Phase 6 — 폐쇄망 시뮬레이션.
**PoC 검증 목표 4번**이 남아 있고, 지금까지 만든 것 중 외부 인터넷에 의존하는 부분이
전부 드러나는 단계다. 베이스 이미지, NuGet 패키지, Trivy 취약점 DB, Helm 차트가 모두 대상이다.
