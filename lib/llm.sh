# shellcheck shell=bash
# lib/llm.sh — llm: bots' chat through a language model, optional and off by
# default.
#
# playerbots can send what players say to a bot to an OpenAI-style chat
# endpoint (LM Studio, llama.cpp's server, a hosted API) and answer with the
# reply, using each bot's character card. Nothing else depends on it: with it
# off, bots answer from playerbots' own canned lines. Changes take effect at
# the next restart.
#
# Part of teldrassil.sh, which sources it; not meant to run on its own.

_llm_get() { grep -E "^AiPlayerbot\.${1}[[:space:]]*=" "$BOT_CONF" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^[[:space:]]*//' || true; }

cmd_llm() {
    local sub="${1:-status}"; [[ $# -gt 0 ]] && shift
    _require_bot_conf
    case "$sub" in
        status) _llm_status ;;
        off)    [[ $# -eq 0 ]] || error_exit "Usage: llm off"; _llm_write --set AiPlayerbot.LLMEnabled=0
                success "LLM chat off (from the next restart): bots answer with playerbots' own lines." ;;
        on)     _llm_on "$@" ;;
        *) error_exit "Usage: llm status | off | on --endpoint URL --model NAME [--max-tokens N] [--reasoning-effort LEVEL] [--bot-to-bot PERCENT] [--api-key-file FILE]" ;;
    esac
}

_llm_status() {
    local enabled; enabled="$(_llm_get LLMEnabled)"
    case "$enabled" in
        1|2|3) ;;
        *) printf 'LLM chat: off\n'; return 0 ;;
    esac
    printf 'LLM chat: on (LLMEnabled %s: %s)\n' "$enabled" \
        "$(case "$enabled" in 1) echo "only bots given the 'ai chat' strategy" ;; 2) echo "every bot" ;; 3) echo "every bot, without the strategy" ;; esac)"
    printf 'Endpoint: %s\n' "$(_llm_get LLMApiEndpoint)"
    printf 'Request:  %s\n' "$(_llm_get LLMApiJson | sed -E 's/"messages": \[[^]]*\], //')"
    printf 'Bot-to-bot chance: %s%%\n' "$(_llm_get LLMBotToBotChatChance)"
    return 0
}

# _llm_write --set K=V ... [--secret-file F] — edit aiplayerbot.conf, keeping a backup.
_llm_write() {
    local tmp; tmp="$(tmp_dir)/aiplayerbot.conf"
    helper conf --conf "$BOT_CONF" --out "$tmp" "$@" >/dev/null
    _backup "$BOT_CONF"
    cat -- "$tmp" > "$BOT_CONF"
}

_llm_on() {
    local endpoint="" model="" tokens=80 effort="" b2b=0 keyfile="" json code
    while [[ $# -gt 0 ]]; do case "$1" in
        --endpoint) _need_value "$@"; endpoint="$2"; shift 2 ;;
        --model) _need_value "$@"; model="$2"; shift 2 ;;
        --max-tokens) _need_value "$@"; tokens="$2"; shift 2 ;;
        --reasoning-effort) _need_value "$@"; effort="$2"; shift 2 ;;
        --bot-to-bot) _need_value "$@"; b2b="$2"; shift 2 ;;
        --api-key-file) _need_value "$@"; keyfile="$2"; shift 2 ;;
        *) error_exit "llm on: unknown flag $1" ;;
    esac; done
    [[ -n "$endpoint" && -n "$model" ]] || error_exit "Usage: llm on --endpoint URL --model NAME (an OpenAI-style .../v1/chat/completions endpoint)"
    [[ "$endpoint" =~ ^https?:// ]] || error_exit "--endpoint is a URL (http://... or https://...)."
    [[ "$tokens" =~ ^[1-9][0-9]*$ ]] || error_exit "--max-tokens must be a positive number."
    [[ "$b2b" =~ ^([0-9]|[1-9][0-9]|100)$ ]] || error_exit "--bot-to-bot is a percentage, 0-100."
    [[ -z "$keyfile" || -r "$keyfile" ]] || error_exit "Cannot read ${keyfile}."
    json="$(python3 -I -c 'import json,sys
body={"model": sys.argv[1], "messages": [{"role": "system", "content": "<pre prompt> <context>"}, {"role": "user", "content": "<prompt>"}], "max_tokens": int(sys.argv[2])}
if sys.argv[3]: body["reasoning_effort"] = sys.argv[3]
print(json.dumps(body))' "$model" "$tokens" "$effort")"
    local -a set=(--set "AiPlayerbot.LLMEnabled=2" --set "AiPlayerbot.LLMApiEndpoint=${endpoint}"
                  --set "AiPlayerbot.LLMApiJson=${json}" --set 'AiPlayerbot.LLMResponseStartPattern=("content":\s*")'
                  --set "AiPlayerbot.LLMBotToBotChatChance=${b2b}")
    # A key is read from its file by the helper, never put on a command line.
    if [[ -n "$keyfile" ]]; then set+=(--set "AiPlayerbot.LLMApiKey=@SECRET@" --secret-file "$keyfile"); fi
    _llm_write "${set[@]}"
    success "LLM chat on (from the next restart): every bot, through ${endpoint}, model ${model}."
    code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "${endpoint%/chat/completions}/models" || true)"
    if [[ "$code" != 200 ]]; then warn "The endpoint does not answer now (http ${code:-none}); bots fall back to their own lines until it does."; fi
    return 0
}
