#!/usr/bin/env bash
# 로컬 실행: 99-cleanup.sh [--force]. 리소스 그룹 전체를 비동기로 삭제한다(vm-mgmt 포함).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../config.sh
source "$ROOT/config.sh"
# shellcheck source=../vm/lib/common.sh
source "$ROOT/vm/lib/common.sh"

if [[ "$(az_ok group exists -n "$RG")" != true ]]; then
  log "RG $RG 가 없습니다. 할 일 없음"
  exit 0
fi
if [[ "${1:-}" != "--force" ]]; then
  read -r -p "삭제할 리소스 그룹 이름을 입력하세요($RG): " answer
  [[ "$answer" == "$RG" ]] || { log "이름이 다릅니다. 중단"; exit 1; }
fi
az_ok group delete -n "$RG" --yes --no-wait
log "RG $RG 삭제 요청(비동기). 확인: az group exists -n $RG"
