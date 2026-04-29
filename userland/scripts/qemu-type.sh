#!/bin/bash
#
# qemu-type.sh — "Paste" text into QEMU VGA console via monitor sendkey
#
# Usage: ./qemu-type.sh "command to type"
#        echo "long command" | ./qemu-type.sh
#
# Requires QEMU running with: -monitor telnet:localhost:4444,server,nowait
#
PORT=4444
HOST=localhost
DELAY=0.05

send_key() {
    echo "sendkey $1" | nc -q0 "$HOST" "$PORT" 2>/dev/null || \
    echo "sendkey $1" | nc -w1 "$HOST" "$PORT" 2>/dev/null
}

type_char() {
    local c="$1"
    case "$c" in
        [a-z]) send_key "$c" ;;
        [A-Z]) send_key "shift-$(echo "$c" | tr A-Z a-z)" ;;
        [0-9]) send_key "$c" ;;
        ' ')   send_key "spc" ;;
        '/')   send_key "slash" ;;
        '\\')  send_key "backslash" ;;
        '-')   send_key "minus" ;;
        '=')   send_key "equal" ;;
        '.')   send_key "dot" ;;
        ',')   send_key "comma" ;;
        ';')   send_key "semicolon" ;;
        "'")   send_key "apostrophe" ;;
        '[')   send_key "bracket_left" ;;
        ']')   send_key "bracket_right" ;;
        '`')   send_key "grave_accent" ;;
        '~')   send_key "shift-grave_accent" ;;
        '!')   send_key "shift-1" ;;
        '@')   send_key "shift-2" ;;
        '#')   send_key "shift-3" ;;
        '$')   send_key "shift-4" ;;
        '%')   send_key "shift-5" ;;
        '^')   send_key "shift-6" ;;
        '&')   send_key "shift-7" ;;
        '*')   send_key "shift-8" ;;
        '(')   send_key "shift-9" ;;
        ')')   send_key "shift-0" ;;
        '_')   send_key "shift-minus" ;;
        '+')   send_key "shift-equal" ;;
        '{')   send_key "shift-bracket_left" ;;
        '}')   send_key "shift-bracket_right" ;;
        '|')   send_key "shift-backslash" ;;
        ':')   send_key "shift-semicolon" ;;
        '"')   send_key "shift-apostrophe" ;;
        '<')   send_key "shift-comma" ;;
        '>')   send_key "shift-dot" ;;
        '?')   send_key "shift-slash" ;;
        $'\n')  send_key "ret" ;;
        $'\t')  send_key "tab" ;;
        *)     echo "Unknown char: $c" >&2 ;;
    esac
    sleep "$DELAY"
}

type_string() {
    local s="$1"
    local i=0
    while [ $i -lt ${#s} ]; do
        type_char "${s:$i:1}"
        i=$((i + 1))
    done
}

# Read from argument or stdin
if [ $# -gt 0 ]; then
    INPUT="$*"
else
    INPUT=$(cat)
fi

type_string "$INPUT"
# Send enter at the end
send_key "ret"
