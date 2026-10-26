# shellcheck shell=bash
# lib/target.sh — Where the server is: this host or an ssh host (SSH_HOST),
# and how its world server runs: a podman container, or a Kubernetes
# Deployment (SERVER_KIND=kube). Everything that touches a container, kubectl
# or the bot config goes through here, so the commands above it do not care.
#
# Part of teldrassil.sh, which sources it; not meant to run on its own.

# -----------------------------------------------------------------------------
# The host
# -----------------------------------------------------------------------------

# ssh does not take an argv: it joins its arguments with spaces and the remote
# shell parses them again. So each one is single-quoted for that second parse.
_shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
_shq_argv() { local a q=""; for a in "$@"; do q+="$(_shq "$a") "; done; printf '%s' "$q"; }

# _on_host <command...> — run it here, or on SSH_HOST. stdin and stdout pass
# through, so SQL and passwords travel on stdin as they do locally.
_on_host() {
    if [[ -z "$SSH_HOST" ]]; then "$@"; return; fi
    ssh -o BatchMode=yes -- "$SSH_HOST" "$(_shq_argv "$@")"
}

_kube() { _on_host kubectl --namespace "$KUBE_NAMESPACE" "$@"; }
_is_kube() { [[ "$SERVER_KIND" == kube ]]; }

# _check_target <command> — settings that cannot work together, and the
# provisioning commands, which build and run a server HERE.
_check_target() {
    case "$1" in
        install|source|build-image|build|extract|db-init|configure|create|remove)
            [[ -z "$SSH_HOST" ]] && ! _is_kube \
                || error_exit "'$1' provisions a server on this host, in podman; this profile points elsewhere (SSH_HOST='${SSH_HOST}', SERVER_KIND=${SERVER_KIND})." ;;
    esac
    if _is_kube; then
        [[ -n "$KUBE_NAMESPACE" ]] || error_exit "SERVER_KIND=kube needs KUBE_NAMESPACE."
    fi
    return 0
}

# Where status and errors say the server is.
_where() {
    local w="this host"; [[ -n "$SSH_HOST" ]] && w="${SSH_HOST} (ssh)"
    if _is_kube; then printf 'deployment %s in %s, on %s' "$SERVER_CONTAINER" "$KUBE_NAMESPACE" "$w"
    else printf '%s' "$w"; fi
}

# -----------------------------------------------------------------------------
# Containers (the database always; the servers with SERVER_KIND=podman)
# -----------------------------------------------------------------------------

