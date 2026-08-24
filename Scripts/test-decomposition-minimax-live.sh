#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
script_path="${script_dir}/$(basename "$0")"
repo_root=$(CDPATH= cd -- "${script_dir}/.." && pwd)
appkey_fallback="${HOME}/.grok/skills/appkey/scripts/appkey"
LIVE_SHELL_COMMAND='JELLY_MINIMAX_LIVE=1 JELLY_MINIMAX_BASE_URL=https://api.minimaxi.com/anthropic JELLY_MINIMAX_MODEL=MiniMax-M3 swift test --filter MiniMaxDecompositionLiveTests'
MISSING_MINIMAX_HINT='appkey set minimax --env MINIMAX_API_KEY --prompt'

run_appkey() {
    if command -v appkey >/dev/null 2>&1; then
        command appkey "$@"
    else
        python3 "$appkey_fallback" "$@"
    fi
}

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

run_live() {
    CDPATH= cd -- "$repo_root"
    listed=$(run_appkey list)
    printf '%s\n' "$listed"
    if ! printf '%s\n' "$listed" | awk '$1 == "minimax" { found = 1 } END { exit found ? 0 : 1 }'; then
        printf '%s\n' "$MISSING_MINIMAX_HINT" >&2
        exit 1
    fi
    run_appkey exec minimax -- sh -c "$LIVE_SHELL_COMMAND"
}

no_secret() {
    secret=$1
    shift
    for path in "$@"; do
        [ -e "$path" ] || continue
        if grep -F -q -- "$secret" "$path"; then
            fail "self-test leaked fake secret"
        fi
    done
}

self_test() {
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/jelly-minimax-live-self-test.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT
    secret=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    [ -n "$secret" ] || fail "self-test could not generate fake secret"
    mkdir -p "$tmp/bin"

    cat > "$tmp/bin/appkey" <<'EOF'
#!/bin/sh
set -eu
{ printf '%s\n' "$@"; printf '%s\n' "--"; } >> "$FAKE_APPKEY_LOG"
if [ "$1" = list ]; then
    if [ "${FAKE_APPKEY_MODE:-}" = missing ]; then
        printf '%s\n' "NAME    ENV" "openai  OPENAI_API_KEY"
    else
        printf '%s\n' "NAME     ENV" "minimax  MINIMAX_API_KEY"
    fi
    exit 0
fi
[ "$1" = exec ]
while [ "$#" -gt 0 ]; do
    [ "$1" = "--" ] && { shift; break; }
    shift
done
export MINIMAX_API_KEY="$FAKE_APPKEY_SECRET"
exec "$@"
EOF
    cat > "$tmp/bin/swift" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$@" > "$FAKE_SWIFT_LOG"
[ "$MINIMAX_API_KEY" = "$FAKE_APPKEY_SECRET" ]
printf 'live=%s\nbase=%s\nmodel=%s\n' \
    "$JELLY_MINIMAX_LIVE" \
    "$JELLY_MINIMAX_BASE_URL" \
    "$JELLY_MINIMAX_MODEL" > "$FAKE_SWIFT_PROOF"
EOF
    chmod +x "$tmp/bin/appkey" "$tmp/bin/swift"

    invoke() {
        set +e
        PATH="$tmp/bin:$PATH" \
            FAKE_APPKEY_LOG=$1 \
            FAKE_APPKEY_SECRET=$secret \
            FAKE_APPKEY_MODE=$2 \
            FAKE_SWIFT_LOG=$tmp/swift.log \
            FAKE_SWIFT_PROOF=$tmp/swift.proof \
            sh "$script_path" >"$3" 2>"$4"
        rc=$?
        set -e
    }

    invoke "$tmp/has.log" has "$tmp/has.out" "$tmp/has.err"
    no_secret "$secret" "$tmp/has.out" "$tmp/has.err" "$tmp/has.log" "$tmp/swift.log" "$tmp/swift.proof"
    [ "$rc" -eq 0 ] || fail "self-test expected success when minimax is listed"
    printf '%s\n' list -- exec minimax -- sh -c "$LIVE_SHELL_COMMAND" -- > "$tmp/has.exp"
    cmp -s "$tmp/has.exp" "$tmp/has.log" || fail "self-test expected list then one exec -- sh -c"
    printf '%s\n' test --filter MiniMaxDecompositionLiveTests > "$tmp/swift.exp"
    cmp -s "$tmp/swift.exp" "$tmp/swift.log" || fail "self-test missing swift filter"
    grep -Fxq 'live=1' "$tmp/swift.proof" || fail "self-test missing JELLY_MINIMAX_LIVE=1"
    grep -Fxq 'base=https://api.minimaxi.com/anthropic' "$tmp/swift.proof" || fail "self-test missing MiniMax base URL"
    grep -Fxq 'model=MiniMax-M3' "$tmp/swift.proof" || fail "self-test missing MiniMax-M3 model"

    invoke "$tmp/miss.log" missing "$tmp/miss.out" "$tmp/miss.err"
    no_secret "$secret" "$tmp/miss.out" "$tmp/miss.err" "$tmp/miss.log"
    [ "$rc" -ne 0 ] || fail "self-test expected non-zero when minimax is missing"
    printf '%s\n' list -- > "$tmp/miss.exp"
    cmp -s "$tmp/miss.exp" "$tmp/miss.log" || fail "self-test missing-name must only list"
    grep -Fqx "$MISSING_MINIMAX_HINT" "$tmp/miss.err" "$tmp/miss.out" || fail "self-test missing safe appkey set hint"

    printf '%s\n' "minimax live runner self-test passed"
}

case "${1:-}" in
    --self-test) self_test ;;
    '') run_live ;;
    *)
        printf '%s\n' "usage: $0 [--self-test]" >&2
        exit 1
        ;;
esac
