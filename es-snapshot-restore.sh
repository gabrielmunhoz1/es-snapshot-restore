#!/usr/bin/env bash
# =============================================================================
#  es-snapshot-restore.sh
#
#  Migrates indices from one Elasticsearch 6.8 cluster (SOURCE / production) to
#  another (DESTINATION) using snapshot/restore.
#
#  - Creates a new snapshot on the source OR lists existing ones (e.g. curator's)
#  - Restores on the destination by reading the source repository registered as
#    READ-ONLY on the destination (the restore never touches the production cluster)
#  - Keeps primary shards / replicas of the indices (no index_settings are sent)
#
#  Usage: ./es-snapshot-restore.sh [-c config.env] [command]
#         ./es-snapshot-restore.sh --help
# =============================================================================
set -uo pipefail

SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
readonly POLL_INTERVAL=30   # seconds between progress checks (snapshot and restore)

# ----------------------------------------------------------------------------
# Output / logging
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_CYN=$'\e[36m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_CYN=""; C_BLD=""; C_RST=""
fi

LOG_FILE=""
TMP_DIR=""
ES_RESP=""
ES_CODE=""
ES_CURL_ERR=""
_INTERRUPTED=0
SELECTED_SNAPSHOT=""
SRC_NAME=""; SRC_UUID=""; SRC_VERSION=""
DST_NAME=""; DST_UUID=""; DST_VERSION=""
PF_RO_REPO_MISSING=0
PF_SOURCE_REPO_RO=0