_container_exists()  { _on_host "$PODMAN" container inspect "$1" >/dev/null 2>&1; }
_container_running() { [[ "$(_on_host "$PODMAN" container inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }
_container_state() {
    _container_exists "$1" || { printf 'missing'; return; }
    _on_host "$PODMAN" container inspect -f '{{.State.Status}}' "$1" 2>/dev/null
}

# -----------------------------------------------------------------------------
# The world server, either kind
# -----------------------------------------------------------------------------

# _kube_selector — the Deployment's pod selector, as a -l argument.
_kube_selector() {
    local sel
    # shellcheck disable=SC2016  # a Go template, not a shell expansion
    sel="$(_kube get deployment "$SERVER_CONTAINER" -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null)" \
        || error_exit "No deployment '${SERVER_CONTAINER}' in namespace ${KUBE_NAMESPACE} (set SERVER_CONTAINER, KUBE_NAMESPACE)."
    [[ -n "$sel" ]] || error_exit "Deployment ${SERVER_CONTAINER} has no matchLabels selector."
    printf '%s' "${sel%,}"
}

# _kube_pods — the world server's pods that exist, terminating ones included:
# a pod that is shutting down still has a server writing its last save.
_kube_pods() { _kube get pods -l "$(_kube_selector)" -o name 2>/dev/null; }

_server_running() {
    if _is_kube; then [[ -n "$(_kube_pods)" ]]; else _container_running "$SERVER_CONTAINER"; fi
}

_server_state() {
    if ! _is_kube; then _container_state "$SERVER_CONTAINER"; return; fi
    local want ready
    want="$(_kube get deployment "$SERVER_CONTAINER" -o jsonpath='{.spec.replicas}' 2>/dev/null)" || { printf 'missing'; return; }
    ready="$(_kube get deployment "$SERVER_CONTAINER" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    if [[ "$want" == 0 ]]; then
        if [[ -n "$(_kube_pods)" ]]; then printf 'stopping'; else printf 'stopped (0 replicas)'; fi
    else
        printf '%s of %s ready' "${ready:-0}" "$want"
    fi
}

# _server_log — the world server's log since it (re)started: for a container
# since a moment, for a Deployment its current pod's whole log, which begins
# when that pod's server did.
_server_log() {
    if _is_kube; then _kube logs "deployment/${SERVER_CONTAINER}" 2>&1 || true
    else _on_host "$PODMAN" logs --since "$1" "$SERVER_CONTAINER" 2>&1 || true; fi
}

# _kube_restarts — how often the world server's container has restarted in its
# current pod (a crash, or mangosd exiting on 'server restart').
_kube_restarts() {
    local n
    n="$(_kube get pods -l "$(_kube_selector)" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}

_server_start_raw() {
    if _is_kube; then
        _bots_push
        _kube scale deployment "$SERVER_CONTAINER" --replicas=1 >/dev/null
    else
        _container_exists "$SERVER_CONTAINER" || error_exit "No container '${SERVER_CONTAINER}' (set SERVER_CONTAINER)."
        _on_host "$PODMAN" start "$SERVER_CONTAINER" >/dev/null
    fi
}

# _server_stop_raw — stop it, and return only once it has exited: callers write
# the database next.
_server_stop_raw() {
    if ! _is_kube; then _on_host "$PODMAN" stop -t "$STOP_TIMEOUT" "$SERVER_CONTAINER" >/dev/null; return; fi
    local sel; sel="$(_kube_selector)"
    _kube scale deployment "$SERVER_CONTAINER" --replicas=0 >/dev/null
    _kube wait --for=delete pod -l "$sel" --timeout="$((STOP_TIMEOUT + 30))s" >/dev/null 2>&1 || true
    [[ -z "$(_kube_pods)" ]] || error_exit "The world server's pod did not go away within $((STOP_TIMEOUT + 30))s; nothing was written."
}

# -----------------------------------------------------------------------------
# The bot config in a Secret (SERVER_KIND=kube, BOT_SECRET)
#
# The world server reads aiplayerbot.conf and the card file from that Secret.
# teldrassil copies them into its temporary directory, points BOT_CONF and
# CARDS_FILE there, so every command edits them as files, and writes the
# Secret back when they changed: before the server starts (it must start with
# them), and on exit (llm on/off take effect at the next start).
# -----------------------------------------------------------------------------

BOTS_PULLED=0
BOTS_SUM=""

# The card file may not exist (no roster cards yet).
_bots_sum() { { cat -- "$BOT_CONF"; [[ ! -f "$CARDS_FILE" ]] || cat -- "$CARDS_FILE"; } | sha256sum | cut -d' ' -f1; }

_bots_pull() {
    _is_kube && [[ -n "$BOT_SECRET" ]] || return 0
    (( BOTS_PULLED )) && return 0
    local d key; d="$(tmp_dir)/bots"; mkdir -p "$d"
    _kube get secret "$BOT_SECRET" >/dev/null 2>&1 \
        || error_exit "No Secret '${BOT_SECRET}' in ${KUBE_NAMESPACE} (BOT_SECRET): whatever deploys the server creates it."
    for key in aiplayerbot.conf llm_character_card.txt; do
        _kube get secret "$BOT_SECRET" -o "jsonpath={.data.${key//./\\.}}" | base64 -d > "$d/$key" \
            || error_exit "Could not read ${key} from the Secret ${BOT_SECRET}."
    done
    [[ -s "$d/aiplayerbot.conf" ]] || error_exit "The Secret ${BOT_SECRET} has no aiplayerbot.conf."
    [[ -s "$d/llm_character_card.txt" ]] || rm -f -- "$d/llm_character_card.txt"
    BOT_CONF="$d/aiplayerbot.conf"; CARDS_FILE="$d/llm_character_card.txt"
    BOTS_PULLED=1; BOTS_SUM="$(_bots_sum)"
}

# _bots_push — write the Secret back if the files changed. Server-side apply:
# a client-side one keeps a copy of the object in an annotation capped at
# 256 KiB, and aiplayerbot.conf alone is bigger.
_bots_push() {
    (( BOTS_PULLED )) || return 0
    [[ "$(_bots_sum)" != "$BOTS_SUM" ]] || return 0
    local key
    {
        printf 'apiVersion: v1\nkind: Secret\ntype: Opaque\nmetadata:\n  name: %s\n  namespace: %s\ndata:\n' "$BOT_SECRET" "$KUBE_NAMESPACE"
        for key in aiplayerbot.conf llm_character_card.txt; do
            [[ -s "$(dirname "$BOT_CONF")/$key" ]] || continue
            printf '  %s: %s\n' "$key" "$(base64 -w0 < "$(dirname "$BOT_CONF")/$key")"
        done
    } | _kube apply --server-side --force-conflicts --field-manager=teldrassil -f - >/dev/null \
        || error_exit "Could not write the bot config to the Secret ${BOT_SECRET}."
    BOTS_SUM="$(_bots_sum)"
    success "Bot config written to the Secret ${BOT_SECRET}."
}
