# Kubernetes DevOps PoC

ERP 클라우드 네이티브 아키텍처 문서(`erp-devops-architecture.pptx`)에 정의된 **Kubernetes 기반 CI/CD 환경**을 실제로 구축·검증하는 PoC 저장소다.

`GitLab/GitHub → Jenkins → Harbor → ArgoCD → Kubernetes` 파이프라인이 실제로 동작하는지, 그리고 폐쇄망(망분리) 환경에서도 성립하는지를 단계적으로 증명하는 것이 목표다.

---

## 문서

| 문서 | 내용 |
|---|---|
| [PLAN.md](PLAN.md) | **전체 PoC 계획** — 목표 정의, Phase 0~8 단계별 도입, GitLab vs GitHub 비교, 도구 비용 분석 |
| [001-repo-bootstrap.md](docs/001-repo-bootstrap.md) | 저장소 구조 결정 근거, 작업 규칙 |
| [002-phase0-kind-cluster.md](docs/002-phase0-kind-cluster.md) | Phase 0 — kind 클러스터 구성 결정과 검증 결과 |
| [003-phase1-helm-charts.md](docs/003-phase1-helm-charts.md) | Phase 1 — Helm 차트화, Compose 대비 변경점, SQL Server arm64 실측 |
| [004-phase2-argocd-gitops.md](docs/004-phase2-argocd-gitops.md) | Phase 2 — ArgoCD GitOps, selfHeal·prune 실측, 자원 추적 방식 |
| [005-phase3-harbor-registry.md](docs/005-phase3-harbor-registry.md) | Phase 3 — Harbor, 취약점 게이트 실증, containerd 레지스트리 신뢰 |
| [006-phase4-ci-pipeline.md](docs/006-phase4-ci-pipeline.md) | Phase 4 — CI 파이프라인, 캐시된 이미지가 게이트를 거치지 않는 문제 |
| [007-app-repo-cleanup.md](docs/007-app-repo-cleanup.md) | 앱 저장소 정리 — Critical CVE 해소, health 엔드포인트, CI 재시도 |

## 빠른 시작

```bash
./scripts/00-bootstrap.sh      # kind 클러스터 + ingress-nginx 구축
./scripts/01-verify.sh         # 클러스터 검증

./scripts/10-build-images.sh   # 앱 이미지 6개 빌드 후 클러스터 주입
./scripts/11-deploy-eshop.sh   # EShopMicroservices 배포
./scripts/12-verify-eshop.sh   # 주문 플로우까지 검증

./scripts/20-install-argocd.sh # ArgoCD 설치 + GitOps 전환
./scripts/21-verify-gitops.sh  # selfHeal · prune 검증

./scripts/30-install-harbor.sh # Harbor 설치 + 취약점 게이트 설정
./scripts/31-push-images.sh    # 이미지를 Harbor 로 푸시
./scripts/32-verify-harbor.sh  # 스캔 차단 · 파트너 격리 검증

./scripts/40-setup-runner.sh   # CI 러너 설치·등록 (status/stop/remove)
./scripts/41-verify-ci.sh      # 커밋 → 배포 전 구간 검증

./scripts/99-teardown.sh       # 클러스터 삭제
```

> ArgoCD 도입 이후에는 `kubectl` · `helm` 으로 클러스터를 직접 고치지 않는다.
> `envs/dev/values.yaml` 을 커밋하면 반영되고, 직접 고친 것은 약 4초 뒤 되돌아온다.

배포 후 접속:

| 주소 | 내용 |
|---|---|
| http://eshop.localtest.me | 쇼핑몰 화면 |
| http://api.eshop.localtest.me/catalog-service/products | API 게이트웨이 |
| http://argocd.localtest.me | ArgoCD UI (`admin` / 설치 스크립트가 출력) |
| http://harbor.localtest.me | Harbor UI (`admin` / `Harbor12345`) |

필요 도구: `docker` `kind` `kubectl` `helm` — `brew install kind helm`

애플리케이션 소스는 별도 저장소다. 기본 경로는 `EShopMicroservices-main/`이며
`ESHOP_SRC` 환경변수로 바꿀 수 있다.

## 관련 저장소

