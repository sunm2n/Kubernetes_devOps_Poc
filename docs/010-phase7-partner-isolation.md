# 010 — Phase 7 파트너 격리 및 멀티테넌시

이슈 [#24](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/24) · 브랜치 `feat/phase7-partner-isolation`

파트너사별로 레지스트리 · 네임스페이스 · 네트워크 · 권한을 나누고,
**나뉘었다는 것을 넘어가려다 막히는 것으로** 증명했다. 검증 20개 전부 통과.

**PoC 검증 목표 5번**이 여기서 성립하며, 이로써 다섯 목표를 모두 달성했다.

---

## 격리를 네 층으로 나눈 이유

```
                  partner-a                     partner-b
  레지스트리      harbor/partner-a (private)    harbor/partner-b (private)
                  robot$partner-a+puller        robot$partner-b+puller
                          │                             │
  네임스페이스    ns partner-a                  ns partner-b
                          │                             │
  네트워크        NetworkPolicy 4종             NetworkPolicy 4종
                          │                             │
  권한            SA tenant-partner-a           SA tenant-partner-b
                          │                             │
  GitOps          AppProject partner-a          AppProject partner-b
```

한 층만으로는 부족하다. 각 층이 막는 것이 다르다.

| 층 | 이것이 없으면 |
|---|---|
| 레지스트리 | 파트너가 남의 이미지를 받아 뜯어볼 수 있다 |
| 네임스페이스 | 이름이 겹쳐 서로의 자원을 덮어쓴다 |
| 네트워크 | 파드가 남의 DB 에 직접 붙는다 |
| 권한 | 담당자가 남의 네임스페이스를 조회한다 |
| GitOps | 매니페스트를 고쳐 남의 네임스페이스에 배포한다 |

마지막 층이 특히 중요하다. GitOps 에서는 **매니페스트가 곧 권한**이다.
앞의 네 층을 다 걸어도, 파트너 A 의 Application 정의에서 `namespace: partner-b`
한 줄만 고치면 넘어갈 수 있다면 격리가 아니다.

---

## kindnet 이 NetworkPolicy 를 강제하는지 먼저 확인했다

kind 기본 CNI(kindnetd)는 오랫동안 NetworkPolicy 를 구현하지 않았다.
그대로였다면 정책을 걸어도 아무 일이 일어나지 않고 **검증만 통과하는**
가장 나쁜 결과가 됐을 것이다.

작업을 시작하기 전에 실측했다.

```
정책 없음                   →  연결됨
deny-all-ingress 적용 후    →  차단됨
```

`kindest/kindnetd:v20260528-9350166c` 에서 강제된다. Calico 설치는 필요 없었다.

**이런 확인을 먼저 하는 편이 낫다.** 나중에 했다면 정책·값 파일·Application 을
다 만들어놓고 CNI 를 갈아끼우는 일이 됐을 것이다.

---

## NetworkPolicy 를 네 개로 나눈 구성

NetworkPolicy 는 더하기만 한다. 규칙이 없는 정책이 곧 전면 차단이고,
뒤에 오는 정책들이 허용을 얹는다.

| 정책 | 역할 |
|---|---|
| `tenant-default-deny` | Ingress·Egress 전면 차단. 나머지 셋이 필요한 것만 연다 |
| `tenant-allow-same-namespace` | 같은 테넌트 안 통신. `namespaceSelector` 없이 `podSelector` 만 쓰면 "같은 네임스페이스" 가 된다 |
| `tenant-allow-dns` | kube-system 의 53번. 이것이 빠지면 전부 멈춘다 |
| `tenant-allow-ingress-controller` | ingress-nginx 에서 오는 것만. 외부 진입의 유일한 경로 |

**DNS 를 빠뜨리면 증상이 엉뚱하게 나타난다.** 서비스 이름을 못 찾아
애플리케이션이 죽는데, 로그에는 이름 해석 실패로 찍혀 네트워크 정책 문제로 보이지 않는다.
Egress 를 막을 때 가장 먼저 걸리는 항목이다.

`tenant-allow-ingress-controller` 가 빠지면 파드는 다 뜨는데 브라우저에서 502 가 뜬다.

---

## 검증이 한 번 거짓으로 통과했다

조건 3(네트워크)에서 처음에 이런 결과가 나왔다.

```
✗ FAIL  partner-a 안에서 catalog-api 를 부르지 못한다 — 정책이 과하다
✓ PASS  partner-a → partner-b/catalog-api 차단됨
```

두 번째 줄은 **거짓 통과**였다. 검증용 파드를 애플리케이션 이미지로 띄웠는데
`mcr.microsoft.com/dotnet/aspnet` 계열에는 `curl` · `wget` · `nc` 가 없다.

```
curl     없음
wget     없음
nc       없음
getent   /usr/bin/getent
```

명령이 없어서 실패한 것을 네트워크가 막은 것으로 읽었다.
**정책을 하나도 걸지 않아도 이 검증은 통과했을 것이다.**

첫 번째 줄(대조군)이 FAIL 로 뜬 덕분에 드러났다.
차단을 확인하는 검증은 같은 방법으로 **열려야 하는 것도 함께 봐야 한다.**
"막혔다" 만 확인하면 도구가 고장 난 것과 구분되지 않는다.

`busybox:1.37` 로 바꾸고 다시 측정했다.

| 경로 | 결과 |
|---|---|
| `partner-a` → 같은 ns `catalog-api:8080` | 연결됨 (대조군) |
| `partner-a` → `catalog-api.partner-b` | 차단됨 |
| `partner-a` → `catalog-api.eshop` (본사) | 차단됨 |
| `nslookup catalog-api.partner-b` | 해석됨 |

마지막 줄이 있어야 차단 지점이 네트워크 정책이지 DNS 가 아니라고 말할 수 있다.

---

## AppProject 거부 메시지도 처음엔 못 잡았다

같은 성격의 문제가 조건 5에도 있었다. 거부 메시지를
`not permitted|is not allowed|denied` 로 찾았는데 ArgoCD 는 이렇게 답한다.

```
InvalidSpecError: application destination server 'https://kubernetes.default.svc'
and namespace 'partner-b' do not match any of the allowed destinations
in project 'partner-a'
```

패턴이 안 맞아 "거부 메시지는 확인하지 못했다" 로 넘어갔고,
**자원이 만들어지지 않았다**는 약한 근거로 통과했다.
배포가 다른 이유로 실패해도 같은 결론이 나왔을 것이다.

메시지를 실제 문구로 맞췄다. 목적지 검증은 저장소를 읽기 전에 일어나므로
리비전이나 경로가 무엇이든 이 오류가 먼저 나온다.

---

## Harbor robot 계정

프로젝트 수준 robot 은 이름이 `robot$<프로젝트>+<이름>` 이 된다.
접두어를 빼고 쓰면 인증이 조용히 실패하므로 발급 응답의 값을 그대로 쓴다.

권한은 **pull 만** 준다. push 를 주면 파트너가 자기 프로젝트에 임의의 이미지를
올릴 수 있고, 그러면 "본사가 검증한 것만 돈다" 는 전제가 깨진다.
Harbor 취약점 게이트(Phase 3)를 우회하는 경로가 생기는 셈이다.

비밀번호는 발급 시점에 한 번만 돌려주고 다시 조회할 수 없다.
그래서 재실행할 때는 같은 이름의 robot 을 지우고 새로 만든다.

### 자격증명을 Git 에 둘 수 없다

이 저장소는 PUBLIC 이다. `scripts/70-setup-partners.sh` 가 robot 을 발급해
클러스터에 `docker-registry` Secret 을 직접 만들고,
Git 의 매니페스트는 **이름만** 참조한다.

```
Git 에 있는 것    네임스페이스 이름, Secret 이름, 정책, Application 정의
스크립트가 만드는 것  robot 계정, docker-registry Secret
```

운영에서는 이 자리에 OpenBao 가 들어간다(Phase 8).
지금 구조는 "자격증명이 필요한 것만 GitOps 밖에 있다" 는 점에서
그 전환의 형태를 미리 갖춘 것이기도 하다.

---

## 차트는 하나로 유지했다

파트너용 차트를 따로 만들지 않았다. `charts/eshop` 에 기능을 더하고
기본값을 꺼둔 뒤, 파트너 값 파일에서 켠다.

```yaml
# charts/eshop/values.yaml — 기본은 꺼짐
tenant:
  networkPolicy:
    enabled: false
    ingressNamespace: ingress-nginx
  rbac:
    enabled: false
    serviceAccountName: tenant-operator
```

본사(`envs/dev`)의 렌더링 결과는 이 변경 전후로 같다.
NetworkPolicy·Role·`imagePullSecrets` 가 하나도 생기지 않는다.

파트너 값 파일이 본사와 다른 부분은 이것뿐이다.

```yaml
# envs/partner-a/values.yaml
global:
  imageRegistry: harbor.localtest.me/partner-a
  imagePullSecrets: [harbor-partner-a]
tenant:
  networkPolicy: { enabled: true }
  rbac: { enabled: true, serviceAccountName: tenant-partner-a }
ingress:
  host: eshop.partner-a.localtest.me
  gatewayHost: api.eshop.partner-a.localtest.me
```

`envs/partner-b/values.yaml` 은 이름만 다르다.
**파트너를 늘리는 데 새 차트나 새 구조가 필요하지 않다**는 것이
15곳으로 확장할 수 있는지의 기준이다.

### 격리를 배포와 같은 단위에 둔 이유

NetworkPolicy 와 RBAC 를 별도 차트나 수동 적용으로 두면
네임스페이스는 만들어졌는데 정책은 안 붙은 시점이 생긴다.
그 틈이 존재하는 한 격리를 보장한다고 말할 수 없다.

---

## RBAC 에서 Secret 을 뺐다

파트너 담당자 계정은 자기 네임스페이스의 Secret 도 읽지 못한다.

```yaml
- apiGroups: [""]
  resources: [pods, pods/log, services, configmaps, persistentvolumeclaims, events]
  verbs: [get, list, watch]
```

자기 것이라도 접속 문자열과 레지스트리 자격증명이 들어 있다.
**pull secret 을 읽으면 그 계정으로 레지스트리에 직접 붙을 수 있다** —
클러스터 안에서 막아둔 레지스트리 경계가 밖에서 열리는 셈이다.

쓰기는 파드 삭제(재시작)만 준다.

---

## 검증 결과

`scripts/71-verify-isolation.sh` — **20개 전부 통과.**

| 조건 | 결과 |
|---|---|
| 1. 파트너 2곳 파드 11개씩 기동, 앱 이미지 6개씩 자기 프로젝트 출처 | 통과 |
| 2. `robot$partner-a+puller` 로 `partner-b` 이미지 → **거부**. 익명도 **거부** | 통과 |
| 3. `partner-a` → `partner-b`·본사 **차단**, 같은 ns 는 연결, DNS 정상 | 통과 |
| 4. `partner-a` 계정 → `partner-b` 조회 **거부**, Secret **거부**, 클러스터 작업 **거부** | 통과 |
| 5. `partner-a` 프로젝트로 `partner-b` 배포 → **ArgoCD 거부** | 통과 |
| 6. 본사 검증 재통과 | 통과 |

2·3·4·5번이 이 단계의 실질이다. 1번만 확인하면 "파드가 떴다" 는 것 외에
아무것도 증명하지 못한다.

---

## 실측 자원

| 노드 | 메모리 |
|---|---|
| `erp-poc-worker` | 7.04 GiB |
| `erp-poc-worker2` | 3.96 GiB |
| `erp-poc-control-plane` | 1.43 GiB |
| **합계** | **12.4 / 23.4 GiB** |

파드는 33개다 — 본사 11 + 파트너 11 × 2.
테넌트 한 벌이 약 2.6 GiB 이므로, 문서 9p 의 15곳을 이 방식으로 올리면
약 40 GiB 가 필요하다는 계산이 나온다.

실제로는 파트너마다 전체 스택을 복제하지 않을 가능성이 높다.
공통 인프라(메시지 브로커·캐시)를 공유하고 데이터만 나누는 구성이라면
훨씬 줄어들지만, 그때는 **공유 지점이 곧 격리의 구멍**이 되므로
어디까지 공유할지가 설계 판단이 된다. 이 PoC 는 완전 복제를 기준으로 측정했다.

SQL Server 가 3벌 도는 구성이지만(arm64 에뮬레이션) 기동에 문제는 없었다.

---

## 남은 것

| 항목 | 어디로 |
|---|---|
| 파트너 자격증명 관리 | Phase 8(OpenBao). 지금은 스크립트가 클러스터에 직접 만든다 |
| 파트너 SSO | Phase 8(Keycloak). 지금은 ServiceAccount 토큰이다 |
| ResourceQuota · LimitRange | 한 파트너가 클러스터 자원을 다 쓰는 것을 막는 층이 없다 |
| 파트너 15곳 확장 | AppProject·Application 을 손으로 늘리고 있다. ApplicationSet 이 필요한 지점 |
| 파트너별 CI | 지금은 본사가 빌드해 배포한다. 파트너가 자기 코드를 넣는 구조는 다른 문제다 |

ResourceQuota 는 AppProject 에서 파트너가 **만들지 못하도록** 막아뒀지만,
관리자가 **부여하는** 쪽은 아직 없다. 격리의 한 층이 비어 있는 상태다.

---

## 다시 만들기

```bash
scripts/70-setup-partners.sh      # 프로젝트·robot·네임스페이스·Application
scripts/71-verify-isolation.sh    # 검증 20개
scripts/70-setup-partners.sh remove
```

접속:

| 주소 | 내용 |
|---|---|
| http://eshop.partner-a.localtest.me | 파트너 A |
| http://eshop.partner-b.localtest.me | 파트너 B |
| http://eshop.localtest.me | 본사 |
