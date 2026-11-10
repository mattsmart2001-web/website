#!/usr/bin/env bash
#
# Build the whole GTEC schema on a throwaway Postgres and drive live_beacon
# through it.
#
# The migrations in the folder above are applied to Supabase by hand, which
# means until now nothing in here had ever been run anywhere but production.
# That was fine for a column rename and not fine for the beacon, which is
# four hundred lines of judgement about whether a lap counts, changed on a
# race week, by someone who cannot see the database.
#
# Everything here is local and disposable. It touches nothing real: no
# Supabase project, no key, no network.
#
#   ./run.sh            apply every migration, then run every test
#   ./run.sh 5433       the same, on a port of your choosing
#
# Needs postgresql-16 (or any 14+) on the path. It will not run as root,
# which is Postgres's rule rather than ours, so it uses an unprivileged
# user if it finds one and tells you if it cannot.
set -euo pipefail

PORT="${1:-5433}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SQL="$(dirname "$HERE")"
RUN="${TMPDIR:-/tmp}/gtec-pgtest"
BIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"
BIN="${BIN:-$(dirname "$(command -v initdb)")}"
PSQL=(psql -h "${TMPDIR:-/tmp}" -p "$PORT" -U postgres)

AS=()
if [ "$(id -u)" = 0 ]; then
    id pgrun >/dev/null 2>&1 || useradd -m pgrun
    AS=(su pgrun -c)
fi
as() { if [ ${#AS[@]} -gt 0 ]; then "${AS[@]}" "$*"; else eval "$*"; fi; }

rm -rf "$RUN"; mkdir -p "$RUN"
[ ${#AS[@]} -gt 0 ] && chown pgrun "$RUN"
as "$BIN/initdb -D $RUN/data -U postgres" >/dev/null
as "$BIN/pg_ctl -D $RUN/data -o '-p $PORT -k ${TMPDIR:-/tmp}' -l $RUN/log start" >/dev/null
trap 'as "$BIN/pg_ctl -D $RUN/data stop" >/dev/null 2>&1 || true' EXIT
sleep 2

"${PSQL[@]}" -q -c "CREATE DATABASE gtec;"
DB=("${PSQL[@]}" -d gtec -v ON_ERROR_STOP=1 -q)

echo "applying the Supabase stubs the migrations expect"
"${DB[@]}" -f "$HERE/00_prelude.sql" 2>&1 | grep -v "wal_level\|HINT" || true

echo "applying every migration in order"
fails=0
for f in $(ls "$SQL"/*.sql | xargs -n1 basename | sort -n); do
    if ! out=$("${DB[@]}" -f "$SQL/$f" 2>&1); then
        fails=$((fails + 1))
        echo "  FAILED $f"
        echo "$out" | grep ERROR | head -2 | sed 's/^/    /'
    fi
done
echo "  $fails failed"

echo
echo "a round at a 13.6 km circuit, outline traced from the line"
"${DB[@]}" -f "$HERE/01_fixture.sql" >/dev/null

for t in "$HERE"/0[23]_*.sql; do
    echo
    echo "$(basename "$t")"
    "${PSQL[@]}" -d gtec -tq -f "$t" 2>&1 | grep -E "laps logged|last on|best on" || true
    "${DB[@]}" -f "$HERE/01_fixture.sql" >/dev/null
done

# Tests that are not about the beacon print their own lines, so they are
# shown as they come rather than grepped for the three the beacon tests
# emit. The fixture is reloaded after each, as above, so one test cannot
# leave anything behind for the next.
for t in "$HERE"/0[4-9]_*.sql; do
    [ -e "$t" ] || continue
    "${PSQL[@]}" -d gtec -tq -f "$t" 2>&1 | grep -vE "^(SET|INSERT|UPDATE|DELETE|SELECT)" || true
    "${DB[@]}" -f "$HERE/01_fixture.sql" >/dev/null
done

cat <<'EXPECTED'

What these should say, with 204 applied:

  02_pit_out_lap    laps logged:    210000, 400000, 209000
                    last on screen: 209000
                    best on screen: 209000

      The 3:30 is a clean lap. The 6:40 is the in-lap with the stop in it,
      which is a real lap driven from the line and belongs in the log. The
      3:10 is the out-lap, timed by GT7 from the pit exit, and it is gone.
      Without 204 it is logged, shown as Last, and takes the best lap,
      which is the whole point of that migration.

  03_clean_laps     laps logged:    211000, 210000, 209500
                    best on screen: 209500

      Nobody pits, so nothing may be lost. Three laps from four crossings:
      the first is the one 184 sets aside, because a car's opening lap is
      whatever GT7 was timing when its session began.
EXPECTED
