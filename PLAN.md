# ERP DevOps — Kubernetes CI/CD PoC 계획

출처: `erp-devops-architecture_3.pptx` (18p) — 특히 6p(CI/CD 흐름), 9p(파트너 배포), 10p(폐쇄망), 12p(라이선스 감사), 17p(로드맵)

## 0. 목표 정의

이 PoC로 **증명해야 할 것**과 **증명 안 해도 되는 것**을 먼저 가른다.

증명 대상 (PoC 성공 기준):
1. Git에 커밋 → 이미지 빌드 → 레지스트리 푸시 → ArgoCD가 자동 감지 → K8s 반영 (사람 손 안 탐)
2. `selfHeal: true` — 클러스터를 수동으로 망가뜨려도 Git 상태로 자동 복구 (6p 핵심 주장)
3. 이미지 취약점 스캔이 파이프라인을 실제로 막는가 (Harbor/Trivy)
4. 폐쇄망: 인터넷 전혀 없이 export한 이미지 tar만으로 배포가 되는가 (10p)
5. 파트너사 격리: 네임스페이스/레지스트리 프로젝트/RBAC로 A사가 B사 것을 못 보는가 (9p)

증명 제외 (PoC 범위 밖 — 나중에):
- Istio 서비스 메시, 분산 추적, OpenSearch 로깅 스택 → 무겁고 CI/CD 검증과 독립적
- 실제 ERP 비즈니스 로직, DB, 500명 부하 → 사이징(8p)은 실측 단계의 일
- sLLM/ProStudio 연계(13·14p) → 파이프라인이 돌아간 뒤에 얹는 것

## 1. 단계별 도입 (각 단계가 독립적으로 "동작하는 상태"로 끝남)

### Phase 0 — 로컬 클러스터 (반나절)
- `kind` 설치, 3노드 클러스터(control-plane 1 + worker 2). Docker Desktop 내장 K8s보다 kind 권장:
  멀티노드 가능, 언제든 `kind delete cluster`로 초기화, ingress/registry 설정을 코드로 남길 수 있음.
- `helm` 설치, ingress-nginx 배포, `*.localtest.me` 로 접근 확인.
- 산출물: `infra/kind-cluster.yaml`, `scripts/00-bootstrap.sh`
- **완료 조건**: `kubectl get nodes` 3개 Ready, 브라우저에서 샘플 nginx 접속

### Phase 1 — EShopMicroservices Helm 차트화 (2~3일)
대상 앱 확정: `EShopMicroservices-main` (.NET 8, MassTransit 8.1.3 + RabbitMQ + YARP).
샘플앱을 새로 만들 필요 없음 — 이미 PPT 4p/15p/16p 구성과 거의 일치한다.

컨테이너 11개:
- 앱 6개: `catalog.api` `basket.api` `discount.grpc` `ordering.api` `yarpapigateway` `shopping.web` (Dockerfile 멀티스테이지 기존재)
- 인프라 5개: `catalogdb`/`basketdb`(postgres:17) `distributedcache`(redis) `orderdb`(mssql) `messagebroker`(rabbitmq)

작업:
- 공통 라이브러리 차트 1개 + 서비스별 values 6개 (Deployment/Service/Ingress/HPA)
- `docker-compose.override.yml`의 environment를 ConfigMap/Secret으로 이관
- health probe: `/health`는 catalog·basket·ordering에만 있음 → yarp·discount·shopping.web에 추가
- 인프라 5종은 Bitnami 차트 또는 StatefulSet, PVC 연결
- **완료 조건**: `helm upgrade --install` 로 11개 파드 Ready, shopping.web에서 상품 조회→장바구니→주문 플로우 성공

### Phase 1 리스크 (착수 전 결정 필요)

