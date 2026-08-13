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
#   test/glyph-protocol.sh            # preflight + full demo
#   test/glyph-protocol.sh doctor     # just the environment / channel diagnosis
#   test/glyph-protocol.sh support    # the support/capability query
#   test/glyph-protocol.sh register   # register the triangle glyph at U+E000 and show it
#   test/glyph-protocol.sh query      # query coverage of U+E000
#   test/glyph-protocol.sh clear      # clear all registrations
#
# IMPORTANT — where to run this:
#   This must run in a shell whose terminal IS the Ghostty build that ships the
#   Glyph Protocol, with the query/response channel intact. If you get "no
#   response" the `doctor` step will tell you why. The usual causes are:
#     * you are inside tmux or GNU screen — they intercept the 25a1 APC before
#       it reaches Ghostty (run outside the multiplexer, or enable passthrough);
#     * the terminal is not the fork Ghostty build (TERM_PROGRAM != ghostty);
#     * stdin/stdout is not a live terminal (output redirected / piped).
#   A correct Ghostty replies to every verb; a terminal without support (or a
#   multiplexer that swallows the APC) stays silent.

set -u

ESC=$'\033'
APC_START="${ESC}_25a1"     # ESC _ 25a1
APC_END="${ESC}\\"          # ESC \  (String Terminator)

# The PUA codepoint we register/query in this demo. U+E000 is the first
# Private Use Area codepoint.
CP_HEX="e000"
CP_CHAR=$''

# A valid TrueType simple-glyph (a triangle), base64-encoded. This is the exact
# payload used by the "glyf: decode triangle" unit test in
# src/terminal/apc/glyph/Glossary.zig, so a correct implementation accepts it.
TRIANGLE_GLYF="AAEAZABkA4QDhAACAAABAQEB9P5wAyADhPzgAAA="

# Set by the last query_read call.
REPLY_RAW=""
# Set by preflight(): 1 if the response channel answered DA1, else 0.
DA1_OK=-1

hr() { printf '%s\n' "------------------------------------------------------------"; }

# Make the ESC framing in a reply human-readable.
visible() { printf '%s' "${1//$ESC/<ESC>}"; }

# Write `payload` to the terminal and read back whatever it replies on the tty.
# Generic: works for any query/response (DA1, glyph, ...). Reads until the tty
# goes quiet for ~80ms after the first byte, or the ~2s budget is exhausted.
# Result lands in REPLY_RAW. Returns 0 if anything was read, 1 otherwise.
#
# Note: capturing single bytes via $(...) cannot represent NUL or trailing
# newline bytes; the glyph and DA1 responses contain neither.
query_read() {
  local payload="$1"
  REPLY_RAW=""

  if [ ! -t 0 ] || [ ! -t 1 ]; then
    printf '%s' "$payload"
    return 1
  fi

  local saved reply="" ch idle=0 i
  saved=$(stty -g)
  stty raw -echo min 0 time 0
  printf '%s' "$payload"

  for ((i = 0; i < 200; i++)); do
    ch=$(dd bs=1 count=1 2>/dev/null)
    if [ -n "$ch" ]; then
      reply+="$ch"
      idle=0
      # Fast path: stop as soon as we see the ST terminator (ESC \).
      case "$reply" in
        *"${ESC}\\") break ;;
      esac
    else
      if [ -n "$reply" ]; then
        idle=$((idle + 1))
        [ "$idle" -ge 8 ] && break
      fi
      sleep 0.01
    fi
  done

  stty "$saved"
  REPLY_RAW="$reply"
  [ -n "$reply" ]
}

# Send an APC glyph message (fields already joined by ';') and read the reply.
#   glyph_query "s"   ->  ESC _ 25a1 ; s ESC \
glyph_query() {
  query_read "${APC_START};${1}${APC_END}"
}

