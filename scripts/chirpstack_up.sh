#!/bin/bash
# Bring up the ChirpStack stack the LoRaWAN scenarios talk to.
#
# Usage:  chirpstack_up.sh [-d]
#   -d   stop the stack instead of starting it
#   -h   this help
#
# Exists because `docker compose up -d` alone does not work on a fresh clone. The submodule
# ships an already-provisioned PostgreSQL data directory, so the scenarios start with the
# devices registered rather than needing an initdb -- but git cannot store an empty
# directory, and PostgreSQL wants ten of them empty. The submodule keeps them with .gitkeep
# placeholders, and PostgreSQL treats *every* entry under pg_tblspc/ as a tablespace link
# and opens it as a directory:
#
#   FATAL: could not open directory "pg_tblspc/.gitkeep/PG_14_202107181": Not a directory
#
# Deleting the placeholders from the submodule would not fix it either: those directories
# hold nothing else, so they would stop existing in a clone, and the server does not
# recreate them -- initdb does, and initdb never runs here. So the directories have to be
# created outside git, which is what this script does before starting the stack. Both halves
# are idempotent, and safe whether or not the placeholders are still shipped.
set -eo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
STACK="$ROOT/labscim-chirpstack-docker"
PGDATA="$STACK/postgresqldata"

die() { echo "ABORTED: $*" >&2; exit 1; }

DOWN=""
while getopts "dh" o; do
    case $o in
        d) DOWN=1 ;;
        h) sed -n '2,/^[^#]/p' "$0" | sed '$d'; exit 0 ;;
        *) exit 1 ;;
    esac
done

[ -d "$STACK" ] || die "ChirpStack submodule missing: $STACK
  get it with: git submodule update --init"

if [ -n "$DOWN" ]; then
    cd "$STACK" && exec docker compose down
fi

# The set PostgreSQL 14 expects to find, and to find empty.
EMPTY_DIRS=(
    pg_commit_ts pg_notify pg_replslot pg_snapshots pg_stat_tmp pg_tblspc pg_twophase
    pg_logical/mappings pg_logical/snapshots pg_wal/archive_status
)

[ -d "$PGDATA" ] || die "PostgreSQL data directory missing: $PGDATA"

for d in "${EMPTY_DIRS[@]}"; do
    mkdir -p "$PGDATA/$d" 2>/dev/null || die "cannot create $PGDATA/$d
  Docker runs PostgreSQL as root, so a directory left over from an earlier run may be
  root-owned. Retry with: sudo mkdir -p '$PGDATA/$d'"
    marker="$PGDATA/$d/.gitkeep"
    if [ -e "$marker" ]; then
        rm -f "$marker" || die "cannot remove $marker -- see the note above about ownership"
    fi
done

cd "$STACK"
docker compose up -d
echo
docker compose ps
