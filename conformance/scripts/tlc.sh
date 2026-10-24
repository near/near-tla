#!/usr/bin/env bash
# tlc.sh <flow>...: model-checks tla/build/MC_<flow> (from mkconf.py) with
# at most 2 workers; logs to tla/build/<flow>.log.
#   TLA2TOOLS_JAR   tla2tools.jar (default: ../tools/tla2tools.jar)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
jar=${TLA2TOOLS_JAR:-$here/../tools/tla2tools.jar}
jar="$(cd "$(dirname "$jar")" && pwd)/$(basename "$jar")"
lib="$here/../modules:$here/tla"
cd "$here/tla/build"
for f in "$@"; do
  meta=$(mktemp -d /tmp/tlc-ws2-conf.XXXXXX)
  java -XX:+UseParallelGC -DTLA-Library="$lib" -cp "$jar" tlc2.TLC \
    -workers 2 -deadlock -metadir "$meta" -config "MC_$f.cfg" "MC_$f" > "$f.log" 2>&1 || true
  rm -rf "$meta"
  sed -i.bak "s#$HOME#~#g" "$f.log" && rm -f "$f.log.bak"
  printf '%-24s %s\n' "$f" "$(grep -E 'states generated|Error|error' "$f.log" | head -2 | tr '\n' ' ')"
done
