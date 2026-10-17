#!/usr/bin/env bash
#
# dlq-redrive.sh — inspect and safely replay Kafka dead-letter topics (.dlq).
#
# Fleet convention: consumers dead-letter poison messages to <source-topic>.dlq
# with headers x-dlq-source-topic / x-dlq-error / x-dlq-failed-at. Until now no
# tool anywhere in the fleet could inspect or replay a DLQ; this is it.
# Operational runbook: docs/dlq-runbook.md.
#
# Broker access: the single in-cluster broker advertises in-cluster DNS, so
# kubectl port-forward does NOT work. Every Kafka CLI call below runs inside the
# broker pod via `kubectl exec -n warehouse-systems kafka-controller-0 -c kafka`
# against --bootstrap-server localhost:9092. Override with DLQ_REDRIVE_NAMESPACE /
# DLQ_REDRIVE_POD / DLQ_REDRIVE_CONTAINER / DLQ_REDRIVE_BOOTSTRAP.
#
# Per .claude/rules/events-cloudevents.md every kafka-*.sh invocation inside the
# pod is prefixed `env KAFKA_HEAP_OPTS=-Xmx128m` — the CLI tools share the broker
# container's memory limit and their full-heap defaults have OOMKilled the broker.
#
# !! HEADERS ARE DROPPED ON REDRIVE — ACCEPTED AND KNOWN !!!
# kafka-console-producer.sh cannot write Kafka record headers, so a redriven
# message loses x-dlq-*, traceparent and content-type. This is deliberate and
# safe: every fleet message is a CloudEvents 1.0 event in structured content
# mode, so the `id` attribute lives INSIDE the JSON value and is stable across
# redelivery; every fleet consumer dedupes on it. A redriven message the
# consumer already processed is a no-op there, which is what makes redrive
# re-runnable. Values are single-line JSON (control chars escaped), so
# line-oriented piping between consumer and producer is safe.
#
# Safety rails:
#   - DRY-RUN IS THE DEFAULT. Republishing requires `--execute --yes`;
#     `--execute` without `--yes` refuses and exits 2.
#   - Refuses any --topic not matching the glob `warehouse.*.dlq`.
#   - Never writes to a .dlq topic: each selected message is republished to its
#     own x-dlq-source-topic header, which must be present, must look like a
#     fleet topic (warehouse.*) and must NOT end in .dlq (redrive-loop guard).
#   - Prints the target source topic(s) and total count BEFORE the first write
#     and again at the end. Any validation failure aborts before the first
#     write (fail closed).
#   - set -euo pipefail throughout.
#
# Message selection consumes the whole DLQ topic with all print properties and
# parses each line  CreateTime:<ms>\tPartition:<p>\tOffset:<o>\t<headers>\t<value>
# with awk (tab-separated, the JSON value is the last field). The headers field
# is comma-separated key:value pairs; a comma inside a header value is kept by
# merging any non `key:`-shaped fragment back into the previous header.
#
# Usage:
#   scripts/dlq-redrive.sh --list
#   scripts/dlq-redrive.sh --topic warehouse.slotting-optimization.events.dlq
#   scripts/dlq-redrive.sh --topic warehouse.X.events.dlq --error "unknown process path"
#   scripts/dlq-redrive.sh --topic warehouse.X.events.dlq --type SlotPlanApproved \
#                          --since 2026-10-14T00:00:00Z --max 10
#   scripts/dlq-redrive.sh --topic warehouse.X.events.dlq --error "..." --execute --yes
#
# Exit codes: 0 success (a dry-run that selects 0 messages is still success),
# 1 operational error or refused safety check, 2 --execute without --yes.
set -euo pipefail

readonly NAMESPACE="${DLQ_REDRIVE_NAMESPACE:-warehouse-systems}"
readonly POD="${DLQ_REDRIVE_POD:-kafka-controller-0}"
readonly CONTAINER="${DLQ_REDRIVE_CONTAINER:-kafka}"
readonly BOOTSTRAP="${DLQ_REDRIVE_BOOTSTRAP:-localhost:9092}"
readonly CONSUMER_TIMEOUT_MS="${DLQ_REDRIVE_TIMEOUT_MS:-15000}"

