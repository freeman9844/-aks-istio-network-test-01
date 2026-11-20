#!/usr/bin/env bash
# vm-mgmt 단계 스크립트 공통 함수(source 전용).

die() {
  echo "[$(date '+%H:%M:%S')] 오류: $*" >&2
  exit 1
}

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

# az 를 실행하고 실패하면 어떤 명령이 왜 실패했는지 남기고 종료한다
az_ok() {
  local out err rc=0
  err="$(mktemp)"
  out="$("${AZ:-az}" "$@" 2>"$err")" || rc=$?
  if (( rc != 0 )); then
    local msg
    msg="$(cat "$err")"
    rm -f "$err"
    die "az $* 실패(rc=$rc): $msg"
  fi
  rm -f "$err"
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return 0
}

# az ... show 가 성공하면 0(리소스 있음), 아니면 1
exists() {
  # 일부 show 명령(예: dns-zone-group show)은 없는 리소스에도 rc 0 과 {} 를 돌려준다
  local out
  out="$("${AZ:-az}" "$@" -o json 2>/dev/null)" || return 1
  out="$(tr -d '[:space:]' <<<"$out")"
  [[ -n "$out" && "$out" != "{}" && "$out" != "null" ]]
}

# retry <횟수> <대기초> <명령…>
retry() {
  local n="$1" wait="$2" i
  shift 2
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    (( i < n )) && sleep "$wait"
  done
  return 1
}

kube() {
  kubectl --kubeconfig "${VM_ROOT:-/opt/aksnetval}/state/kubeconfig" "$@"
}

# py <모듈> <함수> '<JSON kwargs>'
py() {
  local mod="$1"
  shift
  (cd "${VM_ROOT:-/opt/aksnetval}" && python3 -m "aksnetval.$mod" "$@")
}

# enablePrivateCluster 조회 값: 빈 값(AKS 없음)·true 는 진행, 그 외(공개 AKS)는 중단
aks_private_guard() {
  case "${1:-}" in
    "" | true) return 0 ;;
    *) return 1 ;;
  esac
}
