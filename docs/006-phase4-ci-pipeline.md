# 006. Phase 4 — CI 파이프라인 골격

이슈: [#13](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/13)
앱 저장소 PR: [net8_Microservices#1](https://github.com/sunm2n/net8_Microservices/pull/1)
작업일: 2026-08-13

## 결과 요약

앱 저장소에 커밋하면 빌드·푸시·매니페스트 갱신을 거쳐 클러스터에 반영되기까지
사람이 개입하지 않는다. **PoC 검증 목표 1번이 완성됐다.**

| 항목 | 값 |
|---|---|
| 러너 | self-hosted, `erp-poc-local` (macOS arm64) |
| 워크플로 실행 | 3분 22초 |
| 이미지 태그 | 커밋 해시 12자리 (`701fa042982c`) |
| 커밋 → 배포 | 약 4분 (빌드 3분 22초 + ArgoCD 폴링) |
| 검증 | 10개 항목 전부 통과 |

## 흐름

```
sunm2n/net8_Microservices  main 에 push
        │
        ▼  self-hosted 러너 (로컬 머신)
   ci-build.sh    이미지 6개 빌드, 태그 = 커밋 해시
   ci-push.sh     skopeo 로 Harbor(erp-hq) 푸시
   ci-deploy.sh   매니페스트 저장소의 imageTag 갱신 후 커밋
        │
        ▼  커밋
sunm2n/Kubernetes_devOps_Poc  dev / envs/dev/values.yaml
        │
        ▼  폴링 60초
   ArgoCD → 클러스터
```

**CI 는 배포하지 않는다.** `kubectl` 을 쓰지 않고 Git 커밋만 남긴다.
클러스터에 무엇이 떠 있는지는 언제나 Git 이 결정한다.

## 결정 사항

### CI 로직을 워크플로 YAML 이 아니라 셸 스크립트에

PLAN.md 에서 정한 원칙을 그대로 적용했다.
워크플로 파일은 `scripts/ci-*.sh` 를 순서대로 부르는 역할만 한다.

이 PoC 의 최종 목적지는 GitLab + Jenkins 다.
로직이 스크립트에 있으면 전환할 때 워크플로 파일만 갈아끼우면 되고,
로컬에서 그대로 실행해 볼 수도 있다.
실제로 세 스크립트 모두 워크플로에 올리기 전에 로컬에서 먼저 검증했다.

### 이미지 태그를 커밋 해시로

Phase 3까지는 `local` 고정이었다. 두 가지 문제가 있다.

1. 무엇이 배포됐는지 알 수 없다
2. `imagePullPolicy: IfNotPresent` 와 겹치면 노드가 캐시된 옛 이미지를 계속 쓴다

커밋 해시를 쓰면 배포된 이미지와 소스 커밋이 1:1로 대응하고,
태그가 매번 달라지므로 `IfNotPresent` 로도 항상 새 이미지를 받는다.

### self-hosted 러너

GitHub 호스티드 러너는 인터넷 밖에 있어 로컬 Harbor 와 kind 클러스터에 닿지 않는다.
PLAN.md 의 GitLab vs GitHub 비교에서 예상했던 제약이 그대로 나타났다.

로컬 러너는 무료이고 실행 시간 제한도 없다.
폐쇄망(Phase 6)에서는 어차피 이 형태가 된다.

`launchd` 서비스 대신 백그라운드 프로세스로 둔다.
PoC 범위에서 재부팅 후 자동 시작이 필요하지 않고, 서비스 등록은 권한 요구가 따라와 재현이 번거롭다.

### 매니페스트 저장소 자격증명 — 이 PoC 의 방식은 운영에서 통하지 않는다

워크플로의 기본 토큰(`GITHUB_TOKEN`)은 자기 저장소에만 유효해서
다른 저장소에 커밋할 수 없다. 별도의 자격증명이 필요하다.

지금은 러너가 로컬 사용자로 돌아 `gh auth token` 을 그대로 쓴다.
**러너 머신에 사람의 자격증명이 있다는 전제이며, 실제 환경에서는 성립하지 않는다.**
`scripts/ci-deploy.sh` 는 `GITOPS_TOKEN` 을 먼저 보고, 없을 때만 `gh` 로 넘어간다.
운영에서는 이 시크릿을 반드시 주입해야 한다.

토큰이 remote URL 에 남지 않도록 `http.extraheader` 로 전달한다.
URL 에 넣으면 `.git/config` 와 에러 메시지에 그대로 노출된다.

### 순환 실행은 구조상 생기지 않는다

CI 가 만든 커밋이 다시 CI 를 부르면 무한 반복이 된다.
이 구성에서는 CI 가 **다른 저장소**에 커밋하고, 워크플로는 앱 저장소의 push 에만 반응하므로 생기지 않는다.

앱 저장소와 매니페스트 저장소를 분리한 것(001·004 문서)이 여기서 값을 한다.
합쳐져 있었다면 `paths-ignore` 나 `[skip ci]` 같은 우회 장치가 필요했을 것이다.

## 검증 결과

```
▶ 조건 1 — self-hosted 러너
  ✓ PASS  erp-poc-local — online
  ✓ PASS  러너 프로세스 실행 중

▶ 조건 2 — 워크플로 실행 결과
  ✓ PASS  최근 실행 성공 (701fa042982c)

▶ 조건 3 — Harbor 에 커밋 해시 태그로 저장
  ✓ PASS  이미지 6개가 701fa042982c 태그로 저장됨

▶ 조건 4 — 매니페스트 저장소 자동 갱신
  ✓ PASS  envs/dev/values.yaml 의 imageTag = 701fa042982c
  ✓ PASS  마지막 변경 주체 = erp-poc-ci (사람이 아님)

▶ 조건 5 — 클러스터에 배포됨
  ✓ PASS  실행 중인 앱 파드 전부가 701fa042982c
  ✓ PASS  파드 11개 Running·Ready
  ✓ PASS  ArgoCD — Synced · Healthy

▶ 조건 6 — 주문 플로우
  ✓ PASS  주문 플로우 9개 항목 통과

  통과 10 · 실패 0
```

조건 4의 **"마지막 변경 주체가 사람이 아님"** 이 이 단계의 핵심이다.
매니페스트가 바뀐 것만으로는 부족하고, 그 커밋을 CI 가 만들었어야 한다.

## 막혔던 지점

### 1. 베이스 이미지 pull 이 간헐적으로 실패한다

첫 실행이 30초 만에 실패했다.

```
#2 ERROR: failed to do request:
   Head "https://mcr.microsoft.com/v2/dotnet/aspnet/manifests/8.0": EOF
```

코드 문제가 아니라 네트워크 문제였고 재실행으로 통과했다.
그러나 **CI 가 외부 레지스트리에 매번 의존한다는 사실은 남는다.**

Phase 6 폐쇄망에서는 이 의존 자체가 성립하지 않아 미러링이 필수가 된다.
그 전까지는 일시적 실패로 파이프라인이 멈출 수 있다.
재시도를 넣는 것이 맞다고 판단해 후속 이슈로 분리했다.

### 2. 취약점 게이트가 새 이미지 하나를 막았다

빌드·푸시는 성공했는데 `shopping-web` 파드만 `ImagePullBackOff` 에 빠졌다.

```
412 Precondition Failed
```

Phase 3에서 켠 취약점 차단 정책이 동작한 것이다.
`shopping-web` 에만 있는 `CVE-2024-51501`(**Refit**)이 허용목록에 없었다.

**Phase 3의 허용목록이 불완전했다.**
그때 `catalog-api` 하나만 조사해 CVE 6건을 등록했는데,
`shopping-web` 은 다른 의존성을 쓴다. 6개 이미지 전체를 보니 고유 Critical 은 7건이었다.

| CVE | 패키지 | 영향 이미지 | 성격 |
|---|---|---|---|
| CVE-2026-13221 · 42496 · 57433 · 8376 | perl-base | 6개 | 베이스 이미지 |
| CVE-2023-45853 | zlib1g | 6개 | 베이스 이미지 |
| CVE-2026-45288 | **Marten** | 2개 | 애플리케이션 의존성 |
| CVE-2024-51501 | **Refit** | 1개 | 애플리케이션 의존성 |

### 3. 캐시된 이미지는 게이트를 거치지 않는다

위 문제가 **Phase 3 검증에서는 드러나지 않았다.** 그때도 11개 파드가 전부 통과했다.

이유는 `shopping-web:local` 이 이미 노드에 캐시돼 있었기 때문이다.
Harbor 의 차단은 **pull 시점에만** 적용된다. 노드가 이미 가진 이미지는 다시 검사하지 않는다.

Phase 4에서 태그가 커밋 해시로 바뀌면서 처음으로 실제 pull 이 일어났고, 그때 걸렸다.

**운영에서 유의할 점이다.**
정책을 켠 뒤에도 이미 돌고 있는 파드는 그대로 살아 있고,
노드에 캐시가 남아 있는 한 재배포해도 걸리지 않는다.
정책이 실제로 적용되는지 확인하려면 새 태그로 pull 을 강제해야 한다.

고정 태그를 쓰면 이 사각지대가 계속 남는다는 점에서,
커밋 해시 태그로 바꾼 것은 보안 측면에서도 이득이 있었다.

## 산출물

| 저장소 | 파일 | 역할 |
|---|---|---|
| 앱 | `.github/workflows/ci.yml` | 워크플로 — 얇은 래퍼 |
| 앱 | `scripts/ci-build.sh` | 이미지 6개 빌드 |
| 앱 | `scripts/ci-push.sh` | Harbor 푸시 |
| 앱 | `scripts/ci-deploy.sh` | 매니페스트 저장소 갱신 |
| 이 저장소 | `scripts/40-setup-runner.sh` | 러너 설치·등록·중지·삭제 |
| 이 저장소 | `scripts/41-verify-ci.sh` | 완료 조건 자동 검증 |
| 이 저장소 | `scripts/30-install-harbor.sh` | CVE 허용목록에 Refit 추가 |

## 아직 비어 있는 것

워크플로에 **테스트와 정적분석 단계를 자리만 만들어 두었다.**

```yaml
- name: 테스트
  run: echo "테스트 프로젝트가 아직 없다 (PLAN.md R2)."
- name: 정적분석
  run: echo "SonarQube 는 Phase 5에서 붙인다."
```

파이프라인이 도는 것과 파이프라인이 **막아야 할 때 막는 것**은 다른 문제다.
Phase 5에서 다음을 채운다.

- 단위 테스트 추가 후 실패 시 파이프라인 중단 확인 (PLAN.md R2)
- SonarQube 정적분석
- Harbor 스캔 결과를 CI 단계에서 확인 — 지금은 배포 시점에야 걸린다

마지막 항목이 이번에 실제로 드러났다.
`shopping-web` 의 CVE 는 빌드·푸시가 다 끝난 뒤 파드가 뜨지 못하는 형태로 알려졌다.
CI 단계에서 스캔 결과를 확인했다면 더 일찍 멈출 수 있었다.

## 다음 단계

Phase 5 — 품질·보안 게이트.
이번에 만든 빈 자리를 채워, 파이프라인이 통과시키는 것뿐 아니라 막는 것도 하게 한다.
