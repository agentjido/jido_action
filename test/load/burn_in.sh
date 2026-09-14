#!/bin/sh
set -eu

runs=${1:-10}

case "$runs" in
  ''|*[!0-9]*) echo "run count must be a positive integer" >&2; exit 2 ;;
esac

if [ "$runs" -lt 1 ]; then
  echo "run count must be a positive integer" >&2
  exit 2
fi

index=0
while [ "$index" -lt "$runs" ]; do
  seed=$((20260914 + index))
  echo "load run $((index + 1))/$runs seed=$seed"
  JIDO_ACTION_LOAD_SEED="$seed" mix test.load
  index=$((index + 1))
done