TMP_SCAN=""
TMP_SEL=""
cleanup() { rm -f "${TMP_SCAN:-}" "${TMP_SEL:-}"; }
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage: dlq-redrive.sh --list
       dlq-redrive.sh --topic <dlq-topic> [filters] [--execute --yes]

Inspect and replay Kafka dead-letter topics (warehouse.*.dlq).

Modes:
  --list                  Every .dlq topic: message count and the distinct
                          x-dlq-error values grouped with counts.
  --topic <dlq-topic>     The DLQ to dry-run (default) or redrive.
                          Must match the glob warehouse.*.dlq.

Filters (apply to dry-run and execute):
  --error <substring>     Select messages whose x-dlq-error contains this.
  --type <suffix>         Select messages whose CloudEvents type ends with
                          this suffix (e.g. SlotPlanApproved).
  --since <RFC3339>       Select messages with CreateTime >= this instant
                          (e.g. 2026-10-14T00:00:00Z; UTC).
  --max <n>               Stop after n selected messages (0 = unlimited).

Execution:
  --execute --yes         Actually republish the selected messages to their
                          x-dlq-source-topic. DRY-RUN IS THE DEFAULT;
                          --execute without --yes refuses and exits 2.

Env overrides: DLQ_REDRIVE_NAMESPACE (warehouse-systems),
DLQ_REDRIVE_POD (kafka-controller-0), DLQ_REDRIVE_CONTAINER (kafka),
DLQ_REDRIVE_BOOTSTRAP (localhost:9092), DLQ_REDRIVE_TIMEOUT_MS (15000).

Headers (x-dlq-*, traceparent, content-type) are DROPPED on redrive —
kafka-console-producer cannot write them. Dedupe safety comes from the
CloudEvents id inside the structured-mode value; fleet consumers dedupe on it.
USAGE
}

die() { echo "dlq-redrive: $*" >&2; exit 1; }

# GNU date can parse arbitrary RFC3339 (probe: @0 -> 1970); BSD date cannot
# (its -d flag means something else), hence the -j -f fallback below.
if [ "$(date -u -d @0 +%Y 2>/dev/null)" = "1970" ]; then
  DATE_IS_GNU=1
else
  DATE_IS_GNU=0
fi

fmt_ts_iso() { # <epoch-ms> -> RFC3339 UTC with milliseconds
  local ms="$1" s rem
  s=$(( ms / 1000 ))
  rem=$(( ms % 1000 ))
  if [ "$DATE_IS_GNU" -eq 1 ]; then
    # shellcheck disable=SC2312  # the date call cannot mask a pipeline failure
    printf '%s.%03dZ\n' "$(date -u -d "@${s}" +%Y-%m-%dT%H:%M:%S)" "$rem"
  else
    printf '%s.%03dZ\n' "$(date -u -r "${s}" +%Y-%m-%dT%H:%M:%S)" "$rem"
  fi
}

rfc3339_to_epoch_ms() { # <RFC3339> -> epoch milliseconds on stdout
  local t="$1" s="" norm=""
  if [ "$DATE_IS_GNU" -eq 1 ]; then
    s="$(date -u -d "$t" +%s 2>/dev/null)" || s=""
    case "$s" in ''|*[!0-9]*)
      die "--since '$t': GNU date cannot parse it (use RFC3339, e.g. 2026-10-14T00:00:00Z)" ;;
    esac
  else
    norm="${t%%.*}"   # drop fractional seconds
    norm="${norm%Z}"  # drop trailing Z; UTC assumed on the BSD fallback
    s="$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$norm" +%s 2>/dev/null)" || s=""
    case "$s" in ''|*[!0-9]*)
      die "--since '$t': BSD date fallback needs UTC seconds precision (YYYY-MM-DDTHH:MM:SS[Z])" ;;
    esac
  fi
  printf '%s\n' "$(( s * 1000 ))"
}

pod_kafka() { # <command string> — run a Kafka CLI command inside the broker pod
  kubectl exec -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- \
    bash -c "env KAFKA_HEAP_OPTS=-Xmx128m $1"
}

pod_produce_stdin() { # <target topic> — console producer reading lines from stdin
  kubectl exec -i -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- \
    bash -c "env KAFKA_HEAP_OPTS=-Xmx128m kafka-console-producer.sh --bootstrap-server $BOOTSTRAP --topic $1"
}