| 저장소 | 역할 |
|---|---|
| **Kubernetes_devOps_Poc** (현재) | 인프라 · GitOps 매니페스트 · Helm 차트 · 문서 |
| [net8_Microservices](https://github.com/sunm2n/net8_Microservices) | 애플리케이션 소스 (EShopMicroservices, .NET 8) |

> 두 저장소를 분리한 것은 PLAN.md Phase 2의 GitOps 원칙(앱 레포 / 매니페스트 레포 분리)을 따른 것이다.
> 애플리케이션 소스는 이 저장소에 포함되지 않으며, `.gitignore`로 제외되어 있다.

---

## PoC 검증 목표

| # | 검증 항목 | 상태 |
|---|---|---|
| 1 | 커밋 → 빌드 → 레지스트리 푸시 → ArgoCD 자동 배포 (무인) | **달성** — 커밋 하나로 약 4분 ([006](docs/006-phase4-ci-pipeline.md)) |
| 2 | `selfHeal: true` — 클러스터 수동 변경분 자동 복구 | **달성** — 약 4초 만에 복구 ([004](docs/004-phase2-argocd-gitops.md)) |
| 3 | 이미지 취약점 스캔이 파이프라인을 실제로 차단 | **달성** — Critical 검출 시 pull 거부 ([005](docs/005-phase3-harbor-registry.md)) |
| 4 | 인터넷 없이 반입 이미지만으로 배포 (폐쇄망) | 미착수 |
| 5 | 파트너사별 네임스페이스 · 레지스트리 · RBAC 격리 | 미착수 |

---

## 진행 상황

| Phase | 내용 | 이슈 | PR | 문서 | 상태 |
|---|---|---|---|---|---|
| — | 저장소 초기 구성 | — | — | [001](docs/001-repo-bootstrap.md) | 완료 |
| — | 앱 저장소 정리 (CVE·health·CI) | [#5](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/5) [#11](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/11) [#14](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/14) | [#17](https://github.com/sunm2n/Kubernetes_devOps_Poc/pull/17) | [007](docs/007-app-repo-cleanup.md) | 완료 |
| 0 | 로컬 kind 클러스터 | [#1](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/1) | [#3](https://github.com/sunm2n/Kubernetes_devOps_Poc/pull/3) | [002](docs/002-phase0-kind-cluster.md) | 완료 |
| 1 | EShopMicroservices Helm 차트화 | [#4](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/4) | [#6](https://github.com/sunm2n/Kubernetes_devOps_Poc/pull/6) | [003](docs/003-phase1-helm-charts.md) | 완료 |
| 2 | ArgoCD GitOps | [#7](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/7) | [#8](https://github.com/sunm2n/Kubernetes_devOps_Poc/pull/8) | [004](docs/004-phase2-argocd-gitops.md) | 완료 |
| 3 | Harbor 레지스트리 | [#10](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/10) | [#12](https://github.com/sunm2n/Kubernetes_devOps_Poc/pull/12) | [005](docs/005-phase3-harbor-registry.md) | 완료 |
| 4 | CI (빌드·테스트·푸시) | [#13](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/13) | [#15](https://github.com/sunm2n/Kubernetes_devOps_Poc/pull/15) | [006](docs/006-phase4-ci-pipeline.md) | 골격 완료 |
| 5 | 품질/보안 게이트 | | | | 대기 |
| 6 | 폐쇄망 시뮬레이션 | | | | 대기 |
| 7 | 파트너 격리 · 멀티테넌시 | | | | 대기 |

### 미해결 항목

| 이슈 | 내용 | 영향 |
|---|---|---|
| [#16](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/16) | High 등급 취약 패키지 다수 — 대부분 전이 의존성 | Harbor 게이트는 Critical 만 차단해 배포에는 지장 없음. Phase 5 이후 권장 |

---

## 작업 방식

모든 작업은 아래 사이클을 한 단위로 진행한다.

```
이슈 생성 → 작업 브랜치 생성 → 작업 → 테스트 → PR 작성 → dev 머지
                                                    └ 큰 문제 발견 시 후속 이슈 생성
```

- **브랜치**: `main`(안정) ← `dev`(통합) ← `feat/*` · `fix/*` · `docs/*`(작업)
- **작업 단위마다** `docs/NNN-*.md` 문서를 남기고 위 진행 상황 표에서 이슈·PR·문서로 연결한다.
- 각 Phase의 **완료 조건**은 PLAN.md에 정의되어 있으며, 이를 충족해야 dev에 머지한다.

## 환경

| 항목 | 값 |
|---|---|
| 개발 머신 | macOS (Apple Silicon, arm64) · 12 Core / 64 GB |
| 컨테이너 런타임 | Docker Desktop 4.85 (VM 메모리 24 GB 할당) |
| 클러스터 | kind · Kubernetes v1.36.1 · containerd 2.3.1 · 노드 3대 |
| 애플리케이션 | .NET 8 · MassTransit 8.1.3 · RabbitMQ · YARP |
| CI | GitHub Actions · self-hosted 러너 (로컬) |

> SQL Server 이미지는 arm64 빌드가 없어 Rosetta 변환으로 동작한다.
> 기능에는 문제가 없으나 성능 수치는 신뢰할 수 없다.
> 실측 근거는 [PLAN.md의 Phase 1 리스크](PLAN.md#phase-1-리스크) 참고.