**R1. SQL Server에 arm64 이미지가 없다 — 최우선 블로커**
`mcr.microsoft.com/mssql/server:2022-latest`는 amd64 단일 manifest다. Docker Desktop에서는 Rosetta로 돌지만, kind 노드 안의 containerd에는 에뮬레이션이 없어 `exec format error`가 난다. 선택지:
- (A) `orderdb`만 클러스터 밖 Docker에 두고 Ordering.API가 `host.docker.internal`로 접속 — 가장 빠름, Phase 0~5는 이걸로 충분
- (B) Ordering을 PostgreSQL로 교체 — EF provider 교체 + 마이그레이션 재생성. **12p 라이선스 감사 관점에서 SQL Server는 이 스택에서 운영 라이선스 비용이 붙는 유일한 컴포넌트**라 어차피 논의 대상
- (C) `azure-sql-edge`(arm64) — 지원 종료라 비추천

**R2. 테스트 프로젝트가 0개**
Phase 4의 "테스트 실패 시 파이프라인 중단"을 증명할 대상이 없다. Catalog.API에 단위 테스트 최소 1개 추가 필요.

**R3. Discount.Grpc가 SQLite 파일 DB** (`Data Source=discountdb`)
파드 재시작 시 데이터 소실. PVC 연결하거나 PoC 범위에서 감수.

**R4. .NET 8 (문서는 .NET Core 10)**
11개 csproj 전부 `net8.0`. CI/CD 파이프라인 검증에는 영향 없음 — 나중에 TFM만 올리면 된다.

**R5. 평문 자격증명** (`postgres/postgres`, `SA_PASSWORD=SwN12345678`)
문제가 아니라 기회다 — Phase 8 OpenBao / External Secrets 데모의 소재로 그대로 쓴다.

### Phase 2 — GitOps (ArgoCD) ★ 가장 먼저 값어치가 나오는 구간
- ArgoCD 설치 → Application CR로 `gitops` 레포의 `envs/dev` 를 감시.
- **레포 2개로 분리**: `erp-app`(소스) / `erp-gitops`(매니페스트·values). 6p의 "GitLab → ArgoCD Pull" 구조가 이 분리에서 나온다.
- `syncPolicy.automated.selfHeal: true`, `prune: true` 설정.
- **검증 시나리오**: `kubectl scale deploy --replicas=5` 로 강제 변경 → 3분 내 Git 상태(replicas=2)로 자동 복구되는지 확인. 이게 PoC 목표 2번.
- **완료 조건**: gitops 레포의 image tag 한 줄만 바꾸면 배포됨

### Phase 3 — 레지스트리 (Harbor) (하루)
- 처음엔 `registry:2` 로 시작해도 되지만, 어차피 Harbor여야 하는 이유가 3개라 바로 Harbor 권장:
  프로젝트 단위 격리(파트너사별), Trivy 취약점 스캔 내장, 레플리케이션(폐쇄망 반출입).
- Helm으로 Harbor 설치, 프로젝트 `erp-hq` / `partner-a` / `partner-b` 생성, robot account 발급.
- 스캔 정책: `Prevent vulnerable images from running` (Critical 이상 차단) 켜고 일부러 취약한 베이스 이미지로 막히는지 확인 → PoC 목표 3번.
- **완료 조건**: 취약 이미지 pull이 실제로 거부됨

### Phase 4 — CI (빌드·테스트·푸시) (하루~이틀)
- 여기서 GitHub / GitLab / Jenkins 선택이 갈린다 (§2 참조).
- **핵심 설계 원칙: CI 로직을 YAML에 쓰지 말고 `scripts/ci-*.sh` 로 빼라.**
  GitHub Actions → Jenkinsfile → .gitlab-ci.yml 전환이 래퍼 10줄 교체로 끝난다.
  이 PoC의 최종 목적지는 GitLab+Jenkins인데 시작은 GitHub이 편하므로, 이 원칙이 비용을 결정한다.
- 파이프라인: `build → test → docker build → harbor push → gitops repo의 tag 커밋(=배포 트리거)`
- **완료 조건**: `git push` 한 번으로 클러스터에 반영 (PoC 목표 1번)

