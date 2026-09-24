#!/usr/bin/env bash
# Regression guard for the exact invariant CLAUDE.md calls out: "BOOL_FLAGS
# must stay in sync with which parse_args cases take no value (shift vs
# shift 2)". Parses parse_args()'s own source text (not by running it) and
# cross-checks against the real BOOL_FLAGS array.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../../wg-fulltunnel.sh"
source "$HERE/../lib/unit_helpers.sh"
source_wgft_functions "$SCRIPT"

parse_args_body=$(awk '/^parse_args\(\) \{/{flag=1; next} flag && /^}/{flag=0} flag' "$SCRIPT")

value_flags=()
noarg_flags=()
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*([-A-Za-z0-9|]+)\) ]] || continue
  names="${BASH_REMATCH[1]}"
  if [[ "$line" == *"shift 2"* ]]; then
    for n in ${names//|/ }; do
      [[ "$n" == --* ]] && value_flags+=("${n#--}")
    done
  elif [[ "$line" == *"shift"* ]]; then
    for n in ${names//|/ }; do
      [[ "$n" == --* ]] && noarg_flags+=("${n#--}")
    done
  fi
  # Anything with neither (e.g. --config-example, -h|--help: usage; exit 0)
  # exits immediately and is exempt - is_bool_flag() correctness for those
  # doesn't matter since --config can never reach them mid-parse anyway.
done <<< "$parse_args_body"

in_array() {
  local needle=$1; shift
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

for f in "${noarg_flags[@]}"; do
  if in_array "$f" "${BOOL_FLAGS[@]}"; then
    ok "no-value flag '--$f' is listed in BOOL_FLAGS"
  else
    fail "no-value flag '--$f' takes no argument in parse_args() (bare 'shift') but is MISSING from BOOL_FLAGS - a config file's '$f=true' would be silently misparsed"
  fi
done

for b in "${BOOL_FLAGS[@]}"; do
  if in_array "$b" "${value_flags[@]}"; then
    fail "BOOL_FLAGS entry '$b' actually takes a value ('shift 2') in parse_args() - stale entry, config files would drop the next real argument"
  else
    ok "BOOL_FLAGS entry '$b' matches a no-value case in parse_args() (or a case that exits immediately)"
  fi
done

finish
