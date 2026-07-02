#!/usr/bin/env bash
#
# Manual test harness for the Glyph Protocol (fork-custom APC protocol).
#
# The Glyph Protocol lets an application register a TrueType simple-glyph
# outline at a Private Use Area codepoint and have the terminal render it in
# place of the system font / tofu. See src/terminal/apc/glyph.zig for the spec.
#
# Wire framing:  ESC _ 25a1 ; <verb> [ ; key=value ]* [ ; <payload> ] ESC \
# Verbs:         s (support)  q (query)  r (register)  c (clear)
#
# Usage:
#   test/glyph-protocol.sh            # run the full demo (support, register, show, query, clear)
#   test/glyph-protocol.sh support    # just the support/capability query
#   test/glyph-protocol.sh register   # register the triangle glyph at U+E000 and show it
#   test/glyph-protocol.sh query      # query coverage of U+E000
#   test/glyph-protocol.sh clear      # clear all registrations
#
# Run this inside Ghostty (or another terminal claiming Glyph Protocol support).
# In an unsupporting terminal the APC sequences are silently ignored, so the
# "support" step will time out and report "no response".

set -u

ESC=$'\033'
APC_START="${ESC}_25a1"     # ESC _ 25a1
APC_END="${ESC}\\"          # ESC \  (String Terminator)

# The PUA codepoint we register/query in this demo. U+E000 is the first
# Private Use Area codepoint.
CP_HEX="e000"
CP_CHAR=$''

# A valid TrueType simple-glyph (a triangle), base64-encoded. This is the exact
# payload used by the "glyf: decode triangle" unit test in
# src/terminal/apc/glyph/Glossary.zig, so a correct implementation accepts it.
TRIANGLE_GLYF="AAEAZABkA4QDhAACAAABAQEB9P5wAyADhPzgAAA="

# Send a raw APC message. Args are the fields after the identifier, already
# joined by ';'. Example: send "s"   ->  ESC _ 25a1 ; s ESC \
send() {
  printf '%s;%s%s' "$APC_START" "$1" "$APC_END"
}

# Send an APC message and read back a single APC reply (if any) within a short
# timeout. Prints the decoded reply, or "(no response — protocol unsupported or
# reply suppressed)". Requires a real tty.
send_and_read() {
  local payload="$1" reply=""
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    send "$payload"
    printf '\n(not a tty — cannot read reply)\n'
    return
  fi

  local saved
  saved=$(stty -g)
  stty raw -echo min 0 time 0
  send "$payload"

  # Poll for a reply for up to ~1s. The reply is framed by ESC \ (ST).
  local i ch
  for ((i = 0; i < 100; i++)); do
    ch=$(dd bs=1 count=1 2>/dev/null)
    if [ -n "$ch" ]; then
      reply+="$ch"
      # Stop once we've seen the ST terminator (backslash after ESC).
      case "$reply" in
        *"${ESC}\\") break ;;
      esac
    else
      # Nothing available yet; small sleep then retry.
      sleep 0.01
    fi
  done
  stty "$saved"

  if [ -z "$reply" ]; then
    printf '(no response — protocol unsupported or reply suppressed)\n'
  else
    # Render the reply visibly (make the ESC framing readable).
    local visible=${reply//$ESC/<ESC>}
    printf 'reply: %s\n' "$visible"
  fi
}

hr() { printf '%s\n' "------------------------------------------------------------"; }

do_support() {
  hr
  echo "[support] querying Glyph Protocol capability (verb 's')"
  echo "  sent: ESC _ 25a1 ; s ESC \\"
  send_and_read "s"
}

do_register() {
  hr
  echo "[register] registering triangle glyph at U+${CP_HEX} (verb 'r')"
  echo "  sent: ESC _ 25a1 ; r ; cp=${CP_HEX} ; fmt=glyf ; width=1 ; <base64 glyf> ESC \\"
  # reply=1 (default) so we get a success/failure ack we can read.
  send_and_read "r;cp=${CP_HEX};fmt=glyf;width=1;${TRIANGLE_GLYF}"
  printf '\n  U+%s now renders as: [%s]  <- should be a triangle, not tofu\n' \
    "$CP_HEX" "$CP_CHAR"
}

do_query() {
  hr
  echo "[query] asking who covers U+${CP_HEX} (verb 'q')"
  echo "  sent: ESC _ 25a1 ; q ; cp=${CP_HEX} ESC \\"
  echo "  expect status to include 'glossary' after a successful register."
  send_and_read "q;cp=${CP_HEX}"
}

do_clear() {
  hr
  echo "[clear] removing all glyph registrations (verb 'c')"
  echo "  sent: ESC _ 25a1 ; c ESC \\"
  send_and_read "c"
  printf '\n  U+%s should render as tofu again: [%s]\n' "$CP_HEX" "$CP_CHAR"
}

case "${1:-demo}" in
  support | s) do_support ;;
  register | r) do_register ;;
  query | q) do_query ;;
  clear | c) do_clear ;;
  demo)
    do_support
    do_register
    do_query
    hr
    read -r -p "Press Enter to clear the registration... " _
    do_clear
    hr
    echo "done."
    ;;
  *)
    echo "unknown command: $1" >&2
    echo "usage: $0 [support|register|query|clear|demo]" >&2
    exit 2
    ;;
esac