### Phase 5 — 품질/보안 게이트 (하루)
- SonarQube(Community) 정적분석, Polaris로 매니페스트 검증(admission 또는 CI 단계).
- 실패 시 파이프라인 중단 확인.

### Phase 6 — 폐쇄망 시뮬레이션 (하루) ★ 이 아키텍처의 진짜 난이도
- 클러스터 2개: `kind-online`(개발계) / `kind-airgap`(운영계). airgap 쪽은 외부 이미지 pull 전면 차단.
- `scripts/export-images.sh` / `import-images.sh` — 이미지 tar + Helm 차트 + ArgoCD 설정 묶음 반출입.
- **여기서 반드시 터지는 것들** (미리 알고 시작할 것):
  - `mcr.microsoft.com`(.NET 베이스 이미지), `nuget.org` 패키지 → 사전 미러링 필요(Nexus/Harbor proxy cache)
  - Helm 차트가 참조하는 서브차트/의존 이미지 (Harbor 자체도 이미지 십수 개)
  - ArgoCD가 Git을 못 당기는 구간 → 내부 GitLab 필수 (§2에서 GitHub이 탈락하는 지점)
- **완료 조건**: 인터넷 끊긴 클러스터에 USB 시뮬레이션(tar 파일)만으로 배포 성공

### Phase 7 — 파트너 격리 & 멀티테넌시 (하루)
- 네임스페이스 분리 + NetworkPolicy + RBAC, ArgoCD Project/AppProject로 파트너별 권한 제한.
- Harbor 프로젝트 격리와 robot account 권한 검증.

### Phase 8 이후 (선택)
관측성 스택(Prometheus/OpenSearch), Keycloak SSO, OpenBao 시크릿, Velero 백업, Istio.
→ CI/CD가 완전히 돈 다음에. 각각 독립 PoC로 쪼갤 것.

## 2. GitLab vs 개인 GitHub — 무엇이 실제로 다른가

결론부터: **PoC Phase 1~5는 개인 GitHub으로 해도 아무 차이 없다. Phase 6(폐쇄망)에서 GitHub은 구조적으로 탈락한다.**

| 항목 | 개인 GitHub | GitLab CE (self-hosted) | 영향 |
|---|---|---|---|
| ArgoCD가 레포 감시 | 동일 (HTTPS+PAT / SSH deploy key) | 동일 | 차이 없음 |
| CI 러너 위치 | GitHub 호스티드 러너는 **인터넷 밖에 있음** → 로컬 kind 클러스터·로컬 Harbor에 접근 불가 | 로컬 러너가 같은 네트워크 | **Phase 4에서 self-hosted runner 필요** (무료) |
| webhook | github.com이 내 로컬 ArgoCD를 못 부름 → ArgoCD 폴링(기본 3분)에 의존 | 로컬끼리 webhook 즉시 동작 | PoC 수준에선 폴링으로 충분 |
| 폐쇄망 | **불가능.** github.com은 self-host 안 됨. GitHub Enterprise Server는 유료(고가) | CE 무료로 망 안에 설치 | **10p 요건 = GitLab 확정** |
| 15개 파트너 권한 분리 | 개인 계정은 조직/팀 기능 사실상 없음 (Org 필요) | 그룹/서브그룹으로 세분화 (9p 명시) | 실제 운영은 GitLab |
| 컨테이너 레지스트리 | GHCR (public 무료) | 내장 레지스트리 | 어차피 Harbor로 대체 |

### 권장 전략
1. **Phase 1~5는 개인 GitHub**에서 진행 — 계정 준비 0분, Actions로 빠르게 검증. 단 self-hosted runner를 로컬에 띄워야 로컬 Harbor/kind에 붙는다 (무료, `~/actions-runner` 하나면 끝).
2. **Phase 4부터 CI 로직은 전부 `scripts/`에** — YAML은 얇은 래퍼만.
3. **Phase 6 진입 시 로컬에 GitLab CE 컨테이너를 띄워** 레포를 미러링하고 폐쇄망 검증. 이때 Jenkins도 함께 올려 6p 원본 구성을 재현.
4. 9p 각주대로 **Jenkins를 빼고 GitLab CI로 단일화하는 안**도 Phase 6에서 같이 비교 측정할 것 — 파트너사 15곳에 Jenkins까지 설치·운영시키는 건 상당한 부담이다.