# scan_dlq <topic> <err-substring|''> <type-suffix|''> <since-ms|0> <max|0>
# Emits one TSV line per SELECTED message:
#   ts_ms \t partition \t offset \t x-dlq-error \t x-dlq-source-topic \t ce-type \t ce-id
# followed by a final "#SCANNED <n>" marker (messages seen before filtering).
# Filter values are passed through the environment (not -v) so arbitrary
# strings reach awk verbatim.
scan_dlq() {
  local topic="$1" err_sub="$2" type_suf="$3" since_ms="$4" max_n="$5"
  local consumer_cmd
  consumer_cmd="kafka-console-consumer.sh --bootstrap-server $BOOTSTRAP --topic $topic --from-beginning --property print.headers=true --property print.timestamp=true --property print.partition=true --property print.offset=true --timeout-ms $CONSUMER_TIMEOUT_MS"
  pod_kafka "$consumer_cmd" \
    | DLQR_ERR_SUB="$err_sub" DLQR_TYPE_SUF="$type_suf" DLQR_SINCE_MS="$since_ms" DLQR_MAX="$max_n" awk -F '\t' '
      BEGIN {
        errsub  = ENVIRON["DLQR_ERR_SUB"]
        typesuf = ENVIRON["DLQR_TYPE_SUF"]
        sincems = ENVIRON["DLQR_SINCE_MS"] + 0
        maxn    = ENVIRON["DLQR_MAX"] + 0
        selected = 0; scanned = 0; donemax = 0
      }
      /^CreateTime:/ {
        scanned++
        if (donemax) next
        ts = substr($1, 12) + 0
        pa = substr($2, 11) + 0
        of = substr($3, 8) + 0
        val = $5
        for (i = 6; i <= NF; i++) val = val "\t" $i
        # headers field: comma-separated key:value; merge fragments that do not
        # start a new key back into the previous value (comma inside a value)
        split("", hk); split("", hv); nh = 0
        m = split($4, hh, ",")
        for (i = 1; i <= m; i++) {
          if (hh[i] ~ /^[A-Za-z0-9!#$%&*+.^_|~-]+:/) {
            c = index(hh[i], ":")
            nh++
            hk[nh] = substr(hh[i], 1, c - 1)
            hv[nh] = substr(hh[i], c + 1)
          } else if (nh > 0) {
            hv[nh] = hv[nh] "," hh[i]
          }
        }
        err = ""; src = ""
        for (i = 1; i <= nh; i++) {
          if (hk[i] == "x-dlq-error") err = hv[i]
          else if (hk[i] == "x-dlq-source-topic") src = hv[i]
        }
        # first "id":" / "type":" match wins: in structured mode the CloudEvents
        # envelope attributes are printed before data, so that is the real id/type
        ceid = ""; cetype = ""
        if (match(val, /"id":"[^"]*"/)) ceid = substr(val, RSTART + 6, RLENGTH - 7)
        if (match(val, /"type":"[^"]*"/)) cetype = substr(val, RSTART + 8, RLENGTH - 9)
        if (errsub != "" && index(err, errsub) == 0) next
        if (typesuf != "" && (cetype == "" || substr(cetype, length(cetype) - length(typesuf) + 1) != typesuf)) next
        if (sincems > 0 && ts < sincems) next
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", ts, pa, of, err, src, cetype, ceid
        selected++
        if (maxn > 0 && selected >= maxn) donemax = 1
        next
      }
      END { print "#SCANNED " scanned }
    '
}

cmd_list() {
  local topics t n tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/dlq-redrive.XXXXXXXX")"
  if ! pod_kafka "kafka-topics.sh --bootstrap-server $BOOTSTRAP --list" > "$tmp"; then
    die "could not list topics on the broker (kubectl exec failed — cluster or broker container may be down/pressured)"
  fi
  topics="$(grep -E '\.dlq$' "$tmp" || true)"
  if [ -z "$topics" ]; then
    echo "no .dlq topics on the broker"
    rm -f "$tmp"
    return 0
  fi
  for t in $topics; do
    # A scan can die (e.g. exec'd JVM OOM-killed when the broker container is
    # memory-pressured): report the partial count as a lower bound, keep going.
    if scan_dlq "$t" "" "" 0 0 > "$tmp"; then
      n="$(awk '/^#SCANNED / {next} {c++} END {print c + 0}' "$tmp")"
      printf '%s  messages=%s\n' "$t" "$n"
    else
      rc=1
      n="$(awk '/^#SCANNED / {next} {c++} END {print c + 0}' "$tmp")"
      printf '%s  messages=%s (SCAN INTERRUPTED — count is a lower bound)\n' "$t" "$n"
      continue
    fi
    if [ "$n" -gt 0 ]; then
      printf '  errors (count x value):\n'
      awk -F '\t' '/^#SCANNED / {next} {print ($4 == "" ? "(no x-dlq-error header)" : $4)}' "$tmp" \
        | sort | uniq -c | sort -rn | sed 's/^/    /'
    fi
  done
  rm -f "$tmp"
  exit "$rc"
}

describe_filters() {
  local parts="" sep=""
  [ -n "$ERR_FILTER" ] && { parts="${parts}${sep}--error \"${ERR_FILTER}\""; sep=" "; }
  [ -n "$TYPE_FILTER" ] && { parts="${parts}${sep}--type \"${TYPE_FILTER}\""; sep=" "; }
  [ "$SINCE_MS" -gt 0 ] && { parts="${parts}${sep}--since (epoch ms ${SINCE_MS})"; sep=" "; }
  [ "$MAX" -gt 0 ] && { parts="${parts}${sep}--max ${MAX}"; }
  if [ -n "$parts" ]; then echo "$parts"; else echo "(none)"; fi
}

missing_arg() {
  echo "dlq-redrive: option $1 requires a value" >&2
  exit 1
}

# ---------------------------------------------------------------- arguments --
DO_LIST=0
TOPIC=""
ERR_FILTER=""
TYPE_FILTER=""
SINCE=""
SINCE_MS=0
MAX=0
EXECUTE=0
YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --list)    DO_LIST=1 ;;
    --topic)   [ $# -ge 2 ] || missing_arg "$1"; TOPIC="$2"; shift ;;
    --error)   [ $# -ge 2 ] || missing_arg "$1"; ERR_FILTER="$2"; shift ;;
    --type)    [ $# -ge 2 ] || missing_arg "$1"; TYPE_FILTER="$2"; shift ;;
    --since)   [ $# -ge 2 ] || missing_arg "$1"; SINCE="$2"; shift ;;
    --max)     [ $# -ge 2 ] || missing_arg "$1"; MAX="$2"; shift ;;
    --execute) EXECUTE=1 ;;
    --yes)     YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         echo "dlq-redrive: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

