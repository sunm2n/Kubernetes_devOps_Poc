# 001. 저장소 초기 구성

작업일: 2026-08-13

## 목적

PoC를 시작하기 전에 저장소 구조와 작업 규칙을 확정한다. 기능 작업은 포함하지 않는다.

## 배경 — 저장소가 두 개인 이유

작업 시작 시점의 로컬 상태는 다음과 같았다.

- `Kubernetes_devOps_Poc/` — Git 저장소가 아님. `PLAN.md` 파일만 존재
- `Kubernetes_devOps_Poc/EShopMicroservices-main/` — **이미 독립된 Git 저장소**
  (`sunm2n/net8_Microservices`, 커밋 7개, `origin/main` 푸시 완료)
- 원격 `sunm2n/Kubernetes_devOps_Poc` — 커밋 0개의 빈 저장소

애플리케이션 소스가 이미 별도 저장소로 관리되고 있었으므로, 이를 통합하지 않고 분리 상태를 유지했다.

이 분리는 우연이지만 결과적으로 PLAN.md Phase 2의 GitOps 원칙과 정확히 일치한다.
ArgoCD는 매니페스트 저장소만 감시하고, 애플리케이션 빌드는 소스 저장소의 CI가 담당한다.
두 저장소를 합치면 소스 커밋마다 ArgoCD가 불필요하게 반응하게 되어 이 구조가 깨진다.

| 저장소 | 역할 | 감시 주체 |
|---|---|---|
| `net8_Microservices` | 애플리케이션 소스, Dockerfile | CI (빌드 트리거) |
| `Kubernetes_devOps_Poc` | Helm 차트, ArgoCD 매니페스트, 문서 | ArgoCD (배포 트리거) |

### 검토했으나 채택하지 않은 방안

**Git submodule로 연결** — 앱 저장소의 특정 커밋을 고정할 수 있어 재현성 면에서 유리하다.
다만 현 단계에서는 클론·CI마다 추가 절차가 붙는 비용이 이득보다 크다고 판단해 보류했다.
Phase 4(CI) 진입 시 빌드 재현성이 실제 문제로 드러나면 그때 재검토한다.

## 변경 사항

### 1. `.gitignore` 신규 작성

주요 제외 대상:

| 대상 | 이유 |
|---|---|
| `EShopMicroservices-main/` | 별도 저장소. 중첩 Git 저장소가 커밋되는 것을 방지 |
| `.DS_Store` 등 | macOS 생성 파일. 저장소 루트와 앱 디렉터리에 존재했음 |
| `*.key` `*.pem` `.env` `kubeconfig` `*-secret.yaml` | 자격증명 유출 방지. Harbor robot account, ArgoCD 토큰, DB 비밀번호를 다루게 되므로 사전 차단 |
| `charts/**/charts/` `*.tgz` `Chart.lock` | Helm 의존성 캐시. 재생성 가능 |
| `airgap/**/*.tar` `images/*.tar` | Phase 6 폐쇄망 반출입 이미지 번들. 수 GB 단위라 Git 부적합 |
| `bin/` `obj/` | .NET 빌드 산출물 |

### 2. `README.md` 신규 작성

문서·저장소·진행 상황을 한 곳에서 찾아갈 수 있는 인덱스 역할.
PoC 검증 목표 5개와 Phase 0~8 진행 표를 두고, 각 작업의 이슈·PR·문서를 여기서 연결한다.

### 3. `docs/` 디렉터리 신설

작업 단위마다 `NNN-작업명.md` 문서를 남긴다. 이 문서가 첫 번째다.

## 오타 · 결함 수정

### 수정함 — `docker-compose.yml` 1행 (`net8_Microservices` 저장소, 작업 트리)

```diff
-rversion: '3.4'
+version: '3.4'
```

`version` 앞에 `r`이 붙어 있었다. Compose v2는 알 수 없는 최상위 키를 거부하므로
`docker compose config`가 다음과 같이 실패하고, `docker compose up`도 동작하지 않는 상태였다.

```
validating .../docker-compose.yml: additional properties 'rversion' not allowed
```

**커밋된 내용은 원래 정상이었고, 오타는 커밋되지 않은 로컬 수정분이었다.**
(`git show HEAD:src/docker-compose.yml` 1행 = `version: '3.4'`)
따라서 이 수정으로 작업 트리가 HEAD와 다시 일치하게 되었을 뿐, 별도 커밋할 변경은 없다.
수정 후 11개 서비스가 정상 인식되는 것을 확인했다.

### 미결 — `.DS_Store`가 추적되고 있음 (`net8_Microservices` 저장소)

해당 저장소는 `.DS_Store`를 커밋에 포함하고 있고 `.gitignore`에도 제외 규칙이 없다.
다른 저장소의 이력을 건드리는 작업이라 이번 범위에서는 손대지 않았다.
정리하려면 `git rm --cached .DS_Store` + `.gitignore` 추가가 필요하다.

### 수정하지 않음 — 판단 근거

다음 항목들은 철자가 틀렸지만 의도적으로 두었다. 단순 오타가 아니라 동작에 영향을 주는 식별자다.

| 항목 | 위치 | 두는 이유 |
|---|---|---|
| `Extentions.cs` → `Extensions.cs` | `Discount.Grpc/Data/`, `Ordering.Infrastructure/Data/Extensions/` | 파일명 변경은 `.csproj`·`using`·Git 이력에 영향. 오타 수정이 아니라 리팩터링 |
| `OrderFullfilment` → `OrderFulfilment` | `Ordering.API` 설정 키 | `docker-compose.override.yml`의 `FeatureManagement__OrderFullfilment`와 문자열이 정확히 일치해야 동작. 한쪽만 고치면 기능 플래그가 조용히 꺼진다 |
| `docker-compose.override.yml`의 `version: '3.4'` | Compose 파일 | 오타는 아니고 v2에서 무시되는 사용 중단 키. 경고만 출력되며 동작에는 영향 없음 |

## 브랜치 전략

```
main   안정 — 각 Phase 완료 시점
  └ dev   통합 — 작업 PR의 머지 대상
      └ feat/* fix/* docs/*   작업 단위
```

## 후속 작업

- [ ] `net8_Microservices` 저장소에 `rversion` 수정 커밋
- [ ] Phase 0 — 로컬 kind 클러스터 구축 (PLAN.md 참고)
