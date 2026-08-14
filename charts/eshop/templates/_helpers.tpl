{{/*
공통 라벨. 모든 자원에 붙인다.
app.kubernetes.io/* 는 Kubernetes 권장 라벨이며,
kubectl 과 ArgoCD(Phase 2)가 자원을 묶어 보는 기준이 된다.
*/}}
{{- define "eshop.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/*
개별 구성요소를 식별하는 셀렉터 라벨.
Deployment 의 selector 는 생성 후 변경할 수 없으므로 최소한만 담는다.
공통 라벨을 여기 넣으면 차트 버전이 오를 때 selector 가 바뀌어 배포가 실패한다.
*/}}
{{- define "eshop.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
비공개 레지스트리에서 이미지를 받기 위한 pull secret.

본사(erp-hq)는 public 프로젝트라 필요 없고, 파트너사는 private 프로젝트라 필요하다.
Secret 자체는 이 차트가 만들지 않는다. 이 저장소가 PUBLIC 이므로
자격증명이 Git 에 들어가면 안 된다. scripts/70-setup-partners.sh 가
클러스터에 직접 만들고, 여기서는 이름만 참조한다.
*/}}
{{- define "eshop.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
  {{- range . }}
  - name: {{ . }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
의존 서비스가 열릴 때까지 기다리는 initContainer.
호출부에서 .waitFor(호스트:포트 목록)와 .root(최상위 컨텍스트)를 넘긴다.

애플리케이션이 DB 보다 먼저 떠서 예외로 죽고 재시작을 반복하는 상황을 막는다.
Kubernetes 가 결국 재시도해 정상화되기는 하지만,
그 사이 로그가 예외로 뒤덮여 진짜 문제를 가린다.
*/}}
{{- define "eshop.waitInitContainers" -}}
{{- range .waitFor }}
- name: wait-{{ . | replace ":" "-" | replace "." "-" }}
  image: {{ $.root.Values.waitImage }}
  imagePullPolicy: IfNotPresent
  command:
    - sh
    - -c
    - |
      target="{{ . }}"
      host="${target%%:*}"
      port="${target##*:}"
      echo "${host}:${port} 대기 중"
      until nc -z "${host}" "${port}" 2>/dev/null; do
        sleep 2
      done
      echo "${host}:${port} 응답"
  resources:
    requests:
      cpu: 10m
      memory: 16Mi
{{- end }}
{{- end }}
