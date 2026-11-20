#!/usr/bin/env bash
# 로컬 → vm-mgmt 전송 계층(source 전용). 모든 원격 실행은 az vm run-command(RunShellScript)로만 한다.
# run-command 는 출력의 마지막 4,096바이트만 돌려주므로 한 번에 받는 stdout 은 3,000바이트 안팎으로 제한한다.
# AKSNETVAL_FAKE_VM=1 이면 run-command 대신 로컬 bash 로 실행한다(테스트용, VM_ROOT 는 임시 폴더).

_VX_MARK="__AKSNETVAL_RC="

_vx_err() {
  echo "오류: $*" >&2
}

# run-command 메시지에서 [stdout] 과 [stderr] 사이만 꺼낸다(없으면 빈 문자열)
stdout_section() {
  printf '%s\n' "$1" | awk '/^\[stdout\]$/ { f = 1; next } /^\[stderr\]$/ { f = 0 } f'
}

# vm_exec <script>: 원격 실행 후 stdout 구간을 출력하고 원격 스크립트의 종료 코드로 끝난다.
# 전송 실패나 종료 코드 표식이 없으면(출력 잘림 등) 255.
vm_exec() {
  local script="$1" wrapped msg body rc errf
  wrapped="export HOME=\"\${HOME:-/root}\"
(
$script
)
__rc=\$?
echo
echo \"${_VX_MARK}\$__rc\""
  if [[ "${AKSNETVAL_FAKE_VM:-0}" == 1 ]]; then
    errf="$(mktemp)"
    body="$(bash -c "$wrapped" 2>"$errf")" || true
    msg="Enable succeeded: "$'\n'"[stdout]"$'\n'"$body"$'\n\n'"[stderr]"$'\n'"$(cat "$errf")"
    rm -f "$errf"
  else
    msg="$("${AZ:-az}" vm run-command invoke -g "$RG" -n "$VM_MGMT" --command-id RunShellScript \
      --scripts "$wrapped" --query 'value[0].message' -o tsv 2>/dev/null)" || return 255
  fi
  body="$(stdout_section "$msg")"
  rc="$(printf '%s\n' "$body" | grep -a "^${_VX_MARK}" | tail -n 1)"
  [[ -n "$rc" ]] || return 255
  body="$(printf '%s\n' "$body" | grep -av "^${_VX_MARK}")" || true
  [[ -n "$body" ]] && printf '%s\n' "$body"
  return "${rc#"$_VX_MARK"}"
}

