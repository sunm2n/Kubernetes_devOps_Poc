# 004. Phase 2 — ArgoCD GitOps

이슈: [#7](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/7)
작업일: 2026-08-13

## 결과 요약

`helm upgrade --install` 로 직접 배포하던 것을 ArgoCD 가 Git 을 감시해 자동 동기화하는 구조로 바꿨다.
**PoC 검증 목표 2번(`selfHeal`)이 이 단계에서 증명됐다.**

| 항목 | 값 |
|---|---|
| ArgoCD | 차트 10.3.3 (v3.5.1) |
| Application | `eshop-dev` — Synced · Healthy |
| selfHeal 복구 시간 | **약 4초** |
| prune 제거 시간 | 약 4초 |
| Git 커밋 → 클러스터 반영 | 약 68초 (폴링 주기 60초) |
| 검증 | 6개 항목 전부 통과 |

## 구조 — 환경별 values 분리

```
charts/eshop/          차트 본체 — 환경과 무관한 구조
envs/
  dev/values.yaml      개발 환경 값 — 이미지 태그, 복제본 수
argocd/
  values.yaml          ArgoCD 자체 설치 값
  applications/
    eshop-dev.yaml     Application CR
```

차트를 직접 감시하지 않고 `envs/dev/` 를 둔 이유는 두 가지다.

1. **Phase 4** — CI 가 빌드한 이미지 태그를 커밋할 위치가 명확해진다.
   차트를 직접 감시하면 CI 가 차트 본체를 고치게 되어, 구조 변경과 태그 갱신이 한 파일에서 섞인다.
2. **Phase 7** — 파트너사별 환경은 `envs/partner-a/` 를 추가하는 것으로 끝난다.

### multi-source 로 차트와 값을 분리

값 파일이 차트 디렉터리 밖에 있으면 일반적인 `valueFiles` 로는 참조할 수 없다.
ArgoCD 의 multi-source 기능을 쓴다.

```yaml
sources:
  - repoURL: https://github.com/sunm2n/Kubernetes_devOps_Poc.git
    targetRevision: dev
    path: charts/eshop
    helm:
      valueFiles:
        - $values/envs/dev/values.yaml     # 아래 source 를 가리킨다

  - repoURL: https://github.com/sunm2n/Kubernetes_devOps_Poc.git
    targetRevision: dev
    ref: values                            # 이 이름이 $values 가 된다
```

두 번째 source 에 `ref: values` 로 이름을 붙이면 첫 번째 source 의 `valueFiles` 에서
`$values/...` 로 참조할 수 있다.

## 검증 결과

```
▶ 조건 1 — Application 상태
  ✓ PASS  eshop-dev — Synced · Healthy

▶ 조건 2 — selfHeal (수동 변경분 자동 복구)
          Git 기준 복제본 1개 → 5개로 강제 변경
  ✓ PASS  약 4초 만에 1개로 복구

▶ 조건 3 — prune (Git 에 없는 자원 제거)
  ✓ PASS  약 4초 만에 제거됨

▶ 조건 4 — ArgoCD 관리 하에서 애플리케이션 정상
  ✓ PASS  파드 11개 전부 Running·Ready
  ✓ PASS  Deployment·StatefulSet 전부 ArgoCD 추적 대상

▶ 조건 5 — 주문 플로우 (Phase 1 검증 재실행)
  ✓ PASS  Phase 1 검증 9개 항목 재통과

  통과 6 · 실패 0
```

### selfHeal 은 Git 폴링과 무관하다

이번 작업에서 가장 중요한 발견이다.

| 동작 | 반응 시간 | 계기 |
|---|---|---|
| selfHeal (클러스터 수동 변경) | **약 4초** | 클러스터 감시 |
| prune (Git 에 없는 자원) | 약 4초 | 클러스터 감시 |
| Git 커밋 반영 | 약 68초 | 폴링 (60초 주기) |

`kubectl scale --replicas=5` 직후 4초 만에 되돌아온다.
ArgoCD 컨트롤러가 클러스터 자원을 informer 로 감시하고 있어서, 상태가 어긋나는 즉시 알아차린다.
Git 쪽 변경만 폴링에 의존한다.

아키텍처 문서 6p 의 "selfHeal: true 로 클러스터 수동 변경분을 Git 상태로 자동 복구" 는
설정 한 줄로 성립하며, 실제 반응 속도도 운영에 쓸 만하다.

### Git 폴링 주기를 60초로 줄인 이유

기본값은 3분이다. 이 PoC 는 webhook 을 쓸 수 없어 폴링에만 의존한다.
github.com 이 로컬 클러스터로 요청을 보낼 수 없기 때문이다
(PLAN.md 의 GitLab vs GitHub 비교 참고).

실제 운영에서 GitLab 을 망 안에 두면 webhook 이 동작해 이 지연이 사라진다.
**폴링 지연은 이 PoC 환경의 제약이지 GitOps 의 특성이 아니다.**

## 결정 사항

### Phase 1의 Helm 릴리스를 제거하고 ArgoCD 가 다시 만들게 했다

같은 자원을 Helm 릴리스와 ArgoCD 가 동시에 관리하면 소유권이 겹쳐 동기화가 계속 어긋난다.
`scripts/20-install-argocd.sh` 가 기존 릴리스를 감지해 제거한다.

네임스페이스와 PVC 는 남긴다. `helm uninstall` 은 StatefulSet 의 `volumeClaimTemplates` 로 만들어진
PVC 를 지우지 않으므로 데이터가 유지되고, ArgoCD 가 만든 새 StatefulSet 이 그대로 이어받는다.

### `ignoreDifferences` 로 volumeClaimTemplates 제외

StatefulSet 의 `volumeClaimTemplates` 는 생성 후 변경할 수 없다.
API 서버가 기본값을 채워 넣기 때문에 차트가 렌더링한 내용과 실제 상태가 미세하게 달라지고,
그대로 두면 ArgoCD 가 계속 `OutOfSync` 로 보고하며 고치려 시도한다.

### `ServerSideApply=true`

마지막 적용 상태를 어노테이션이 아니라 서버 측에 기록한다.
매니페스트가 커지면 `kubectl.kubernetes.io/last-applied-configuration` 어노테이션이
크기 제한에 걸릴 수 있는데, 이를 피한다.

### ArgoCD 서버를 평문 HTTP 로 노출

ArgoCD 서버는 기본적으로 자체 TLS 로 동작한다.
ingress-nginx 뒤에서 평문으로 받기 위해 `server.insecure: true` 를 설정했다.
로컬 검증용이며 운영에서는 TLS 를 유지해야 한다.

## 작업 중 발견한 것

### ArgoCD 는 라벨이 아니라 어노테이션으로 자원을 추적한다

prune 검증이 처음에 실패했다.
`app.kubernetes.io/instance=eshop-dev` 라벨을 붙인 ConfigMap 을 만들고 3분을 기다렸으나 제거되지 않았다.

실제 관리 중인 자원을 확인해보니 판단 기준이 달랐다.

```
annotations:
  argocd.argoproj.io/tracking-id = eshop-dev:apps/Deployment:eshop/catalog-api
```

argo-cd Helm 차트가 `application.instanceLabelKey` 를 `argocd.argoproj.io/instance` 로 설정하고,
추적 자체는 `argocd.argoproj.io/tracking-id` 어노테이션으로 한다.

차트가 붙인 `app.kubernetes.io/instance=eshop-dev` 라벨은
`Release.Name` 이 우연히 Application 이름과 같아서 생긴 것일 뿐 ArgoCD 와 무관하다.

올바른 어노테이션(`eshop-dev:/ConfigMap:eshop/prune-test`)을 붙이자 **4초 만에** 제거됐다.

형식은 `<app>:<group>/<Kind>:<namespace>/<name>` 이며, 코어 그룹은 앞부분을 비운다.

### 파드 템플릿 해시가 너무 넓었다 — 수정함

Git 커밋으로 `shopping-web` 복제본을 1에서 2로 늘렸더니,
복제본만 늘어난 것이 아니라 **새 ReplicaSet 이 생기며 롤링 업데이트가 일어났다.**

```yaml
# 문제가 있던 코드
checksum/config: {{ toYaml $app | sha256sum }}
```

`$app` 에는 `config` · `secrets` 뿐 아니라 `replicas` · `image` · `probe` · `waitFor` 가 모두 들어 있다.
복제본 수처럼 파드 내용과 무관한 값이 바뀌어도 해시가 달라져 파드가 전부 재생성된다.

운영이었다면 복제본 조정 때마다 전체 서비스가 롤링돼 불필요한 중단이 생겼을 것이다.

```yaml
# 수정
checksum/config: {{ dict "config" $app.config "secrets" $app.secrets | toYaml | sha256sum }}
```

검증:

| 변경 내용 | 해시 | 기대 동작 |
|---|---|---|
| 기준 | `e45820d65c958e3b…` | — |
| `replicas` 변경 | `e45820d65c958e3b…` | 동일 — 롤링 없음 |
| `config` 변경 | `dcf365d9026a0f5d…` | 변경 — 롤링 발생 |

Phase 1 단독으로는 드러나지 않았을 결함이다.
GitOps 로 전환해 값을 커밋으로 바꾸기 시작하면서 보였다.

## 산출물

| 파일 | 역할 |
|---|---|
| `envs/dev/values.yaml` | 개발 환경 값 — 이미지 태그, 복제본 수 |
| `argocd/values.yaml` | ArgoCD Helm values |
| `argocd/applications/eshop-dev.yaml` | Application CR (multi-source, selfHeal, prune) |
| `scripts/20-install-argocd.sh` | ArgoCD 설치 및 Application 등록 |
| `scripts/21-verify-gitops.sh` | 완료 조건 자동 검증 |

## 운영 방식이 바뀐다

이 단계 이후 **클러스터를 직접 고치지 않는다.**

| 하려는 일 | 이전 | 지금 |
|---|---|---|
| 복제본 조정 | `kubectl scale` | `envs/dev/values.yaml` 커밋 |
| 설정 변경 | `helm upgrade --set` | `envs/dev/values.yaml` 커밋 |
| 이미지 갱신 | `helm upgrade` | `envs/dev/values.yaml` 의 `imageTag` 커밋 |

`kubectl` 로 바꾼 것은 4초 뒤 되돌아온다. 이것이 의도된 동작이다.

이미지 빌드(`scripts/10-build-images.sh`)는 여전히 필요하다.
Phase 3에서 Harbor 를 도입하면 레지스트리에서 받아오게 되고,
Phase 4에서 CI 가 빌드와 태그 커밋을 대신하면서 사람이 할 일이 사라진다.

## 알려진 제약

**감시 브랜치가 `dev` 다.** 작업 브랜치에서 검증할 때는 환경변수로 덮어쓴다.

```bash
ARGOCD_TARGET_REVISION=feat/my-branch scripts/20-install-argocd.sh
```

Git 에 남는 정의는 항상 `dev` 를 가리켜야 하므로 파일 자체는 고치지 않는다.

**Application CR 자체는 ArgoCD 가 관리하지 않는다.**
`kubectl apply` 로 등록한다. Application 까지 Git 으로 관리하려면 App of Apps 패턴이 필요하다.
환경이 하나뿐인 지금은 이르다. Phase 7에서 파트너사별 환경이 늘어날 때 도입한다.

**`finalizers` 경고** — 등록 시 다음 경고가 나오지만 동작에는 영향이 없다.

```
Warning: metadata.finalizers: "resources-finalizer.argocd.argoproj.io":
prefer a domain-qualified finalizer name including a path (/)
```

ArgoCD 공식 문서가 안내하는 이름이며, Kubernetes 가 권장 형식을 알리는 것뿐이다.

## 다음 단계

Phase 3 — Harbor 레지스트리.
지금은 `kind load` 로 이미지를 노드에 직접 넣고 있어, 이미지가 어디서 왔는지 Git 에 기록되지 않는다.
레지스트리를 도입하면 이미지 출처와 취약점 스캔 결과가 파이프라인의 일부가 된다.
