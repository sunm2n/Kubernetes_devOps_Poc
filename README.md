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

## 빠른 시작

```bash
./scripts/00-bootstrap.sh   # kind 클러스터 + ingress-nginx 구축 (재실행 가능)
./scripts/01-verify.sh      # 완료 조건 자동 검증
./scripts/99-teardown.sh    # 클러스터 삭제
```

필요 도구: `docker` `kind` `kubectl` `helm` — `brew install kind helm`

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
| 1 | 커밋 → 빌드 → 레지스트리 푸시 → ArgoCD 자동 배포 (무인) | 미착수 |
| 2 | `selfHeal: true` — 클러스터 수동 변경분 자동 복구 | 미착수 |
| 3 | 이미지 취약점 스캔이 파이프라인을 실제로 차단 | 미착수 |
| 4 | 인터넷 없이 반입 이미지만으로 배포 (폐쇄망) | 미착수 |
| 5 | 파트너사별 네임스페이스 · 레지스트리 · RBAC 격리 | 미착수 |

---

## 진행 상황

| Phase | 내용 | 이슈 | PR | 문서 | 상태 |
|---|---|---|---|---|---|
| — | 저장소 초기 구성 | — | — | [001](docs/001-repo-bootstrap.md) | 완료 |
| 0 | 로컬 kind 클러스터 | [#1](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/1) | [#3](https://github.com/sunm2n/Kubernetes_devOps_Poc/pull/3) | [002](docs/002-phase0-kind-cluster.md) | 완료 |
| 1 | EShopMicroservices Helm 차트화 | | | | 대기 |
| 2 | ArgoCD GitOps | | | | 대기 |
| 3 | Harbor 레지스트리 | | | | 대기 |
| 4 | CI (빌드·테스트·푸시) | | | | 대기 |
| 5 | 품질/보안 게이트 | | | | 대기 |
| 6 | 폐쇄망 시뮬레이션 | | | | 대기 |
| 7 | 파트너 격리 · 멀티테넌시 | | | | 대기 |

### 미해결 항목

| 이슈 | 내용 | 영향 |
|---|---|---|
| [#2](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/2) | Docker Desktop 메모리가 8 GB로 제한됨 (호스트는 64 GB) | Phase 3에서 한계 도달, Phase 6는 불가 |

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
| 컨테이너 런타임 | Docker Desktop 29.6 |
| 애플리케이션 | .NET 8 · MassTransit 8.1.3 · RabbitMQ · YARP |

> arm64 환경 관련 제약(SQL Server 이미지 등)은 [PLAN.md의 Phase 1 리스크](PLAN.md#phase-1-리스크-착수-전-결정-필요) 참고.
