#!/usr/bin/env bash
# tlc.sh [--set NAME] [flow...]: model-checks tla/build/MC_<flow> (from
# mkconf.py) with at most 2 workers; logs to tla/build/<flow>.log. With
# --set, the set's build directory (scripts/flowsets.py; default probes);
# with no flow named, every flow of the set's flows file. Exits nonzero if
# any run fails (TLC's exit status, or a log without TLC's success line).
#   TLA2TOOLS_JAR   tla2tools.jar (default: ../tools/tla2tools.jar)
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
set_name=probes
if [ "${1:-}" = --set ]; then
  set_name=${2:?tlc.sh: --set needs a set name}
  shift 2
fi
build=$(python3 "$here/scripts/flowsets.py" "$set_name" build) || exit 2
if [ $# -eq 0 ]; then
  flows=$(python3 "$here/scripts/flowsets.py" "$set_name" flows) || exit 2
  set -- $(python3 -c 'import sys, tomllib; print(" ".join(f["name"] for f in tomllib.load(open(sys.argv[1], "rb"))["flow"]))' "$flows")
fi
jar=${TLA2TOOLS_JAR:-$here/../tools/tla2tools.jar}
jar="$(cd "$(dirname "$jar")" && pwd)/$(basename "$jar")"
[ -f "$jar" ] || { echo "tlc.sh: no tla2tools.jar at $jar (set TLA2TOOLS_JAR)" >&2; exit 2; }
lib="$here/../modules:$here/tla"
cd "$build" || exit 2
failed=()
for f in "$@"; do
  meta=$(mktemp -d /tmp/tlc-ws2-conf.XXXXXX)
  mkdir "$meta/jtmp"   # private java.io.tmpdir: TLC unpacks its standard modules there
  java -XX:+UseParallelGC -Xss16m -Djava.io.tmpdir="$meta/jtmp" -DTLA-Library="$lib" -cp "$jar" tlc2.TLC \
    -workers 2 -deadlock -metadir "$meta" -config "MC_$f.cfg" "MC_$f" > "$f.log" 2>&1
  rc=$?
  rm -rf "$meta"
  sed -i.bak "s#$HOME#~#g" "$f.log" && rm -f "$f.log.bak"
  if [ $rc -ne 0 ] || ! grep -q 'Model checking completed. No error has been found' "$f.log"; then
    failed+=("$f")
    printf '%-24s FAILED (exit %s): %s\n' "$f" "$rc" "$(grep -m2 -E 'Error|error' "$f.log" | tr '\n' ' ')"
  else
    printf '%-24s ok (%s)\n' "$f" "$(grep -m1 -oE '[0-9]+ distinct states generated' "$f.log")"
  fi
done
if [ ${#failed[@]} -gt 0 ]; then
  echo "tlc.sh: ${#failed[@]} run(s) failed: ${failed[*]}" >&2
  exit 1
fi
