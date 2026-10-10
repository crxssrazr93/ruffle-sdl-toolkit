#!/usr/bin/env bash
# ffdec.sh: thin wrapper around JPEXS Free Flash Decompiler (ffdec) for patch scripts.
#
#   ffdec.sh as3 <in.swf> <outdir> [Class[,Class2|pkg.+] ...]   decompile AS3 to <outdir>/scripts/**.as
#   ffdec.sh pcode <in.swf> <outdir>                            export P-code (AS1/AS2 or AS3) to <outdir>/scripts/
#   ffdec.sh replace-as3 <in.swf> <out.swf> <Class> <file.as> [<Class2> <file2.as> ...]
#   ffdec.sh replace-pcode <in.swf> <out.swf> </script/name> <file.pcode> [...]
#   ffdec.sh raw <args...>                                      pass arguments straight to ffdec
#
# Locating ffdec (first match wins):
#   FFDEC      path to the ffdec launcher script, or to ffdec.jar
#   FFDEC_JAR  path to ffdec.jar (run with: java -jar)
#   ffdec      found on PATH
# Extra global pre-options (for example -air) go into FFDEC_OPTS.
# Java runs headless (-Djava.awt.headless=true); override JAVA to pick a JVM.
#
# Exit codes: 0 ok, 1 usage (or ffdec own failure status), 2 ffdec or java not found, 3 nothing produced.
set -euo pipefail

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

JAVA="${JAVA:-java}"
run_ffdec() {
  local target="${FFDEC:-}"
  if [ -z "$target" ] && [ -n "${FFDEC_JAR:-}" ]; then target="$FFDEC_JAR"; fi
  if [ -z "$target" ]; then
    target=$(command -v ffdec || true)
    [ -n "$target" ] || { echo "ffdec.sh: ffdec not found. Set FFDEC (launcher or jar) or FFDEC_JAR, or put ffdec on PATH." >&2; exit 2; }
  fi
  [ -e "$target" ] || { echo "ffdec.sh: $target does not exist" >&2; exit 2; }
  # a launcher script next to ffdec.jar is bypassed (it only probes java versions noisily)
  if [ "${target##*.}" != jar ] && [ -r "$(dirname "$(readlink -f "$target")")/ffdec.jar" ]; then
    target="$(dirname "$(readlink -f "$target")")/ffdec.jar"
  fi
  # shellcheck disable=SC2086
  case "$target" in
    *.jar)
      command -v "$JAVA" >/dev/null || { echo "ffdec.sh: java not found" >&2; exit 2; }
      "$JAVA" -Djava.awt.headless=true -jar "$target" ${FFDEC_OPTS:-} "$@" ;;
    *)
      local launcher=("$target")
      [ -x "$target" ] || launcher=(bash "$target")
      "${launcher[@]}" ${FFDEC_OPTS:-} "$@" ;;
  esac
}

[ $# -ge 1 ] || usage
cmd=$1; shift

case "$cmd" in
  as3)
    [ $# -ge 2 ] || usage
    swf=$1; out=$2; shift 2
    [ -f "$swf" ] || { echo "ffdec.sh: no such file $swf" >&2; exit 1; }
    sel=()
    if [ $# -gt 0 ]; then
      classes=$(IFS=,; echo "$*")
      sel=(-selectclass "$classes")
    fi
    mkdir -p "$out"
    run_ffdec "${sel[@]}" -export script "$out" "$swf" >/dev/null
    [ -d "$out/scripts" ] || { echo "ffdec.sh: no scripts exported (is this an AS3 SWF, are the class names right?)" >&2; exit 3; }
    ;;
  pcode)
    [ $# -eq 2 ] || usage
    [ -f "$1" ] || { echo "ffdec.sh: no such file $1" >&2; exit 1; }
    mkdir -p "$2"
    run_ffdec -format script:pcode -export script "$2" "$1" >/dev/null
    [ -d "$2/scripts" ] || { echo "ffdec.sh: no scripts exported" >&2; exit 3; }
    ;;
  replace-as3|replace-pcode)
    [ $# -ge 4 ] && [ $(( ($# - 2) % 2 )) -eq 0 ] || usage
    in=$1; out=$2; shift 2
    [ -f "$in" ] || { echo "ffdec.sh: no such file $in" >&2; exit 1; }
    args=("$@")
    for ((i = 1; i < ${#args[@]}; i += 2)); do
      [ -f "${args[i]}" ] || { echo "ffdec.sh: no such file ${args[i]}" >&2; exit 1; }
    done
    if [ "$cmd" = replace-pcode ]; then
      # AS2 script names need the leading slash (/frame_1/DoAction), no .pcode suffix
      for ((i = 0; i < ${#args[@]}; i += 2)); do
        case "${args[i]}" in /*) ;; *) echo "ffdec.sh: P-code script name must start with / : ${args[i]}" >&2; exit 1 ;; esac
      done
    fi
    rm -f "$out"
    run_ffdec -replace "$in" "$out" "${args[@]}"
    [ -s "$out" ] || { echo "ffdec.sh: $out was not written; ffdec reported an error above" >&2; exit 3; }
    ;;
  raw)
    run_ffdec "$@" ;;
  *) usage ;;
esac