case "$MAX" in
  ''|*[!0-9]*) die "--max must be a non-negative integer, got '$MAX'" ;;
esac
[ -n "$SINCE" ] && SINCE_MS="$(rfc3339_to_epoch_ms "$SINCE")"

# ------------------------------------------------------------------ dispatch --
if [ "$DO_LIST" -eq 1 ]; then
  [ -n "$TOPIC" ] && die "--list scans every .dlq topic; do not pass --topic with it"
  [ "$EXECUTE" -eq 1 ] && die "--list is read-only; --execute does not apply to it"
  cmd_list
  exit 0
fi

[ -n "$TOPIC" ] || { usage >&2; echo >&2; die "a --topic is required for redrive operations"; }

case "$TOPIC" in
  warehouse.*.dlq) : ;;
  *) die "refusing: --topic must match 'warehouse.*.dlq', got '$TOPIC'" ;;
esac

TMP_SCAN="$(mktemp "${TMPDIR:-/tmp}/dlq-redrive.XXXXXXXX")"
TMP_SEL="$(mktemp "${TMPDIR:-/tmp}/dlq-redrive.XXXXXXXX")"
if ! pod_kafka "kafka-topics.sh --bootstrap-server $BOOTSTRAP --list" > "$TMP_SEL"; then
  die "could not list topics on the broker (kubectl exec failed — cluster or broker container may be down/pressured)"
fi
if ! grep -qx "$TOPIC" "$TMP_SEL"; then
  die "topic '$TOPIC' does not exist on the broker"
fi

