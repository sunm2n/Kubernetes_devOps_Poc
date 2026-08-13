# 005. Phase 3 — Harbor 레지스트리

이슈: [#10](https://github.com/sunm2n/Kubernetes_devOps_Poc/issues/10)
작업일: 2026-08-13

## 결과 요약

`kind load` 로 노드에 직접 넣던 이미지를 Harbor 에서 받아오도록 바꿨다.
**PoC 검증 목표 3번(취약점 스캔이 파이프라인을 실제로 차단)이 이 단계에서 증명됐다.**

| 항목 | 값 |
|---|---|
| Harbor | 차트 1.19.2 (v2.15.2) |
| 프로젝트 | `erp-hq`(public) · `partner-a` · `partner-b`(private) |
| 이미지 | 6개, 전부 Trivy 자동 스캔 완료 |
| 차단 정책 | `prevent_vul=true` · `severity=critical` |
| 검증 | 11개 항목 전부 통과 |

## 무엇이 달라졌나

이전까지 이미지는 `scripts/10-build-images.sh` 가 `kind load` 로 노드에 직접 넣었다.
GitOps 로 전환한 뒤에도 **이미지가 어디서 왔는지는 Git 에 아무 기록이 남지 않았다.**
클러스터를 다시 만들면 이미지도 함께 사라지고, 누가 무엇을 넣었는지 확인할 방법이 없었다.

이제 이미지 참조가 매니페스트에 남는다.

```yaml
# envs/dev/values.yaml
global:
  imageRegistry: harbor.localtest.me/erp-hq
  imageTag: local
```

클러스터를 재생성한 뒤 `kind load` 없이 배포해 실제로 확인했다.
노드에 이미지가 0개인 상태에서 시작해 11개 파드가 전부 떴다.

## 검증 결과

```
▶ 조건 1 — 프로젝트 구성
  ✓ PASS  erp-hq(public) · partner-a(private) · partner-b(private)

▶ 조건 2 — 이미지 저장 및 Trivy 스캔
          catalog-api — 취약점 174건
          basket-api — 취약점 174건
          discount-grpc — 취약점 173건
          ordering-api — 취약점 178건
          yarp-apigateway — 취약점 172건
          shopping-web — 취약점 173건
  ✓ PASS  이미지 6개 저장됨
  ✓ PASS  6개 전부 Trivy 스캔 완료

▶ 조건 3 — 클러스터가 Harbor 를 이미지 출처로 쓰는가
  ✓ PASS  앱 컨테이너 6개가 harbor.localtest.me 를 참조
  ✓ PASS  파드 11개 Running·Ready

▶ 조건 4 — 취약 이미지 차단 (검증 목표 3번)
          스캔 결과 Critical 1건
  ✓ PASS  취약 이미지 pull 거부됨
  ✓ PASS  허용목록에 등록된 CVE 만 있는 이미지는 통과

▶ 조건 5 — 파트너 프로젝트 격리
  ✓ PASS  partner-a 계정으로 partner-b 이미지 접근 거부됨
  ✓ PASS  익명 접근 거부됨 (private 프로젝트)

▶ 조건 6 — ArgoCD 및 주문 플로우
  ✓ PASS  ArgoCD — Synced · Healthy
  ✓ PASS  주문 플로우 9개 항목 통과

  통과 11 · 실패 0
```

## 취약점 게이트가 실제로 막는다

차단 정책을 켜자 **우리가 만든 이미지가 그대로 막혔다.**

containerd 쪽 메시지는 원인을 알려주지 않는다.

```
failed to resolve reference "harbor.localtest.me/erp-hq/catalog-api:local":
unexpected status from HEAD request ...: 412 Precondition Failed
```

skopeo 로 같은 요청을 보내면 이유가 나온다.

```
current image with 174 vulnerabilities cannot be pulled due to configured policy in
'Prevent images with vulnerability severity of "Critical" or higher from running.'
```

**운영에서 이 상황을 만나면 `412` 만 보고 원인을 찾기 어렵다.**
Harbor UI 나 API 로 스캔 결과를 확인해야 한다.

### 검출된 Critical 6건

| CVE | 패키지 | 출처 |
|---|---|---|
| CVE-2026-13221 | perl-base | Debian 베이스 |
| CVE-2026-42496 | perl-base | Debian 베이스 |
| CVE-2026-57433 | perl-base | Debian 베이스 |
| CVE-2026-8376 | perl-base | Debian 베이스 |
| CVE-2023-45853 | zlib1g | Debian 베이스 |
| **CVE-2026-45288** | **Marten 6.4.1** | **애플리케이션 의존성** |

앞의 5건은 `mcr.microsoft.com/dotnet/aspnet:8.0` 이 딸고 오는 것이라
애플리케이션 코드로는 손댈 수 없다. 베이스 이미지를 갱신해야 한다.

**마지막 1건은 성격이 다르다.** `Marten 6.4.1` 은 Catalog·Basket 이 쓰는 NuGet 패키지이고,
버전을 올리면 해결된다. 허용목록에 넣고 넘길 것이 아니라 고쳐야 할 항목이다.
후속 이슈로 분리했다.

### 허용목록으로 분류

게이트를 켠 채로 두려면 알려진 항목을 분류해야 한다.
운영에서 하는 일과 같다.

허용목록을 적용한 뒤에도 **베이스 이미지 5건만 넣은 상태에서는 여전히 차단됐다.**
Marten CVE 가 남아 있었기 때문이다. 게이트가 항목 단위로 정확히 판단한다는 뜻이다.

6건을 모두 등록하자 통과했고, 그 상태에서 `alpine:3.10`(허용목록에 없는 Critical 1건)을
올려보니 다시 막혔다. **게이트는 켜져 있고 새로 생기는 Critical 은 계속 잡는다.**

## 막혔던 지점

### 1. containerd 가 레지스트리 설정을 읽지 않았다

```
[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = ''
```

기본값이 빈 문자열이라 `/etc/containerd/certs.d/` 를 아예 보지 않는다.
`containerdConfigPatches` 로 채워야 하는데, **이 값은 노드 생성 시점에만 적용된다.**
클러스터를 다시 만들었다.

`infra/kind/cluster.yaml` 에 넣었으므로 이후에는 재현된다.
그리고 이 경로 아래의 `hosts.toml` 은 요청마다 읽히므로,
레지스트리를 추가할 때는 파일만 넣으면 되고 containerd 재시작이 필요 없다.

### 2. 한쪽 노드의 파드만 이미지를 받았다

`hosts.toml` 을 배포한 뒤에도 절반이 `ImagePullBackOff` 였다.

```
catalog-api      erp-poc-worker2   Pending
basket-api       erp-poc-worker    Running
discount-grpc    erp-poc-worker    Running
yarp-apigateway  erp-poc-worker2   Pending
```

**Ingress 노드(`erp-poc-worker`)의 파드는 전부 성공하고 다른 노드는 전부 실패했다.**

원인은 인증 흐름에 있었다. `hosts.toml` 은 레지스트리 요청을 올바른 엔드포인트로 보낸다.
그런데 Harbor 는 401 응답의 `Www-Authenticate` 헤더에 토큰 발급 주소를
`http://harbor.localtest.me/service/token` 으로 돌려준다.
containerd 가 그 주소를 **다시 해석해야 한다.**

`harbor.localtest.me` 는 공개 DNS 에서 `127.0.0.1` 로 해석된다.
노드 안에서 그것은 노드 자신이고, Ingress 의 hostPort 를 가진 노드에서만 우연히 통했다.

각 노드의 `/etc/hosts` 에 Ingress 노드 IP 를 등록해 해결했다.

```
172.20.0.2  harbor.localtest.me
```

**레지스트리 엔드포인트만 맞추는 것으로는 부족하다.
인증 서비스 주소까지 해석 가능해야 한다.**

### 3. 프로젝트 CVE 허용목록이 무시됐다

6건을 모두 등록했는데도 계속 차단됐다. 저장은 정상이었다.

```
items: ['CVE-2026-13221', ..., 'CVE-2026-45288']   ← 6건 다 있음
→ 그런데도 pull 거부
```

원인은 `reuse_sys_cve_allowlist` 였다. **기본값이 `true` 이고,
그 경우 프로젝트에 등록한 허용목록이 아니라 시스템 전역 허용목록(비어 있음)을 본다.**

```
reuse_sys_cve_allowlist = false
```

로 바꾸자 통과했다. UI 에서는 체크박스 하나라 눈에 띄지만,
API 로 설정할 때는 이 값을 명시하지 않으면 프로젝트 허용목록이 조용히 무시된다.

### 4. crane 으로는 푸시할 수 없었다

호스트 Docker 데몬 설정을 바꾸지 않기로 했다.
`docker push` 로 평문 레지스트리에 올리려면 `insecure-registries` 를 추가하고
데몬을 재시작해야 하는데, 사용자 환경의 보안 설정이라 피했다.

대신 `kind` 네트워크에 컨테이너를 붙여 푸시하기로 했고, 처음에는 crane 을 썼다.

```
Error: invalid realm in www-authenticate:
       realm scheme "http" not allowed for a secure registry; use https
```

crane 의 `--insecure` 는 레지스트리 연결에만 적용되고 인증 흐름에는 미치지 않는다.
Harbor 가 돌려주는 http realm 을 거부한다. 플래그 위치를 바꿔도 같았다.

skopeo 의 `--dest-tls-verify=false` 는 인증 흐름까지 포함해 동작한다.

```bash
docker run --rm --network kind \
  --add-host harbor.localtest.me:${INGRESS_IP} \
  quay.io/skopeo/stable copy \
    --dest-tls-verify=false --dest-creds admin:... \
    docker-archive:/work/image.tar \
    docker://harbor.localtest.me/erp-hq/catalog-api:local
```

### 5. 프로젝트 메타데이터는 한 번에 하나씩만

```
{"errors":[{"code":"BAD_REQUEST","message":"only allow one key/value pair"}]}
```

`POST /projects/{name}/metadatas` 는 키를 하나만 받는다.
없는 키는 POST 로 만들고 있는 키는 PUT 으로 고쳐야 해서,
스크립트에서는 둘 다 시도하는 방식으로 처리했다.

## 결정 사항

### `erp-hq` 를 public 으로

이 저장소가 PUBLIC 이라 pull secret 을 Git 에 둘 수 없다.
`erp-hq` 를 public 프로젝트로 만들어 익명 pull 을 허용했다.

파트너 격리 검증에는 private 프로젝트와 robot account 를 쓴다.
실제 운영에서 자격증명을 어떻게 다룰지는 Phase 8(OpenBao)에서 정한다.

### TLS 없이 평문 HTTP

로컬 검증이라 끄고 간다. 대가는 분명하다.
받는 쪽에서도 평문을 허용해야 하고(`hosts.toml` 의 http 엔드포인트, `--dest-tls-verify=false`),
그 설정이 다른 레지스트리까지 느슨하게 만들 여지가 생긴다.
Phase 6 폐쇄망 구성에서 다시 다룬다.

### `imagePullPolicy` 는 `IfNotPresent` 유지

태그가 `local` 로 고정이라 `Always` 로 둘 이유가 있지만 그대로 두었다.
Phase 4에서 커밋 해시를 태그로 쓰기 시작하면 태그 자체가 매번 달라지므로
`IfNotPresent` 로도 항상 새 이미지를 받게 된다.

## 산출물

| 파일 | 역할 |
|---|---|
| `infra/kind/cluster.yaml` | containerd `config_path` 추가 |
| `infra/harbor/values.yaml` | Harbor Helm values |
| `charts/eshop/values.yaml` | `global.imageRegistry` 추가 |
| `envs/dev/values.yaml` | Harbor 참조로 전환 |
| `scripts/30-install-harbor.sh` | 설치, 노드 신뢰 설정, 프로젝트·정책·허용목록 |
| `scripts/31-push-images.sh` | skopeo 로 이미지 푸시 |
| `scripts/32-verify-harbor.sh` | 완료 조건 자동 검증 |

## 후속

`Marten 6.4.1` 의 Critical CVE 는 허용목록에 넣어 통과시켰지만,
버전을 올려 해결해야 할 항목이다. 앱 저장소 수정이 필요해 후속 이슈로 분리했다.

베이스 이미지 5건도 `mcr.microsoft.com/dotnet/aspnet:8.0` 을 갱신하면 줄어든다.
PLAN.md 의 R4(.NET 8 → .NET Core 10)와 함께 볼 항목이다.

## 다음 단계

Phase 4 — CI.
지금은 사람이 `10-build-images.sh` → `31-push-images.sh` → `envs/dev/values.yaml` 커밋을 손으로 한다.
이 세 단계를 CI 가 대신하면 커밋 한 번으로 배포까지 이어진다.
PoC 검증 목표 1번이 그때 완성된다.