# upload_bundle <tgz>: base64 청크로 올려 복원하고 sha256 을 비교한 뒤 VM_ROOT 에 푼다.
# 번들에 든 최상위 항목만 교체하고 state/·results/·logs/ 는 보존한다.
upload_bundle() {
  local tgz="$1" chunk="${UPLOAD_CHUNK:-32000}" b64 sha root i total
  root="$(printf '%q' "$VM_ROOT")"
  b64="$(base64 -w0 "$tgz")"
  sha="$(sha256sum "$tgz" | cut -d' ' -f1)"
  total=$(( (${#b64} + chunk - 1) / chunk ))
  vm_exec "mkdir -p $root && : > $root/.upload.b64" >/dev/null || { _vx_err "업로드 준비 실패"; return 1; }
  for ((i = 0; i < ${#b64}; i += chunk)); do
    vm_exec "printf '%s' '${b64:i:chunk}' >> $root/.upload.b64" >/dev/null \
      || { _vx_err "업로드 청크 $((i / chunk + 1))/$total 실패"; return 1; }
  done
  vm_exec "cd $root && base64 -d .upload.b64 > .upload.tgz \
&& [ \"\$(sha256sum .upload.tgz | cut -d' ' -f1)\" = $sha ] || { echo sha256 불일치; exit 1; }
for top in \$(tar -tzf .upload.tgz | sed 's#^\./##' | cut -d/ -f1 | sort -u); do
  case \"\$top\" in state|results|logs|.|'') ;; *) rm -rf \"\$top\" ;; esac
done
tar -xzf .upload.tgz && rm -f .upload.b64 .upload.tgz && mkdir -p state results logs" \
    || { _vx_err "업로드 복원 실패(sha256 또는 압축 해제)"; return 1; }
}

# fetch_file <원격 경로> <로컬 경로>: base64 를 FETCH_CHUNK 문자씩 회수해 재조립하고 sha256 을 비교한다
fetch_file() {
  local remote="$1" dest="$2" chunk="${FETCH_CHUNK:-3000}" q cq meta sha len off part want tmp
  q="$(printf '%q' "$remote")"
  cq="$(printf '%q' "$VM_ROOT/.fetch.b64")"
  meta="$(vm_exec "base64 -w0 $q > $cq && echo \"\$(sha256sum $q | cut -d' ' -f1) \$(wc -c < $cq)\"")" \
    || { _vx_err "원격 파일 확인 실패: $remote"; return 1; }
  sha="${meta%% *}"
  len="${meta##* }"
  [[ "$len" =~ ^[0-9]+$ ]] || { _vx_err "원격 파일 크기 해석 실패: $meta"; return 1; }
  tmp="$(mktemp)"
  for ((off = 0; off < len; off += chunk)); do
    want=$(( len - off < chunk ? len - off : chunk ))
    part="$(vm_exec "tail -c +$((off + 1)) $cq | head -c $chunk")" || { rm -f "$tmp"; _vx_err "회수 실패(offset $off)"; return 1; }
    part="${part//[$'\r\n ']/}"
    [[ ${#part} -eq $want ]] || { rm -f "$tmp"; _vx_err "회수 길이 불일치(offset $off: ${#part}/$want)"; return 1; }
    printf '%s' "$part" >> "$tmp"
  done
  mkdir -p "$(dirname "$dest")"
  base64 -d "$tmp" > "$dest"
  rm -f "$tmp"
  if [[ "$(sha256sum "$dest" | cut -d' ' -f1)" != "$sha" ]]; then
    rm -f "$dest"
    _vx_err "sha256 불일치: $remote"
    return 1
  fi
}

# stage_action <systemctl is-active 출력>: 실행 중이면 따라가기만 한다
stage_action() {
  case "${1:-}" in
    active | activating) echo follow ;;
    *) echo start ;;
  esac
}

stage_state() {
  vm_exec "systemctl is-active aksnetval-$1 2>/dev/null; true"
}

# start_stage <stage> [args…]: systemd-run 으로 vm/<stage>.sh 를 백그라운드 실행한다
start_stage() {
  local stage="$1" root args=""
  shift
  root="$(printf '%q' "$VM_ROOT")"
  (( $# )) && args="$(printf ' %q' "$@")"
  vm_exec "cd $root && mkdir -p logs state && rm -f state/$stage.rc
systemctl reset-failed aksnetval-$stage 2>/dev/null || true
systemd-run --quiet --unit aksnetval-$stage --setenv HOME=/root --working-directory $root \
  /bin/bash -c 'vm/$stage.sh \"\$@\" > logs/$stage.log 2>&1; echo \$? > state/$stage.rc' bash$args"
}

# poll_stage <stage>: POLL 초마다 상태와 새 로그 줄을 출력하고, 끝나면 단계의 종료 코드로 끝난다.
# run-command 실패는 연속 3회까지 경고 후 재시도한다.
poll_stage() {
  local stage="$1" seen=0 fails=0 out header st rc n root
  root="$(printf '%q' "$VM_ROOT")"
  while true; do
    if out="$(vm_exec "cd $root
st=\$(systemctl is-active aksnetval-$stage 2>/dev/null)
rc=-; [ -f state/$stage.rc ] && rc=\$(tr -dc 0-9 < state/$stage.rc)
echo \"__STATE \${st:-unknown} \${rc:--}\"
if [ -f logs/$stage.log ]; then tail -n +$((seen + 1)) logs/$stage.log; fi \
  | LC_ALL=C awk -v max=2800 '{ s = substr(\$0, 1, max); b += length(s) + 1; if (b > max && NR > 1) exit; print s; n++ } END { print \"__N \" n + 0 }'")" \
      && [[ "$out" == __STATE* ]]; then
      fails=0
      header="${out%%$'\n'*}"
      read -r _ st rc <<<"$header"
      n="$(printf '%s\n' "$out" | grep -a '^__N ' | tail -n 1 | cut -d' ' -f2)"
      if (( n > 0 )); then
        printf '%s\n' "$out" | sed '1d' | grep -av '^__N ' | head -n "$n"
      fi
      seen=$(( seen + n ))
      if [[ "$st" != active && "$st" != activating ]]; then
        (( n > 0 )) && continue
        if [[ "$rc" == - ]]; then
          _vx_err "$stage 단계가 종료됐지만 종료 코드 파일이 없습니다(상태: $st)"
          return 1
        fi
        return "$rc"
      fi
    else
      fails=$(( fails + 1 ))
      echo "경고: $stage 상태 조회 실패($fails/3)" >&2
      (( fails >= 3 )) && { _vx_err "상태 조회가 연속 3회 실패했습니다"; return 1; }
    fi
    sleep "${POLL:-30}"
  done
}
