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