if ! scan_dlq "$TOPIC" "$ERR_FILTER" "$TYPE_FILTER" "$SINCE_MS" "$MAX" > "$TMP_SCAN"; then
  die "scan of $TOPIC failed (broker container may be memory-pressured — see stderr above; nothing was republished)"
fi
scanned="$(sed -n 's/^#SCANNED //p' "$TMP_SCAN")"
scanned="${scanned:-0}"
awk '/^#SCANNED / {next} {print}' "$TMP_SCAN" > "$TMP_SEL"
selected="$(awk 'END {print NR + 0}' "$TMP_SEL")"

# ------------------------------------------------------------------- dry-run --
if [ "$EXECUTE" -eq 0 ]; then
  echo "==> dry-run: $TOPIC"
  echo "==> filters: $(describe_filters)"
  echo "==> partition  offset  timestamp / error / type / CloudEvents id / target"
  while IFS=$'\t' read -r ts p o err src cetype ceid; do
    printf '    p=%s\to=%s\t%s\n' "$p" "$o" "$(fmt_ts_iso "$ts")"
    printf '        err="%s"\n' "${err:-(no x-dlq-error header)}"
    printf '        type=%s\n' "${cetype:-(no CloudEvents type)}"
    printf '        id=%s\n' "${ceid:-(no CloudEvents id)}"
    printf '        target=%s\n' "${src:-(MISSING x-dlq-source-topic — would be refused)}"
  done < "$TMP_SEL"
  echo "==> selected $selected of $scanned message(s) from $TOPIC"
  echo "==> nothing was republished (dry-run is the default; add --execute --yes to republish)"
  exit 0
fi

# ------------------------------------------------------------------- execute --
if [ "$YES" -ne 1 ]; then
  echo "dlq-redrive: --execute given without --yes: refusing to republish." >&2
  echo "dlq-redrive: re-run the DRY-RUN first, have it reviewed, then add --yes." >&2
  exit 2
fi

if [ "$selected" -eq 0 ]; then
  echo "==> 0 message(s) selected — nothing to do."
  exit 0
fi

# Fail closed: validate every target BEFORE the first write, and print the
# target source topic(s) with their counts before writing anything.
echo "==> EXECUTE: republishing $selected of $scanned message(s) from $TOPIC"
echo "==> filters: $(describe_filters)"
while IFS=$'\t' read -r cnt src; do
  case "$src" in
    *.dlq) die "refusing: x-dlq-source-topic '$src' ends in .dlq (redrive loop)" ;;
    warehouse.*) : ;;
    *) die "refusing: x-dlq-source-topic '$src' is not a fleet topic (warehouse.*)" ;;
  esac
  printf '==> target source topic: %s (%s message(s))\n' "$src" "$cnt"
done < <(awk -F '\t' '/^#SCANNED / {next} {c[$5]++} END {for (s in c) print c[s] "\t" s}' "$TMP_SCAN" | sort -k2)

i=0
while IFS=$'\t' read -r ts p o err src cetype ceid; do
  i=$(( i + 1 ))
  # Consume EXACTLY this message: explicit partition+offset, one message, no
  # print properties, so stdout is the bare value (first line).
  raw="$(pod_kafka "kafka-console-consumer.sh --bootstrap-server $BOOTSTRAP --topic $TOPIC --partition $p --offset $o --max-messages 1 --timeout-ms $CONSUMER_TIMEOUT_MS")"
  value="$(printf '%s\n' "$raw" | awk 'NR == 1 {print; exit}')"
  case "$value" in
    '{'*) : ;;
    *) die "message p=$p o=$o: consumer stdout was not a JSON object (got: ${value:0:80}) — aborting before any further writes" ;;
  esac
  printf '  [%d/%d] p=%s o=%s id=%s -> %s\n' "$i" "$selected" "$p" "$o" "${ceid:--}" "$src"
  printf '%s\n' "$value" | pod_produce_stdin "$src"
done < "$TMP_SEL"

echo "==> DONE: republished $i message(s) from $TOPIC to:"
awk -F '\t' '/^#SCANNED / {next} {c[$5]++} END {for (s in c) printf "==> target source topic: %s (%s message(s))\n", s, c[s]}' "$TMP_SCAN"
echo "==> remember: headers were dropped; consumers dedupe on the CloudEvents id in the value."