_log_file() { [[ -n $LOG_FILE ]] && printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG_FILE"; return 0; }
info()  { printf '%s\n' "$*"; _log_file INFO "$*"; }
ok()    { printf '%s[OK]%s %s\n' "$C_GRN" "$C_RST" "$*"; _log_file OK "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; _log_file WARN "$*"; }
err()   { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; _log_file ERROR "$*"; }
title() { printf '\n%s== %s ==%s\n' "$C_BLD$C_CYN" "$*" "$C_RST"; _log_file INFO "== $* =="; }
die()   { err "$*"; exit 1; }

# Confirmation: only proceeds if the user types exactly y or Y.
confirm_yes() {
  local ans=""
  printf '%s%s%s\n' "$C_BLD" "$1" "$C_RST"
  read -r -p "Type 'y' or 'Y' to confirm (anything else cancels): " ans || ans=""
  _log_file INPUT "$1 -> '$ans'"
  [[ $ans == "y" || $ans == "Y" ]]
}

side_label() { [[ $1 == source ]] && echo "SOURCE" || echo "DESTINATION"; }

human_bytes() {
  awk -v b="${1:-0}" 'BEGIN { split("B KB MB GB TB PB", u, " "); i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ } printf "%.1f %s", b, u[i] }'
}

fmt_duration() { local s=${1:-0}; printf '%02d:%02d:%02d' $((s / 3600)) $((s % 3600 / 60)) $((s % 60)); }

ver_num() { local a b c; IFS=. read -r a b c <<<"${1%%-*}"; echo $(( ${a:-0} * 1000000 + ${b:-0} * 1000 + ${c:-0} )); }

urlenc() { jq -rn --arg s "$1" '$s | @uri'; }

# Reads names (one per line) from stdin and prints comma-separated batches of at
# most N characters (avoids URLs too long for the nginx ingress).
make_batches() {
  awk -v max="${1:-3000}" '
    NF == 0 { next }
    { if (line != "" && length(line) + length($0) + 1 > max) { print line; line = $0 }
      else { line = (line == "" ? $0 : line "," $0) } }
    END { if (line != "") print line }'
}

# ----------------------------------------------------------------------------
# Shared jq functions
# ----------------------------------------------------------------------------
read -r -d '' JQ_LIB <<'JQEOF' || true
def wc2re: "^" + (split("*") | map(gsub("(?<c>[\\\\.^$|?+()\\[\\]{}])"; "\\\(.c)")) | join(".*")) + "$";
def es_patterns($p): [ $p | split(",")[] | select(length > 0) | {ex: startswith("-"), re: (ltrimstr("-") | wc2re)} ];
def es_match($P): . as $n | reduce $P[] as $p (false; if ($n | test($p.re)) then ($p.ex | not) else . end);
def to_set: reduce .[] as $x ({}; .[$x] = true);
def repo_loc: [ (.type // ""), (.settings.container // .settings.bucket // .settings.location // ""),
                ((.settings.base_path // "") | ltrimstr("/") | rtrimstr("/")) ] | join("|");
def is_ro: (((.settings.readonly // false) | tostring) == "true");
JQEOF

# ----------------------------------------------------------------------------
# HTTP
# ----------------------------------------------------------------------------
_curl_auth_cfg() {
  [[ -z $1 ]] && return 0
  local up="$1:$2"
  up=${up//\\/\\\\}
  up=${up//\"/\\\"}
  printf 'user = "%s"\n' "$up"
}

# es_request <source|dest> <METHOD> <path> [body] [max_time]
# Response body in $ES_RESP (file), HTTP status in $ES_CODE. Returns 0 on 2xx.
# Credentials are passed through a curl config file (they don't show up in "ps").
es_request() {
  local side=$1 method=$2 path=$3 body=${4-} max_time=${5:-$CURL_MAX_TIME}
  local url user pass ca insecure code rc
  case $side in
    source) url=$SOURCE_ES_URL; user=$SOURCE_ES_USER; pass=$SOURCE_ES_PASS; ca=$SOURCE_CA_CERT; insecure=$SOURCE_INSECURE_TLS ;;
    dest)   url=$DEST_ES_URL;   user=$DEST_ES_USER;   pass=$DEST_ES_PASS;   ca=$DEST_CA_CERT;   insecure=$DEST_INSECURE_TLS ;;
    *) die "es_request: invalid side '$side'" ;;
  esac
  local -a args=(-sS -g -X "$method" --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$max_time"
                 -H 'Content-Type: application/json' -o "$ES_RESP" -w '%{http_code}')
  [[ -n $ca ]] && args+=(--cacert "$ca")
  [[ $insecure == true ]] && args+=(-k)
  [[ -n $body ]] && args+=(--data-binary @-)
  : >"$ES_RESP"
  code=$(printf '%s' "$body" | curl "${args[@]}" -K <(_curl_auth_cfg "$user" "$pass") "${url%/}${path}" 2>"$TMP_DIR/curl.err")
  rc=$?
  ES_CODE=${code:-000}
  if (( rc != 0 )); then
    ES_CODE=000
    ES_CURL_ERR=$(head -c 500 "$TMP_DIR/curl.err")
    _log_file HTTP "$side $method $path -> curl rc=$rc $ES_CURL_ERR"
    return 1
  fi
  _log_file HTTP "$side $method $path -> $ES_CODE"
  [[ $ES_CODE == 2* ]]
}

es_error() {
  if [[ $ES_CODE == 000 ]]; then printf 'connection failure/timeout: %s' "${ES_CURL_ERR:-?}"; return; fi
  local r
  r=$(jq -r '(.error | if type == "object" then (.reason // .root_cause[0].reason // .type) else . end) // empty | tostring' "$ES_RESP" 2>/dev/null)
  [[ -z $r ]] && r=$(head -c 300 "$ES_RESP")
  printf 'HTTP %s: %s' "$ES_CODE" "$r"
}

# cluster_info <side>  ->  CI_NAME CI_UUID CI_VERSION
cluster_info() {
  es_request "$1" GET "/" || return 1
  IFS=$'\t' read -r CI_NAME CI_UUID CI_VERSION < <(jq -r '[.cluster_name, .cluster_uuid, .version.number] | @tsv' "$ES_RESP")
  [[ -n ${CI_UUID:-} ]]
}

ensure_cluster_names() {
  if [[ -z $SRC_NAME ]] && cluster_info source; then SRC_NAME=$CI_NAME; SRC_UUID=$CI_UUID; SRC_VERSION=$CI_VERSION; fi
  if [[ -z $DST_NAME ]] && cluster_info dest; then DST_NAME=$CI_NAME; DST_UUID=$CI_UUID; DST_VERSION=$CI_VERSION; fi
  if [[ -n $SRC_UUID && $SRC_UUID == "$DST_UUID" ]]; then
    die "SOURCE and DESTINATION point to the SAME cluster (cluster_uuid $SRC_UUID). Check SOURCE_ES_URL / DEST_ES_URL."
  fi
  return 0
}

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
check_deps() {
  (( BASH_VERSINFO[0] >= 4 )) || die "Requires bash 4 or newer."
  local d missing=()
  for d in curl jq awk date mktemp; do command -v "$d" >/dev/null 2>&1 || missing+=("$d"); done
  (( ${#missing[@]} == 0 )) || die "Missing dependencies: ${missing[*]} (e.g. apt-get install -y curl jq / yum install -y curl jq)"
}

load_config() {
  [[ -f $CONFIG_FILE ]] || die "Configuration file not found: $CONFIG_FILE (copy config.env.example to config.env)"
  local perms
  perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || true)
  if [[ -n $perms && ${perms: -1} != 0 ]]; then
    warn "$CONFIG_FILE may be readable by other users (mode $perms). Recommended: chmod 600 $CONFIG_FILE"
  fi
  # shellcheck source=/dev/null
  source "$CONFIG_FILE" || die "Error reading $CONFIG_FILE"

  : "${SOURCE_ES_URL:=}" "${SOURCE_ES_USER:=}" "${SOURCE_ES_PASS:=}" "${SOURCE_CA_CERT:=}" "${SOURCE_INSECURE_TLS:=false}"
  : "${DEST_ES_URL:=}" "${DEST_ES_USER:=}" "${DEST_ES_PASS:=}" "${DEST_CA_CERT:=}" "${DEST_INSECURE_TLS:=false}"
  : "${SOURCE_REPO:=}" "${DEST_RO_REPO_FOR_SOURCE:=}"
  : "${SNAPSHOT_NAME_PREFIX:=migration}" "${SNAPSHOT_INDICES:=*,-.*}" "${SNAPSHOT_LIST_LIMIT:=30}"
  : "${RESTORE_INDICES:=*,-.*}" "${RESTORE_IGNORE_INDEX_SETTINGS:=}"
  : "${ON_CONFLICT:=ask}" "${CHECK_DISK_BEFORE_RESTORE:=true}" "${DISK_WATERMARK_PERCENT:=85}"
  : "${EXPECTED_PRIMARY_SHARDS:=3}" "${EXPECTED_REPLICAS:=1}"
  : "${CURL_CONNECT_TIMEOUT:=10}" "${CURL_MAX_TIME:=120}" "${CURL_LONG_MAX_TIME:=600}"
  : "${LOG_DIR:=./logs}" "${STATE_DIR:=./state}"

  local v missing=()
  for v in SOURCE_ES_URL DEST_ES_URL SOURCE_REPO DEST_RO_REPO_FOR_SOURCE; do [[ -n ${!v} ]] || missing+=("$v"); done
  (( ${#missing[@]} == 0 )) || die "Required variables are empty in $CONFIG_FILE: ${missing[*]}"

  [[ ${SOURCE_ES_URL%/} != "${DEST_ES_URL%/}" ]] || die "SOURCE_ES_URL and DEST_ES_URL are the same."

  # index names can't contain spaces: strip spaces from patterns
  SNAPSHOT_INDICES=${SNAPSHOT_INDICES// /}
  RESTORE_INDICES=${RESTORE_INDICES// /}
  RESTORE_IGNORE_INDEX_SETTINGS=${RESTORE_IGNORE_INDEX_SETTINGS// /}
  SNAPSHOT_NAME_PREFIX=${SNAPSHOT_NAME_PREFIX,,}

  case $ON_CONFLICT in ask|abort|skip|delete) ;; *) die "Invalid ON_CONFLICT: '$ON_CONFLICT' (use ask|abort|skip|delete)" ;; esac
  for v in SOURCE_INSECURE_TLS DEST_INSECURE_TLS CHECK_DISK_BEFORE_RESTORE; do
    [[ ${!v} == true || ${!v} == false ]] || die "$v must be true or false (current: '${!v}')"
  done
  for v in SNAPSHOT_LIST_LIMIT DISK_WATERMARK_PERCENT EXPECTED_PRIMARY_SHARDS \
           EXPECTED_REPLICAS CURL_CONNECT_TIMEOUT CURL_MAX_TIME CURL_LONG_MAX_TIME; do
    [[ ${!v} =~ ^[0-9]+$ ]] || die "$v must be numeric (current: '${!v}')"
  done
  if [[ $RESTORE_IGNORE_INDEX_SETTINGS == *number_of_shards* || $RESTORE_IGNORE_INDEX_SETTINGS == *number_of_replicas* ]]; then
    die "RESTORE_IGNORE_INDEX_SETTINGS must not contain number_of_shards/number_of_replicas (the restore must keep the snapshot values)."
  fi
  [[ $SNAPSHOT_NAME_PREFIX =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "Invalid SNAPSHOT_NAME_PREFIX: '$SNAPSHOT_NAME_PREFIX'"

  [[ $LOG_DIR == /* ]] || LOG_DIR="$SCRIPT_DIR/${LOG_DIR#./}"
  [[ $STATE_DIR == /* ]] || STATE_DIR="$SCRIPT_DIR/${STATE_DIR#./}"
}

setup_runtime() {
  mkdir -p "$LOG_DIR" "$STATE_DIR" || die "Could not create $LOG_DIR / $STATE_DIR"
  LOG_FILE="$LOG_DIR/es-snapshot-restore-$(date '+%Y%m%d-%H%M%S').log"
  TMP_DIR=$(mktemp -d) || die "mktemp failed"
  trap 'rm -rf "$TMP_DIR"' EXIT
  ES_RESP="$TMP_DIR/resp.json"
  _log_file INFO "Start (v$SCRIPT_VERSION) config=$CONFIG_FILE source=$SOURCE_ES_URL destination=$DEST_ES_URL"
}

ask_passwords() {
  if [[ -n $SOURCE_ES_USER && -z $SOURCE_ES_PASS ]]; then
    read -r -s -p "Password for user '$SOURCE_ES_USER' on the SOURCE cluster ($SOURCE_ES_URL): " SOURCE_ES_PASS; echo
  fi
  if [[ -n $DEST_ES_USER && -z $DEST_ES_PASS ]]; then
    read -r -s -p "Password for user '$DEST_ES_USER' on the DESTINATION cluster ($DEST_ES_URL): " DEST_ES_PASS; echo
  fi
}

# ----------------------------------------------------------------------------
# Preflight checks
# ----------------------------------------------------------------------------
preflight() {
  local errors=0 h side
  PF_RO_REPO_MISSING=0; PF_SOURCE_REPO_RO=0
  title "Preflight checks"

  if cluster_info source; then
    SRC_NAME=$CI_NAME; SRC_UUID=$CI_UUID; SRC_VERSION=$CI_VERSION
    ok "SOURCE     : cluster '$SRC_NAME' version $SRC_VERSION ($SOURCE_ES_URL)"
  else
    err "SOURCE unreachable ($SOURCE_ES_URL): $(es_error)"; ((errors++))
  fi
  if cluster_info dest; then
    DST_NAME=$CI_NAME; DST_UUID=$CI_UUID; DST_VERSION=$CI_VERSION
    ok "DESTINATION: cluster '$DST_NAME' version $DST_VERSION ($DEST_ES_URL)"
  else
    err "DESTINATION unreachable ($DEST_ES_URL): $(es_error)"; ((errors++))
  fi
  (( errors == 0 )) || return "$errors"

  if [[ $SRC_UUID == "$DST_UUID" ]]; then
    err "SOURCE and DESTINATION are the SAME cluster (cluster_uuid $SRC_UUID)!"; return 1
  fi
  if (( $(ver_num "$DST_VERSION") < $(ver_num "$SRC_VERSION") )); then
    err "Destination version ($DST_VERSION) is lower than source ($SRC_VERSION): restore not supported."; ((errors++))
  elif [[ $DST_VERSION != "$SRC_VERSION" ]]; then
    warn "Different versions (source $SRC_VERSION, destination $DST_VERSION)."
  fi

  for side in source dest; do
    if es_request "$side" GET "/_cluster/health?filter_path=status,number_of_data_nodes,active_shards,unassigned_shards"; then
      h=$(jq -r '"status=\(.status) data_nodes=\(.number_of_data_nodes) active_shards=\(.active_shards) unassigned=\(.unassigned_shards)"' "$ES_RESP")
      if jq -e '.status == "red"' "$ES_RESP" >/dev/null; then warn "$(side_label $side) health: $h"; else ok "$(side_label $side) health: $h"; fi
    else
      warn "Could not read $(side_label $side) cluster health: $(es_error)"
    fi
  done

  # Source repository (on the source cluster)
  local src_loc="" ro_loc
  if es_request source GET "/_snapshot/$(urlenc "$SOURCE_REPO")"; then
    jq --arg r "$SOURCE_REPO" '.[$r]' "$ES_RESP" >"$TMP_DIR/src_repo.json"
    src_loc=$(jq -r "$JQ_LIB"$'\n''repo_loc' "$TMP_DIR/src_repo.json")
    ok "SOURCE repo '$SOURCE_REPO': $src_loc"
    if jq -e "$JQ_LIB"$'\n''is_ro' "$TMP_DIR/src_repo.json" >/dev/null; then
      PF_SOURCE_REPO_RO=1
      warn "Repo '$SOURCE_REPO' is readonly on the SOURCE: new snapshots can't be created (only existing ones can be used)."
    fi
  else
    err "Repo '$SOURCE_REPO' not found/unreachable on the SOURCE: $(es_error)"; ((errors++))
  fi

  # Read-only repository on the destination
  if es_request dest GET "/_snapshot"; then
    cp "$ES_RESP" "$TMP_DIR/dst_repos.json"
    if jq -e --arg r "$DEST_RO_REPO_FOR_SOURCE" 'has($r)' "$TMP_DIR/dst_repos.json" >/dev/null; then
      jq --arg r "$DEST_RO_REPO_FOR_SOURCE" '.[$r]' "$TMP_DIR/dst_repos.json" >"$TMP_DIR/ro_repo.json"
      ro_loc=$(jq -r "$JQ_LIB"$'\n''repo_loc' "$TMP_DIR/ro_repo.json")
      if jq -e "$JQ_LIB"$'\n''is_ro' "$TMP_DIR/ro_repo.json" >/dev/null; then
        ok "DESTINATION repo '$DEST_RO_REPO_FOR_SOURCE' is readonly: $ro_loc"
      else
        err "Repo '$DEST_RO_REPO_FOR_SOURCE' on the DESTINATION is NOT readonly! Two clusters writing to the same repository can corrupt it. Re-register it as read-only ('Register read-only repository' menu)."
        ((errors++))
      fi
      if [[ -n $src_loc && $ro_loc != "$src_loc" ]]; then
        err "Repo '$DEST_RO_REPO_FOR_SOURCE' (destination) points to '$ro_loc', which differs from the source repo '$src_loc'."; ((errors++))
      fi
      local mrb
      mrb=$(jq -r '.settings.max_restore_bytes_per_sec // "40mb (default)"' "$TMP_DIR/ro_repo.json")
      info "     max_restore_bytes_per_sec (per node) = $mrb"
      if es_request dest POST "/_snapshot/$(urlenc "$DEST_RO_REPO_FOR_SOURCE")/_verify"; then
        ok "Repo '$DEST_RO_REPO_FOR_SOURCE' verified on $(jq '.nodes | length' "$ES_RESP") DESTINATION node(s)"
      else
        err "Failed to verify repo '$DEST_RO_REPO_FOR_SOURCE' on the DESTINATION: $(es_error)"; ((errors++))
      fi
      local others
      others=$(jq -r --arg r "$DEST_RO_REPO_FOR_SOURCE" --arg loc "$ro_loc" "$JQ_LIB"$'\n''to_entries[] | select(.key != $r and (.value | repo_loc) == $loc and (.value | is_ro | not)) | .key' "$TMP_DIR/dst_repos.json")
      [[ -z $others ]] || warn "The DESTINATION has a WRITABLE repository pointing to the source container: $others (risk of repository corruption)."
    else
      PF_RO_REPO_MISSING=1
      err "Repo '$DEST_RO_REPO_FOR_SOURCE' does not exist on the DESTINATION. Use the 'Register read-only repository' option."; ((errors++))
    fi
  else
    err "Could not list DESTINATION repositories: $(es_error)"; ((errors++))
  fi

  if es_request dest GET "/_cluster/settings?flat_settings=true"; then
    local alloc
    alloc=$(jq -r '.transient["cluster.routing.allocation.enable"] // .persistent["cluster.routing.allocation.enable"] // "all"' "$ES_RESP")
    [[ $alloc == all ]] || warn "DESTINATION has cluster.routing.allocation.enable=$alloc: restored shards may not be allocated."
  fi

  if (( errors == 0 )); then ok "Preflight OK."; else err "$errors problem(s) found."; fi
  return "$errors"
}

# ----------------------------------------------------------------------------
# Read-only repository
# ----------------------------------------------------------------------------
# register_ro_repo <origin_side> <origin_repo> <target_side> <target_repo>
# Copies every setting of the original repository (type, container, base_path, client,
# compress, throttles...) and only forces readonly=true.
register_ro_repo() {
  local o_side=$1 o_repo=$2 t_side=$3 t_repo=$4
  local o_lbl t_lbl new_loc existing existing_loc others
  o_lbl=$(side_label "$o_side"); t_lbl=$(side_label "$t_side")

  es_request "$o_side" GET "/_snapshot/$(urlenc "$o_repo")" \
    || { err "Could not read repository '$o_repo' on the $o_lbl cluster: $(es_error)"; return 1; }
  jq --arg r "$o_repo" '.[$r]' "$ES_RESP" >"$TMP_DIR/orig_repo.json"
  jq '{type: .type, settings: ((.settings // {}) + {readonly: true})}' \
    "$TMP_DIR/orig_repo.json" >"$TMP_DIR/new_repo.json"
  new_loc=$(jq -r "$JQ_LIB"$'\n''repo_loc' "$TMP_DIR/new_repo.json")

  es_request "$t_side" GET "/_snapshot" || { err "Could not list $t_lbl repositories: $(es_error)"; return 1; }
  cp "$ES_RESP" "$TMP_DIR/t_repos.json"
  existing=$(jq -c --arg r "$t_repo" '.[$r] // empty' "$TMP_DIR/t_repos.json")
  if [[ -n $existing ]]; then
    existing_loc=$(jq -r "$JQ_LIB"$'\n''repo_loc' <<<"$existing")
    info "Repository '$t_repo' already exists on the $t_lbl: $existing"
    if [[ $existing_loc != "$new_loc" ]]; then
      err "It points to a different location ($existing_loc, expected $new_loc). Use another name."; return 1
    fi
    warn "It will be RE-REGISTERED (settings update). Don't do this while a restore from it is running."
  fi
  others=$(jq -r --arg r "$t_repo" --arg loc "$new_loc" "$JQ_LIB"$'\n''to_entries[] | select(.key != $r and (.value | repo_loc) == $loc and (.value | is_ro | not)) | .key' "$TMP_DIR/t_repos.json")
  [[ -z $others ]] || warn "The $t_lbl already has a WRITABLE repository at the same location: $others (risk of corruption)."

  info "Repository '$t_repo' to be registered on the $t_lbl cluster (data from '$o_repo' on the $o_lbl):"
  jq . "$TMP_DIR/new_repo.json"
  confirm_yes "Register '$t_repo' as READ-ONLY on the $t_lbl cluster?" || { info "Cancelled."; return 1; }
  es_request "$t_side" PUT "/_snapshot/$(urlenc "$t_repo")" "$(<"$TMP_DIR/new_repo.json")" \
    || { err "Registration failed: $(es_error)"; return 1; }
  ok "Repository '$t_repo' registered on the $t_lbl."
  if es_request "$t_side" POST "/_snapshot/$(urlenc "$t_repo")/_verify"; then
    ok "Verified on $(jq '.nodes | length' "$ES_RESP") node(s)."
  else
    warn "Verification failed: $(es_error) (check the azure client/keystore on every node)"
  fi
}

register_repo_menu() {
  local c
  title "Register read-only repository"
  echo "1) SOURCE repo ('$SOURCE_REPO') -> DESTINATION as '$DEST_RO_REPO_FOR_SOURCE' (read-only)  [required for the restore]"
  echo "0) Back"
  read -r -p "Option: " c || return 1
  case $c in
    1) register_ro_repo source "$SOURCE_REPO" dest "$DEST_RO_REPO_FOR_SOURCE" ;;
    *) return 0 ;;
  esac
}

# ----------------------------------------------------------------------------
# Snapshots
# ----------------------------------------------------------------------------
# Reads the snapshot through the DESTINATION read-only repo -> $TMP_DIR/snap.json
fetch_snapshot_info() {
  es_request dest GET "/_snapshot/$(urlenc "$DEST_RO_REPO_FOR_SOURCE")/$(urlenc "$1")" "" "$CURL_LONG_MAX_TIME" || return 1
  jq -e '.snapshots[0]' "$ES_RESP" >"$TMP_DIR/snap.json"
}

create_snapshot() {
  local health running name body
  title "Create a new snapshot on the SOURCE cluster (production)"
  ensure_cluster_names
  if (( PF_SOURCE_REPO_RO )); then err "Repo '$SOURCE_REPO' is readonly on the source."; return 1; fi

  es_request source GET "/_cluster/health?filter_path=status" || { err "Failed to read source health: $(es_error)"; return 1; }
  health=$(jq -r '.status' "$ES_RESP")
  info "Source health: $health"
  if [[ $health == red ]]; then
    warn "Source is RED: indices with an unavailable primary will make the snapshot fail (partial=false)."
    confirm_yes "Continue anyway?" || return 1
  fi

  # ES 6.x allows only ONE snapshot at a time per cluster (e.g. a curator job)
  es_request source GET "/_snapshot/_status?filter_path=snapshots.snapshot,snapshots.repository,snapshots.state" \
    || { err "Failed to check running snapshots: $(es_error)"; return 1; }
  running=$(jq -r '(.snapshots // [])[] | "  \(.repository)/\(.snapshot) (\(.state))"' "$ES_RESP")
  if [[ -n $running ]]; then
    err "A snapshot is already running on the source (ES 6.x allows only one at a time):"
    info "$running"
    info "Wait for it to finish (e.g. curator job) and try again."
    return 1
  fi

  name="${SNAPSHOT_NAME_PREFIX}-$(date '+%Y.%m.%d-%H%M%S')"
  info "Cluster              : $SRC_NAME ($SOURCE_ES_URL)"
  info "Repository           : $SOURCE_REPO"
  info "Snapshot             : $name"
  info "Indices              : $SNAPSHOT_INDICES"
  info "include_global_state : false (does not carry cluster templates/settings)"
  info "Note: the snapshot is incremental (only uploads segments new since the repo's last snapshot) and uses"
  info "      the max_snapshot_bytes_per_sec throttle already configured on the repo. No source setting is changed."
  info "      Make sure the prefix '$SNAPSHOT_NAME_PREFIX' is not deleted by curator's delete_snapshots."
  confirm_yes "Create snapshot '$name' on the PRODUCTION cluster '$SRC_NAME'?" || { info "Cancelled."; return 1; }

  body=$(jq -cn --arg i "$SNAPSHOT_INDICES" '{indices: $i, ignore_unavailable: true, include_global_state: false, partial: false}')
  es_request source PUT "/_snapshot/$(urlenc "$SOURCE_REPO")/$(urlenc "$name")?wait_for_completion=false" "$body" \
    || { err "Failed to start snapshot: $(es_error)"; return 1; }
  ok "Snapshot '$name' started."
  monitor_snapshot "$name" || return 1
  SELECTED_SNAPSHOT=$name
}

monitor_snapshot() {
  local name=$1 start=$SECONDS entry st sdone stotal sfailed i state
  info "Polling every ${POLL_INTERVAL}s (Ctrl+C stops only the monitoring; the snapshot keeps running on the cluster)."
  _INTERRUPTED=0
  trap '_INTERRUPTED=1' INT
  while (( ! _INTERRUPTED )); do
    # _snapshot/_status without repo/name = only running snapshots (from cluster state, lightweight)
    if es_request source GET "/_snapshot/_status?filter_path=snapshots.snapshot,snapshots.repository,snapshots.state,snapshots.shards_stats"; then
      entry=$(jq -r --arg n "$name" --arg r "$SOURCE_REPO" \
        '(.snapshots // [])[] | select(.snapshot == $n and .repository == $r) | "\(.state) \(.shards_stats.done) \(.shards_stats.total) \(.shards_stats.failed)"' "$ES_RESP")
      [[ -z $entry ]] && break
      read -r st sdone stotal sfailed <<<"$entry"
      printf '[%s] state=%s shards=%s/%s failed=%s elapsed=%s\n' "$(date '+%T')" "$st" "$sdone" "$stotal" "$sfailed" "$(fmt_duration $((SECONDS - start)))"
    else
      warn "Failed to check status: $(es_error)"
    fi
    sleep "$POLL_INTERVAL"
  done
  trap - INT
  if (( _INTERRUPTED )); then
    echo
    warn "Monitoring interrupted. Snapshot '$name' is still running on the source; pick it from the list later."
    return 1
  fi

  info "Snapshot finished on the source. Waiting for it to show up in the destination read-only repo..."
  for i in 1 2 3 4 5 6 7 8 9 10; do
    fetch_snapshot_info "$name" && break
    sleep 6
  done
  if [[ ! -s $TMP_DIR/snap.json ]] || [[ $(jq -r '.snapshot // empty' "$TMP_DIR/snap.json") != "$name" ]]; then
    err "Snapshot '$name' did not become visible on the DESTINATION via '$DEST_RO_REPO_FOR_SOURCE': $(es_error)"
    return 1
  fi
  state=$(jq -r '.state' "$TMP_DIR/snap.json")
  case $state in
    SUCCESS) ok "Snapshot '$name' completed with SUCCESS in $(fmt_duration $((SECONDS - start)))." ;;
    PARTIAL) err "Snapshot '$name' finished PARTIAL (failed indices: $(jq -r '[.failures[]?.index] | unique | join(", ")' "$TMP_DIR/snap.json")). Only SUCCESS snapshots can be restored."; return 1 ;;
    *) err "Snapshot '$name' finished with state $state. Only SUCCESS snapshots can be restored."; return 1 ;;
  esac
}

# Lists only SUCCESS snapshots, always through the read-only repo on the DESTINATION
# (no load on production). Fills SNAP_IDS and prints the table.
SNAP_IDS=()
list_snapshots() {
  local repo=$DEST_RO_REPO_FOR_SOURCE total hidden id ep dur nidx okc tot when i=0
  title "SUCCESS snapshots in repository '$repo' (queried on the DESTINATION cluster)"
  es_request dest GET "/_cat/snapshots/$(urlenc "$repo")?format=json&ignore_unavailable=true&h=id,status,start_epoch,duration,indices,successful_shards,total_shards" "" "$CURL_LONG_MAX_TIME" \
    || { err "Failed to list snapshots: $(es_error)"; return 1; }
  total=$(jq '[ .[] | select(.status == "SUCCESS") ] | length' "$ES_RESP")
  hidden=$(jq '[ .[] | select(.status != "SUCCESS") ] | length' "$ES_RESP")
  jq -r --argjson lim "$SNAPSHOT_LIST_LIMIT" \
    'map(select(.status == "SUCCESS")) | sort_by(.start_epoch | tonumber) | .[(if length > $lim then length - $lim else 0 end):][] | [.id, .start_epoch, .duration, .indices, .successful_shards, .total_shards] | map(tostring) | @tsv' \
    "$ES_RESP" >"$TMP_DIR/snaplist.tsv"
  SNAP_IDS=()
  printf '%s%4s  %-42s %-19s %9s %8s %15s%s\n' "$C_BLD" "#" "SNAPSHOT" "START" "DURATION" "INDICES" "SHARDS OK/TOT" "$C_RST"
  while IFS=$'\t' read -r id ep dur nidx okc tot; do
    i=$((i + 1)); SNAP_IDS+=("$id")
    when=$(date -d "@$ep" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ep")
    printf '%4s  %-42s %-19s %9s %8s %15s\n' "$i" "$id" "$when" "$dur" "$nidx" "$okc/$tot"
  done <"$TMP_DIR/snaplist.tsv"
  info "Showing $i of $total SUCCESS snapshot(s) (most recent last)."
  (( hidden > 0 )) && info "$hidden snapshot(s) not in SUCCESS state (PARTIAL/FAILED/...) are hidden."
  (( i > 0 ))
}

choose_existing_snapshot() {
  local choice sel st
  list_snapshots || { warn "No SUCCESS snapshots available."; return 1; }
  while true; do
    read -r -p "Snapshot number (or exact name; 'q' to go back): " choice || return 1
    [[ $choice == q || $choice == Q ]] && return 1
    [[ -z $choice ]] && continue
    if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SNAP_IDS[@]} )); then
      sel=${SNAP_IDS[choice - 1]}
    else
      sel=$choice
      if ! fetch_snapshot_info "$sel"; then err "Snapshot '$sel' not found in the destination repo '$DEST_RO_REPO_FOR_SOURCE'."; continue; fi
      st=$(jq -r '.state' "$TMP_DIR/snap.json")
      [[ $st == SUCCESS ]] || { err "Snapshot '$sel' is in state '$st'. Only SUCCESS snapshots can be used."; continue; }
    fi
    SELECTED_SNAPSHOT=$sel
    ok "Selected snapshot: $sel"
    return 0
  done
}

# ----------------------------------------------------------------------------
# Restore
# ----------------------------------------------------------------------------
# Estimates disk/shards. Uses $TMP_DIR/to_restore.json. Returns 1 if the user gives up.
estimate_resources() {
  local snap=$1 size=0 primaries=0 per_index=0 diff_pri="" used total cap needed active dnodes n new_shards per_node
  [[ $CHECK_DISK_BEFORE_RESTORE == true ]] || return 0
  n=$(jq 'length' "$TMP_DIR/to_restore.json")
  info "Computing snapshot size (queried on the DESTINATION by reading the repository; may take a few minutes)..."
  if es_request dest GET "/_snapshot/$(urlenc "$DEST_RO_REPO_FOR_SOURCE")/$(urlenc "$snap")/_status?filter_path=snapshots.stats,snapshots.indices.*.stats,snapshots.indices.*.shards_stats" "" "$CURL_LONG_MAX_TIME"; then
    read -r size primaries per_index diff_pri < <(jq -r --slurpfile r "$TMP_DIR/to_restore.json" --argjson ep "$EXPECTED_PRIMARY_SHARDS" '
      def sz: (.stats.total.size_in_bytes // .stats.total_size_in_bytes // 0);
      .snapshots[0] as $s | ($s.indices // {}) as $I
      | if ($I | length) > 0 then
          [ $r[0][] | ($I[.] // {}) ] as $sel
          | [ ($sel | map(sz) | add // 0), ($sel | map(.shards_stats.total // 0) | add // 0), 1,
              ($sel | map(select((.shards_stats.total // $ep) != $ep)) | length) ]
        else [ ($s | sz), 0, 0, 0 ] end | map(tostring) | join(" ")' "$ES_RESP")
    info "Size of the selected indices (primaries, without replicas): $(human_bytes "$size")"
    if [[ $per_index == 1 && ${diff_pri:-0} != 0 ]]; then
      warn "$diff_pri index(es) in the snapshot have a primary count other than $EXPECTED_PRIMARY_SHARDS (they will be restored as they are in the snapshot)."
    fi
  else
    warn "Could not compute size: $(es_error). If it's an ingress 504/timeout, raise proxy-read-timeout or disable CHECK_DISK_BEFORE_RESTORE."
    confirm_yes "Continue without the disk estimate?" || return 1
    return 0
  fi

  if es_request dest GET "/_cat/allocation?format=json&bytes=b&h=node,disk.used,disk.total"; then
    read -r used total < <(jq -r '[ .[] | select(.node != "UNASSIGNED" and .["disk.total"] != null and .["disk.used"] != null) ]
        | [ (map(.["disk.used"] | tonumber) | add // 0), (map(.["disk.total"] | tonumber) | add // 0) ] | map(tostring) | join(" ")' "$ES_RESP")
    needed=$(( size * (1 + EXPECTED_REPLICAS) ))
    cap=$(( total * DISK_WATERMARK_PERCENT / 100 - used ))
    info "DESTINATION disk: used $(human_bytes "$used") of $(human_bytes "$total") | free up to ${DISK_WATERMARK_PERCENT}%: $(human_bytes "$cap")"
    info "Estimated need (primaries + $EXPECTED_REPLICAS replica): $(human_bytes "$needed")"
    if (( needed > cap )); then
      warn "Estimated space is GREATER than what's available up to ${DISK_WATERMARK_PERCENT}% usage. The restore may stall on the disk watermark."
      confirm_yes "Continue anyway?" || return 1
    fi
  fi

  if es_request dest GET "/_cluster/health?filter_path=active_shards,number_of_data_nodes"; then
    read -r active dnodes < <(jq -r '"\(.active_shards) \(.number_of_data_nodes)"' "$ES_RESP")
    (( primaries > 0 )) || primaries=$(( n * EXPECTED_PRIMARY_SHARDS ))
    new_shards=$(( primaries * (1 + EXPECTED_REPLICAS) ))
    (( dnodes > 0 )) || dnodes=1
    per_node=$(( (active + new_shards) / dnodes ))
    info "Shards: current=$active + new~$new_shards => ~$per_node per data node ($dnodes data nodes)"
    (( per_node <= 1000 )) || warn "More than 1000 shards per node: the cluster works, but gets heavier (heap/cluster state)."
  fi
  return 0
}

restore_snapshot() {
  local snap=$1 ro_enc snap_enc st sver sstart n_snap n_match n_open n_closed n_alias n_conf
  local action use_list n_restore n_delete body body_size ts state_file c
  [[ -n $snap ]] || { err "No snapshot given."; return 1; }
  ro_enc=$(urlenc "$DEST_RO_REPO_FOR_SOURCE"); snap_enc=$(urlenc "$snap")
  ensure_cluster_names

  title "Restore planning"
  fetch_snapshot_info "$snap" || { err "Snapshot '$snap' not found in repo '$DEST_RO_REPO_FOR_SOURCE' on the DESTINATION: $(es_error)"; return 1; }
  IFS=$'\t' read -r st sver sstart < <(jq -r '[.state, (.version // "?"), (.start_time // "?")] | @tsv' "$TMP_DIR/snap.json")
  [[ $st == SUCCESS ]] || { err "Snapshot is in state '$st'. Only SUCCESS snapshots can be restored."; return 1; }
  if [[ $sver != "?" && -n $DST_VERSION ]] && (( $(ver_num "$sver") > $(ver_num "$DST_VERSION") )); then
    err "Snapshot was created on version $sver, newer than the destination ($DST_VERSION)."; return 1
  fi

  es_request dest GET "/_cat/indices?format=json&h=index,status" "" "$CURL_LONG_MAX_TIME" || { err "Failed to list destination indices: $(es_error)"; return 1; }
  cp "$ES_RESP" "$TMP_DIR/dst_indices.json"
  es_request dest GET "/_cat/aliases?format=json&h=alias,index" "" "$CURL_LONG_MAX_TIME" || { err "Failed to list destination aliases: $(es_error)"; return 1; }
  cp "$ES_RESP" "$TMP_DIR/dst_aliases.json"

  jq -n --slurpfile s "$TMP_DIR/snap.json" --slurpfile d "$TMP_DIR/dst_indices.json" --slurpfile a "$TMP_DIR/dst_aliases.json" \
        --arg pat "$RESTORE_INDICES" "$JQ_LIB"$'\n''
    $s[0] as $snap
    | es_patterns($pat) as $P
    | ($d[0] | reduce .[] as $x ({}; .[$x.index] = $x.status)) as $D
    | ([ $a[0][] | .alias ] | to_set) as $A
    | [ ($snap.indices // [])[] | select(es_match($P)) ] as $cand
    | { snapshot_indices: ($snap.indices // [] | length),
        matched: ($cand | length),
        candidates: $cand,
        conflicts_open:   [ $cand[] | select($D[.] == "open") ],
        conflicts_closed: [ $cand[] | select($D[.] != null and $D[.] != "open") ],
        conflicts_alias:  [ $cand[] | select($A[.]) ] }' >"$TMP_DIR/plan.json" \
    || { err "Failed to build the restore plan."; return 1; }

  read -r n_snap n_match n_open n_closed n_alias < <(jq -r \
    '[.snapshot_indices, .matched, (.conflicts_open | length), (.conflicts_closed | length), (.conflicts_alias | length)] | map(tostring) | join(" ")' \
    "$TMP_DIR/plan.json")
  info "Snapshot '$snap' ($st, version $sver, started $sstart): $n_snap index(es); $n_match match '$RESTORE_INDICES'."
  (( n_match > 0 )) || { err "No indices to restore."; return 1; }

  action="none"
  n_conf=$(( n_open + n_closed + n_alias ))
  if (( n_conf > 0 )); then
    warn "$n_conf snapshot index(es) already exist on the DESTINATION (open: $n_open, closed: $n_closed, name used by an alias: $n_alias)."
    info "Examples:"
    jq -r '(.conflicts_open + .conflicts_closed + .conflicts_alias) | unique | .[:20][] | "  - " + .' "$TMP_DIR/plan.json"
    (( n_conf > 20 )) && info "  ... (full list in the log)"
    jq -r '(.conflicts_open + .conflicts_closed + .conflicts_alias) | unique | .[]' "$TMP_DIR/plan.json" | sed 's/^/CONFLICT /' >>"$LOG_FILE"
    action=$ON_CONFLICT
    if [[ $action == ask ]]; then
      echo "1) Skip the conflicting ones (restore only indices that don't exist on the destination)"
      echo "2) DELETE the conflicting ones on the destination and restore them from the snapshot"
      echo "3) Cancel"
      read -r -p "Option: " c || c=3
      case $c in 1) action=skip ;; 2) action=delete ;; *) action=abort ;; esac
    fi
    [[ $action == abort ]] && { info "Restore cancelled."; return 1; }
    if [[ $action == delete && $n_alias -gt 0 ]]; then
      warn "$n_alias index(es) conflict with ALIAS names on the destination; they will be skipped (the script does not remove aliases)."
    fi
  fi

  jq --arg act "$action" '
      (if $act == "skip" then (.conflicts_open + .conflicts_closed + .conflicts_alias)
       elif $act == "delete" then .conflicts_alias else [] end) as $excl
      | (reduce $excl[] as $x ({}; .[$x] = true)) as $E
      | [ .candidates[] | select($E[.] | not) ]' "$TMP_DIR/plan.json" >"$TMP_DIR/to_restore.json"
  if [[ $action == delete ]]; then
    jq '(.conflicts_open + .conflicts_closed) | unique' "$TMP_DIR/plan.json" >"$TMP_DIR/to_delete.json"
  else
    echo '[]' >"$TMP_DIR/to_delete.json"
  fi
  n_restore=$(jq 'length' "$TMP_DIR/to_restore.json")
  n_delete=$(jq 'length' "$TMP_DIR/to_delete.json")
  (( n_restore > 0 )) || { warn "After handling conflicts there are no indices left to restore."; return 1; }
  # If any index matching the pattern was left out, send the explicit list; otherwise send the pattern.
  if (( n_restore == n_match )); then use_list=false; else use_list=true; fi

  estimate_resources "$snap" || { info "Restore cancelled."; return 1; }

  jq -cn --slurpfile r "$TMP_DIR/to_restore.json" --arg pat "$RESTORE_INDICES" --argjson uselist "$use_list" \
         --arg ign "$RESTORE_IGNORE_INDEX_SETTINGS" '
    { indices: (if $uselist then $r[0] else $pat end),
      ignore_unavailable: true,
      include_global_state: false,
      include_aliases: true,
      partial: false }
    + (if $ign != "" then {ignore_index_settings: $ign} else {} end)' >"$TMP_DIR/restore_body.json"
  body=$(<"$TMP_DIR/restore_body.json")
  body_size=${#body}

  title "RESTORE SUMMARY"
  info "DESTINATION cluster    : $DST_NAME ($DEST_ES_URL)"
  info "Repository (readonly)  : $DEST_RO_REPO_FOR_SOURCE"
  info "Snapshot               : $snap ($st, started $sstart)"
  info "Index pattern          : $RESTORE_INDICES"
  if [[ $use_list == true ]]; then
    info "Indices to restore     : $n_restore (explicit list; $(( n_match - n_restore )) matching the pattern were left out)"
  else
    info "Indices to restore     : $n_restore"
  fi
  (( n_delete > 0 )) && info "${C_RED}Indices to DELETE on the destination before the restore: $n_delete${C_RST}"
  info "Primaries / replicas   : kept as in the snapshot (no index_settings are sent)"
  info "include_global_state   : false | include_aliases: true"
  [[ -n $RESTORE_IGNORE_INDEX_SETTINGS ]] && info "ignore_index_settings  : $RESTORE_IGNORE_INDEX_SETTINGS"
  info "The SOURCE (production) cluster is not accessed by the restore: data is read directly from the Storage Account."
  if (( body_size > 900000 )); then
    warn "The restore request body is $(human_bytes "$body_size"); the nginx ingress (proxy-body-size, default 1m) may reject it."
  fi
  echo
  confirm_yes "Confirm the RESTORE of indices '$RESTORE_INDICES' ($n_restore indices) from snapshot '$snap' on the DESTINATION cluster '$DST_NAME'?" \
    || { info "Restore cancelled by the user."; return 1; }

  if (( n_delete > 0 )); then
    confirm_yes "WARNING: $n_delete index(es) will be DELETED on the DESTINATION cluster '$DST_NAME' (their current data will be lost). Confirm?" \
      || { info "Restore cancelled."; return 1; }
    delete_dest_indices "$TMP_DIR/to_delete.json" || { err "Failed to delete indices; restore not started."; return 1; }
  fi

  info "Sending restore request..."
  if ! es_request dest POST "/_snapshot/${ro_enc}/${snap_enc}/_restore?wait_for_completion=false" "$body"; then
    err "Restore rejected: $(es_error)"
    return 1
  fi
  ok "Restore accepted by the destination cluster."

  ts=$(date '+%Y%m%d-%H%M%S')
  state_file="$STATE_DIR/restore-$ts.json"
  jq -n --arg snap "$snap" --arg repo "$DEST_RO_REPO_FOR_SOURCE" --arg url "$DEST_ES_URL" --arg at "$(date '+%F %T')" \
        --slurpfile r "$TMP_DIR/to_restore.json" \
        '{snapshot: $snap, repository: $repo, dest_url: $url, started_at: $at, indices: $r[0]}' >"$state_file"
  cp "$state_file" "$STATE_DIR/last_restore.json"
  info "State saved to $state_file"

  monitor_restore
}

delete_dest_indices() {
  local file=$1 batch fails=0
  while IFS= read -r batch; do
    if es_request dest DELETE "/${batch}?ignore_unavailable=true"; then
      info "Deleted: $(tr ',' '\n' <<<"$batch" | wc -l | tr -d ' ') index(es)"
      _log_file DELETE "$batch"
    else
      err "Failed to delete batch: $(es_error)"; ((fails++))
    fi
  done < <(jq -r '.[]' "$file" | make_batches 3000)
  (( fails == 0 ))
}

monitor_restore() {
  local sf="$STATE_DIR/last_restore.json" snap n start line pt ps rt rs ip ir un fl ni empty_polls=0 result=""
  [[ -f $sf ]] || { err "No restore recorded in $STATE_DIR."; return 1; }
  jq '.indices' "$sf" >"$TMP_DIR/mon_idx.json"
  snap=$(jq -r '.snapshot' "$sf"); n=$(jq 'length' "$TMP_DIR/mon_idx.json")
  title "Monitoring restore of snapshot '$snap' ($n indices) on the DESTINATION"
  info "Polling every ${POLL_INTERVAL}s. Ctrl+C stops only the monitoring (the restore keeps running on the cluster)."
  start=$SECONDS
  _INTERRUPTED=0
  trap '_INTERRUPTED=1' INT
  while (( ! _INTERRUPTED )); do
    if es_request dest GET "/_cat/shards?format=json&h=index,prirep,state,unassigned.reason" "" "$CURL_LONG_MAX_TIME"; then
      line=$(jq -r --slurpfile n "$TMP_DIR/mon_idx.json" '
        ($n[0] | reduce .[] as $x ({}; .[$x] = true)) as $N
        | map(select($N[.index])) as $s
        | [ ($s | map(select(.prirep == "p")) | length),
            ($s | map(select(.prirep == "p" and .state == "STARTED")) | length),
            ($s | map(select(.prirep == "r")) | length),
            ($s | map(select(.prirep == "r" and .state == "STARTED")) | length),
            ($s | map(select(.prirep == "p" and .state == "INITIALIZING")) | length),
            ($s | map(select(.prirep == "r" and .state == "INITIALIZING")) | length),
            ($s | map(select(.state == "UNASSIGNED")) | length),
            ($s | map(select(.["unassigned.reason"] == "ALLOCATION_FAILED")) | length),
            ($s | map(.index) | unique | length) ] | map(tostring) | join(" ")' "$ES_RESP")
      read -r pt ps rt rs ip ir un fl ni <<<"$line"
      if (( pt == 0 )); then
        empty_polls=$((empty_polls + 1))
        info "[$(date '+%T')] waiting for the indices to appear on the destination..."
        if (( empty_polls >= 10 )); then result=notfound; break; fi
      else
        printf '[%s] indices %s/%s | primaries %s/%s (%s%%) | replicas %s/%s (%s%%) | recovering p=%s r=%s | unassigned %s | failed %s | %s\n' \
          "$(date '+%T')" "$ni" "$n" "$ps" "$pt" $(( ps * 100 / pt )) "$rs" "$rt" $(( rt > 0 ? rs * 100 / rt : 100 )) \
          "$ip" "$ir" "$un" "$fl" "$(fmt_duration $((SECONDS - start)))"
        _log_file PROGRESS "$line"
        if (( ps == pt && rs == rt )); then result=done; break; fi
        if (( fl > 0 && ip == 0 && ir == 0 && un == fl )); then result=failed; break; fi
      fi
    else
      warn "Failed to query shards: $(es_error)"
    fi
    sleep "$POLL_INTERVAL"
  done
  trap - INT

  if (( _INTERRUPTED )); then
    echo
    warn "Monitoring interrupted. The restore keeps running on the destination; use the 'monitor' command to resume."
    return 1
  fi
  case $result in
    done)
      ok "Restore complete: all shards (primaries and replicas) are STARTED. Monitored time: $(fmt_duration $((SECONDS - start)))"
      jq --arg at "$(date '+%F %T')" '.completed_at = $at' "$sf" >"$TMP_DIR/sf.json" && cp "$TMP_DIR/sf.json" "$sf"
      verify_restore
      ;;
    failed)
      err "$fl shard(s) in ALLOCATION_FAILED and nothing else in progress. Elasticsearch explanation:"
      if es_request dest GET "/_cluster/allocation/explain"; then
        jq -r '"  index=\(.index) shard=\(.shard) primary=\(.primary)\n  reason: \(.unassigned_info.details // .unassigned_info.reason // "-")\n  \(.allocate_explanation // "")"' "$ES_RESP"
      fi
      info "After fixing the cause: POST _cluster/reroute?retry_failed=true (on the destination) and run 'monitor' again."
      return 1
      ;;
    notfound)
      err "No shard of the restored indices showed up on the destination. Check the destination Elasticsearch logs."
      return 1
      ;;
  esac
}

# ----------------------------------------------------------------------------
# Verification
# ----------------------------------------------------------------------------
verify_restore() {
  local sf="$STATE_DIR/last_restore.json" ts csv n_fix target batch
  [[ -f $sf ]] || { err "No restore recorded in $STATE_DIR."; return 1; }
  jq '.indices' "$sf" >"$TMP_DIR/ver_idx.json"
  title "Verification of restored indices ($(jq 'length' "$TMP_DIR/ver_idx.json") indices)"

  es_request dest GET "/_cat/indices?format=json&h=index,health,status,pri,rep,docs.count" "" "$CURL_LONG_MAX_TIME" \
    || { err "Failed to read destination indices: $(es_error)"; return 1; }
  cp "$ES_RESP" "$TMP_DIR/ver_dst.json"
  # Always compares with the source (a single light _cat/indices read)
  if es_request source GET "/_cat/indices?format=json&h=index,pri,rep,docs.count" "" "$CURL_LONG_MAX_TIME"; then
    cp "$ES_RESP" "$TMP_DIR/ver_src.json"
  else
    warn "Failed to read source indices ($(es_error)); comparing only against the expected standard."
    echo '[]' >"$TMP_DIR/ver_src.json"
  fi

  jq -n --slurpfile n "$TMP_DIR/ver_idx.json" --slurpfile d "$TMP_DIR/ver_dst.json" --slurpfile s "$TMP_DIR/ver_src.json" \
        --arg ep "$EXPECTED_PRIMARY_SHARDS" --arg er "$EXPECTED_REPLICAS" '
    ($d[0] | reduce .[] as $x ({}; .[$x.index] = $x)) as $D
    | ($s[0] | reduce .[] as $x ({}; .[$x.index] = $x)) as $S
    | [ $n[0][] as $i | $D[$i] as $x | $S[$i] as $y
        | { index: $i, health: ($x.health // "-"), pri: ($x.pri // "-"), rep: ($x.rep // "-"), docs: ($x["docs.count"] // "-"),
            spri: ($y.pri // "-"), srep: ($y.rep // "-"), sdocs: ($y["docs.count"] // "-"), insrc: ($y != null) }
        | .result = (if $x == null then "ERROR_MISSING"
                     elif .health != "green" then "WARN_HEALTH_\(.health | ascii_upcase)"
                     elif .insrc and (.pri != .spri or .rep != .srep) then "ERROR_SHARDS_DIFFER_FROM_SOURCE"
                     elif (.insrc | not) and (.pri != $ep or .rep != $er) then "WARN_SHARDS_DIFFER_FROM_EXPECTED"
                     elif .insrc and .docs != .sdocs then "WARN_DOCS_DIFFER"
                     else "OK" end)
        | .fix_rep = (if $x == null or .pri == "-" then null
                      elif .insrc then (if .pri == .spri and .rep != .srep then .srep else null end)
                      elif .rep != $er then $er else null end) ]' >"$TMP_DIR/verify.json"

  ts=$(date '+%Y%m%d-%H%M%S')
  csv="$LOG_DIR/verify-$ts.csv"
  jq -r '(["index","result","health","pri_dest","rep_dest","docs_dest","pri_source","rep_source","docs_source"] | @csv),
         (.[] | [.index, .result, .health, .pri, .rep, .docs, .spri, .srep, .sdocs] | map(tostring) | @csv)' \
    "$TMP_DIR/verify.json" >"$csv"

  info "Summary:"
  jq -r 'group_by(.result) | .[] | "  \(.[0].result): \(length)"' "$TMP_DIR/verify.json"
  if jq -e 'any(.[]; .result != "OK" and .result != "WARN_DOCS_DIFFER")' "$TMP_DIR/verify.json" >/dev/null; then
    info "Problems (up to 50):"
    jq -r '[ .[] | select(.result != "OK" and .result != "WARN_DOCS_DIFFER") ][:50][]
           | "  \(.index)  \(.result)  health=\(.health) pri=\(.pri)/\(.spri) rep=\(.rep)/\(.srep)"' "$TMP_DIR/verify.json"
  fi
  if jq -e 'any(.[]; .result == "WARN_DOCS_DIFFER")' "$TMP_DIR/verify.json" >/dev/null; then
    info "Note: doc count differences are expected for indices that kept receiving data on the source after the snapshot."
  fi
  info "Full report: $csv"

  n_fix=$(jq '[ .[] | select(.fix_rep != null) ] | length' "$TMP_DIR/verify.json")
  if (( n_fix > 0 )); then
    warn "$n_fix index(es) with a replica count different from the source/expected value."
    if confirm_yes "Set number_of_replicas of these indices on the DESTINATION to the source value (or $EXPECTED_REPLICAS if they no longer exist on the source)?"; then
      while IFS= read -r target; do
        while IFS= read -r batch; do
          es_request dest PUT "/${batch}/_settings" "{\"index\":{\"number_of_replicas\":$target}}" \
            && ok "number_of_replicas=$target applied to $(tr ',' '\n' <<<"$batch" | wc -l | tr -d ' ') index(es)" \
            || err "Failed to set replicas: $(es_error)"
        done < <(jq -r --arg t "$target" '.[] | select(.fix_rep == $t) | .index' "$TMP_DIR/verify.json" | make_batches 3000)
      done < <(jq -r '[ .[] | .fix_rep | select(. != null) ] | unique | .[]' "$TMP_DIR/verify.json")
    fi
  fi
  if jq -e 'any(.[]; .result == "ERROR_SHARDS_DIFFER_FROM_SOURCE" and .pri != .spri)' "$TMP_DIR/verify.json" >/dev/null; then
    err "Some indices have a PRIMARY count different from the source (can't be fixed via settings; see the CSV)."
  fi
}

# ----------------------------------------------------------------------------
# Flows
# ----------------------------------------------------------------------------
run_preflight_or_fix() {
  if preflight; then return 0; fi
  if (( PF_RO_REPO_MISSING )); then
    if confirm_yes "Read-only repository '$DEST_RO_REPO_FOR_SOURCE' does not exist on the destination. Register it now?"; then
      register_ro_repo source "$SOURCE_REPO" dest "$DEST_RO_REPO_FOR_SOURCE" \
        && preflight && return 0
    fi
  fi
  err "Fix the problems above before continuing."
  return 1
}

full_flow() {
  local c
  run_preflight_or_fix || return 1
  SELECTED_SNAPSHOT=""
  title "Snapshot selection"
  echo "1) Create a NEW snapshot now on the source cluster"
  echo "2) List existing snapshots and pick one"
  echo "0) Back"
  read -r -p "Option: " c || return 1
  case $c in
    1) create_snapshot || return 1 ;;
    2) choose_existing_snapshot || return 1 ;;
    *) return 0 ;;
  esac
  restore_snapshot "$SELECTED_SNAPSHOT"
}

main_menu() {
  local c
  while true; do
    printf '\n%s===== es-snapshot-restore v%s =====%s\n' "$C_BLD" "$SCRIPT_VERSION" "$C_RST"
    echo "SOURCE     : $SOURCE_ES_URL  (repo: $SOURCE_REPO)"
    echo "DESTINATION: $DEST_ES_URL  (read-only repo: $DEST_RO_REPO_FOR_SOURCE)"
    echo
    echo "1) Check connectivity and prerequisites"
    echo "2) Snapshot + Restore (create or pick a snapshot and restore it)"
    echo "3) List snapshots"
    echo "4) Monitor the last restore"
    echo "5) Verify indices from the last restore"
    echo "6) Register read-only repository"
    echo "0) Exit"
    read -r -p "Option: " c || { echo; return 0; }
    case $c in
      1) preflight ;;
      2) full_flow ;;
      3) list_snapshots ;;
      4) monitor_restore ;;
      5) verify_restore ;;
      6) register_repo_menu ;;
      0|q|Q) return 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

usage() {
  cat <<EOF
es-snapshot-restore v$SCRIPT_VERSION - Elasticsearch 6.8 migration via snapshot/restore

Usage: $(basename "$0") [-c config_file] [command] [argument]

Without a command, opens the interactive menu. Commands:
  check               check connectivity, versions and repositories
  run                 full flow: create/pick a snapshot and restore it
  list                list available snapshots
  snapshot            create a new snapshot on the source (and offer the restore)
  restore <snapshot>  restore the given snapshot on the destination
  monitor             monitor the last restore
  verify              verify the indices of the last restore
  register-repo       register the source repository as read-only on the destination

Options:
  -c, --config FILE   configuration file (default: $SCRIPT_DIR/config.env)
  -h, --help          this help
EOF
}

main() {
  local cmd="" arg=""
  while (( $# )); do
    case $1 in
      -c|--config) [[ $# -ge 2 ]] || die "-c requires a file"; CONFIG_FILE=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; die "Unknown option: $1" ;;
      *) if [[ -z $cmd ]]; then cmd=$1; else arg=$1; fi; shift ;;
    esac
  done

  check_deps
  load_config
  setup_runtime
  ask_passwords
  info "Log: $LOG_FILE"

  case $cmd in
    "") main_menu ;;
    check) preflight ;;
    run) full_flow ;;
    list) list_snapshots ;;
    snapshot)
      run_preflight_or_fix || exit 1
      create_snapshot || exit 1
      if confirm_yes "Proceed to restore snapshot '$SELECTED_SNAPSHOT'?"; then restore_snapshot "$SELECTED_SNAPSHOT"; fi ;;
    restore)
      [[ -n $arg ]] || die "Usage: $(basename "$0") restore <snapshot_name>"
      run_preflight_or_fix || exit 1
      restore_snapshot "$arg" ;;
    monitor) monitor_restore ;;
    verify) verify_restore ;;
    register-repo) register_repo_menu ;;
    *) usage; die "Unknown command: $cmd" ;;
  esac
}

main "$@"