주의: GitLab CE 자체가 메모리를 4~8GB 먹는다. 64GB 머신이라 동시 구동은 가능하지만, Phase 6는 다른 스택을 내리고 진행하는 게 안전하다.

## 3. 비용 — Jenkins / Harbor / ArgoCD

**세 개 모두 완전 무료다. 라이선스 비용 0원, 파트너사 재배포도 자유.**

| 도구 | 라이선스 | 비용 | 유료 버전(선택) |
|---|---|---|---|
| Jenkins | MIT | 무료, 무제한 | CloudBees CI (안 써도 됨) |
| Harbor | Apache 2.0 (CNCF Graduated) | 무료, 무제한 | 없음 (벤더 지원 계약만) |
| ArgoCD | Apache 2.0 (CNCF Graduated) | 무료, 무제한 | Akuity / Codefresh 관리형 (안 써도 됨) |

12p 감사 결과와 일치한다 — 이 셋은 "문제없음 — 재배포 자유" 칸에 있다.

### 실제로 돈이 나가는 지점 (도구 라이선스가 아니라 다른 데서 나온다)

1. **Docker Desktop** — 직원 250명↑ 또는 매출 $10M↑ 기업은 유료(12p 명시). 개인 PoC는 무료.
   회사 차원에선 Rancher Desktop / colima / podman 으로 회피 가능. **PoC 단계에서 이 결정을 미리 검증해두면 나중에 전면 교체를 피한다.**
2. **Docker Hub pull rate limit** — CI에서 반복 빌드하면 금방 걸린다. Harbor proxy cache로 우회(무료). 안 하면 유료 플랜 압박.
3. **Grafana AGPLv3** — 내부 사용은 무료, 15개 파트너사에 재배포하는 형태가 문제(12p "조건부"). 대안은 Perses 또는 파트너사가 직접 설치.
4. **SonarQube** — Community Build 무료지만 브랜치 분석·PR 데코레이션 없음. 필요하면 Developer Edition 유료. 12p대로 내부 CI 전용이면 무료로 충분.
5. **GitHub 무료 한도** — public 레포 Actions 무제한, private는 월 2,000분. **self-hosted runner는 분 소모 0** → 로컬 러너 쓰면 사실상 무료.
6. **GitLab** — self-hosted CE 무료·무제한. gitlab.com SaaS 무료 티어는 CI 분 제한 있음. Ultimate(컨테이너 스캔·SAST 풀셋)는 유저당 유료 → **그래서 이 아키텍처가 Harbor+SonarQube 조합을 쓰는 것**이고, 그게 비용 관점에선 정답이다.
7. **진짜 비용은 인프라** — 8p 사이징(운영 24Core/96GB + 개발계)의 VM/노드 비용, 그리고 14p sLLM용 GPU 노드풀. 도구값보다 두 자릿수 크다.

> 위 가격/한도 조건은 2026년 5월 기준 정보다. 실제 계약 전에 각 벤더 현재 약관을 재확인할 것.

## 4. 먼저 결정해야 할 것

- [ ] Phase 1 샘플 앱을 .NET Core 10으로 갈지, 더 가벼운 것으로 대체할지 (실제 ERP 이미지 크기·빌드 시간 감을 잡으려면 .NET 권장)
- [ ] Phase 4 CI를 GitHub Actions로 시작할지, 처음부터 로컬 Jenkins로 갈지
- [ ] 폐쇄망(Phase 6)을 이번 PoC 범위에 넣을지 — 넣으면 이 PoC의 가치가 크게 오르지만 기간이 2배