# Environment + response-channel diagnosis. Returns 0 if everything looks sane
# for a live Glyph Protocol test, non-zero if a blocker was detected.
preflight() {
  hr
  echo "[doctor] environment"
  printf '  TERM=%s  TERM_PROGRAM=%s  TERM_PROGRAM_VERSION=%s\n' \
    "${TERM:-<unset>}" "${TERM_PROGRAM:-<unset>}" "${TERM_PROGRAM_VERSION:-<unset>}"

  local blocked=0

  if [ "${TERM_PROGRAM:-}" != "ghostty" ]; then
    echo "  ! TERM_PROGRAM is not 'ghostty'. The Glyph Protocol is a fork-custom"
    echo "    feature; unless this terminal is that Ghostty build, the 25a1 APC is"
    echo "    ignored and every verb stays silent."
    blocked=1
  fi
  if [ -n "${TMUX:-}" ]; then
    echo "  ! Inside tmux (\$TMUX set). tmux intercepts APC sequences, so the"
    echo "    25a1 query never reaches Ghostty. Detach/run outside tmux, or wrap"
    echo "    sequences in tmux passthrough (set allow-passthrough on)."
    blocked=1
  fi
  if [ -n "${STY:-}" ]; then
    echo "  ! Inside GNU screen (\$STY set). screen filters APC sequences; run"
    echo "    outside screen."
    blocked=1
  fi
  if [ -n "${SSH_TTY:-}${SSH_CONNECTION:-}" ]; then
    echo "  · SSH session detected — fine as long as the *local* terminal is Ghostty."
  fi

  # Response-channel sanity check: every real terminal answers Primary Device
  # Attributes (DA1). If even this is silent, the problem is the channel, not
  # the Glyph Protocol.
  printf '  probing response channel with DA1 (ESC [ c) ... '
  if query_read "${ESC}[c"; then
    DA1_OK=1
    printf 'OK\n'
    echo "    DA1 reply: $(visible "$REPLY_RAW")"
  else
    DA1_OK=0
    printf 'DEAD\n'
    echo "    No DA1 reply. This tty is not talking to an interactive terminal"
    echo "    (output piped/redirected, or a terminal that ignores queries)."
    blocked=1
  fi

  return "$blocked"
}

# Explain a silent glyph verb using what preflight learned.
explain_silence() {
  echo "(no response)"
  if [ "$DA1_OK" = "1" ]; then
    echo "  -> The terminal answered DA1 but NOT the Glyph Protocol. Either you are"
    echo "     in a multiplexer (tmux/screen) that swallows the 25a1 APC, or this"
    echo "     terminal is not the Ghostty build with Glyph Protocol support."
  elif [ "$DA1_OK" = "0" ]; then
    echo "  -> The response channel is dead (see the doctor output above), so no"
    echo "     terminal reply of any kind can be read here."
  else
    echo "  -> Run 'test/glyph-protocol.sh doctor' to find out why."
  fi
}

report() {
  if [ -n "$REPLY_RAW" ]; then
    printf 'reply: %s\n' "$(visible "$REPLY_RAW")"
  else
    explain_silence
  fi
}

do_support() {
  hr
  echo "[support] querying Glyph Protocol capability (verb 's')"
  echo "  sent: ESC _ 25a1 ; s ESC \\"
  glyph_query "s"
  report
}

do_register() {
  hr
  echo "[register] registering triangle glyph at U+${CP_HEX} (verb 'r')"
  echo "  sent: ESC _ 25a1 ; r ; cp=${CP_HEX} ; fmt=glyf ; width=1 ; <base64 glyf> ESC \\"
  # reply=1 (default) so we get a success/failure ack we can read.
  glyph_query "r;cp=${CP_HEX};fmt=glyf;width=1;${TRIANGLE_GLYF}"
  report
  printf '\n  U+%s now renders as: [%s]  <- should be a triangle, not tofu\n' \
    "$CP_HEX" "$CP_CHAR"
}

do_query() {
  hr
  echo "[query] asking who covers U+${CP_HEX} (verb 'q')"
  echo "  sent: ESC _ 25a1 ; q ; cp=${CP_HEX} ESC \\"
  echo "  expect status to include 'glossary' after a successful register."
  glyph_query "q;cp=${CP_HEX}"
  report
}

do_clear() {
  hr
  echo "[clear] removing all glyph registrations (verb 'c')"
  echo "  sent: ESC _ 25a1 ; c ESC \\"
  glyph_query "c"
  report
  printf '\n  U+%s should render as tofu again: [%s]\n' "$CP_HEX" "$CP_CHAR"
}

case "${1:-demo}" in
  doctor | d) preflight ;;
  support | s) do_support ;;
  register | r) do_register ;;
  query | q) do_query ;;
  clear | c) do_clear ;;
  demo)
    preflight || echo "  (continuing anyway; the verbs below will likely stay silent)"
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
    echo "usage: $0 [doctor|support|register|query|clear|demo]" >&2
    exit 2
    ;;
esac
