#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      # The grep above can never match pi/pi-signed: FM_HARNESS_RE anchors
      # them (^pi$/^pi-signed$) specifically so the short, generic word "pi"
      # cannot false-positive as a substring inside unrelated args (e.g.
      # "pip", "piano", "spinner") - but that same anchoring requires args to
      # be EXACTLY "pi", which a real invocation's full command line never is.
      # This left every pi session permanently unrecognized as a harness
      # ancestor, on every platform, not only Windows - verified against the
      # real npm-installed `pi` v0.83.0 launcher, whose wrapper script execs a
      # bare node process (`exec node .../pi-coding-agent/dist/cli.js "$@"`)
      # without rewriting argv[0], so neither the comm nor argv0 checks above
      # ever see "pi" either. Recover the same safe path-component semantics
      # fm_harness_path_name already gives comm/argv0, applied to every
      # whitespace-separated token of args: an exact "pi" or "pi-signed"
      # component, or the actual installed package directory
      # "pi-coding-agent" (@earendil-works/pi-coding-agent), both bounded by
      # slashes so they cannot match inside an unrelated longer segment.
      local tok
      # shellcheck disable=SC2086  # deliberate word-splitting over args tokens
      for tok in $args; do
        case "/$tok/" in
          */pi/*|*/pi-signed/*|*/pi-coding-agent/*)
            return 0 ;;
        esac
      done
      ;;
  esac
  return 1
}

# --- Windows (MSYS-family) ancestry ------------------------------------------
#
# Git Bash / MSYS2 / Cygwin break BOTH halves of the POSIX walk below. Their
# `ps` implements none of `-o comm=`, `-o args=`, or `-o ppid=` - it exits with
# "unknown option -- o" on the very first hop - and their process table reports
# the harness-spawned shell's parent as pid 1, so even a working `ps` would find
# no chain. Every session therefore failed to acquire state/.lock and fell back
# to read-only, on a host where the repository itself is perfectly writable.
#
# The Win32 process table does carry a real chain, walkable via
# ParentProcessId - but empirically that chain is only reliable ONE hop at a
# time, not as a multi-hop walk: MSYS's fork/exec emulation for `bash
# <script>` routes every subprocess launch through a short-lived internal
# helper, and Windows' ParentProcessId is a static creation-time attribute
# that is never updated or reparented once that helper exits (unlike POSIX,
# which reparents orphans to pid 1). Verified directly: a freshly spawned
# child bash.exe, confirmed still running via a deliberate 3-second sleep, already
# had a ParentProcessId naming a pid that Get-CimInstance could not find at
# all - not a query race (the child was provably alive throughout), a
# genuinely dead link. So a hook or script invoked as `bash file.sh` can dead-
# end one hop up regardless of how the query is issued, and a script's own
# $$ is itself too short-lived to serve as a stable anchor - it exits the
# moment that one hook/script invocation ends, while state/.lock needs a pid
# that survives for the WHOLE session.
#
# Claude Code sidesteps this entirely: it exports CLAUDE_PID, the pid of the
# actual long-lived claude.exe process for this session (verified: matches
# the real innermost claude.exe found by a full manual ancestry walk from a
# stable shell). fm_harness_ancestry_pids_windows uses it directly with no
# walk at all when present - see below. Harnesses without an equivalent pid
# marker (today: pi, codex, opencode, grok, kimi) fall back to the best-effort
# multi-hop walk, which DOES succeed when the intervening launcher hops
# happen to still be resolvable (verified against a real `pi -p` run, whose
# chain resolved cleanly for 4 hops up to its own node.exe before the first
# dead end - past the point the walk needed to match), but is not guaranteed
# to on every invocation shape. A session lock write that never lands is the
# safe failure mode here (operate read-only), so this asymmetry is accepted
# rather than worked around further.
#
# Pid NAMESPACE: on Windows every pid this file emits or accepts - the ancestry,
# the liveness predicate, and therefore state/.lock's contents - is a Win32 pid.
# That is self-consistent because these functions are the only readers: nothing
# outside this file signals or waits on the lock pid, it is only ever compared
# against this same ancestry.

# True when this shell runs under an MSYS-family runtime on Windows, where the
# POSIX walk cannot work and the Win32 table is the only usable authority.
# FM_HARNESS_PLATFORM_OVERRIDE (posix|windows) exists solely so tests can pin
# this independently of the real host: the unit layer's fake-`ps` cases test
# POSIX comm/args reporting semantics regardless of what platform actually
# runs the suite, and a test host that is ITSELF Windows must not have those
# cases silently rerouted into this file's own Windows dispatch.
fm_harness_platform_is_windows() {
  case "${FM_HARNESS_PLATFORM_OVERRIDE:-}" in
    windows) return 0 ;;
    posix) return 1 ;;
  esac
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  return 1
}

# Print the Win32 pid backing MSYS pid $1, or return 1. FM_PROC_OVERRIDE exists
# so tests can supply a fixture tree in place of the real /proc.
fm_harness_win_pid_of() {  # <msys-pid>
  local proc winpid
  proc=${FM_PROC_OVERRIDE:-/proc}
  winpid=$(cat "$proc/$1/winpid" 2>/dev/null) || return 1
  winpid=$(printf '%s' "$winpid" | tr -d '[:space:]')
  case "$winpid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$winpid"
}

# Print the Win32 ancestry of pid $1, one process per line, outermost-walked
# LAST, as pid<TAB>ppid<TAB>image<TAB>commandline - up to 16 hops, stopping at
# pid 0/1 or the first unresolvable pid. `image` is ExecutablePath when Windows
# will report it and Name otherwise, mirroring what `ps -o comm=` gives on
# macOS: a full path whose components the harness-name check can still read.
# Embedded newlines/tabs are flattened so one process can never span or split
# rows.
#
# Deliberately NOT a single whole-table snapshot (`Get-CimInstance Win32_Process`
# with no filter): enumerating 400+ processes takes long enough that a
# short-lived intermediate - exactly what Git Bash's `bash -c` wrapper chain
# produces for every single command - can exit before the enumeration reaches
# it, so its row is silently absent from that snapshot even though the SAME
# pid resolves fine as a direct target. A targeted per-hop `-Filter` query,
# all issued from one already-running PowerShell process so no cross-process
# timing gap opens between hops, does not have this gap - verified empirically
# against this exact chain shape (bash -> bash -> claude -> claude -> claude,
# and separately node -> sh -> pi's own launcher).
#
# The walk itself lives in the sibling fm-session-lock-win-ancestry.ps1, not an
# inline `-Command` string - see that file's header for why. `${BASH_SOURCE[0]}`
# is this library file regardless of which script sourced it, so the sibling
# path resolves correctly no matter who calls in.
fm_harness_win_ancestry_chain() {  # <win32-pid>
  local self_dir
  self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  powershell.exe -NoProfile -NonInteractive -File "$self_dir/fm-session-lock-win-ancestry.ps1" -StartPid "$1" 2>/dev/null | tr -d '\r'
}

# Split ancestry-chain row $1 into FM_HARNESS_WIN_PID/_PPID/_COMM/_ARGS,
# normalized so the shared matcher can read them: backslashes become forward
# slashes, so the harness-name path check can see components, and a trailing
# .exe is dropped, so an exact-name harness such as `pi` is still recognized
# as `pi.exe`.
FM_HARNESS_WIN_PID=''
FM_HARNESS_WIN_PPID=''
FM_HARNESS_WIN_COMM=''
FM_HARNESS_WIN_ARGS=''
fm_harness_win_row_fields() {  # <row>
  local row=$1
  FM_HARNESS_WIN_PID=$(printf '%s' "$row" | cut -f1)
  FM_HARNESS_WIN_PPID=$(printf '%s' "$row" | cut -f2)
  FM_HARNESS_WIN_COMM=$(printf '%s' "$row" | cut -f3 | tr '\\' '/')
  FM_HARNESS_WIN_ARGS=$(printf '%s' "$row" | cut -f4- | tr '\\' '/')
  FM_HARNESS_WIN_COMM=${FM_HARNESS_WIN_COMM%.exe}
  FM_HARNESS_WIN_COMM=${FM_HARNESS_WIN_COMM%.EXE}
}

# Windows counterpart of fm_harness_ancestry_pids, over Win32 pids. The walk
# semantics are identical - climb freely to the first harness match, then stop
# at the first non-harness ancestor unless the run is Claude, whose whole
# contiguous run is reported - so both platforms answer the same question.
#
# Claude fast path first: CLAUDE_PID names the actual long-lived claude.exe
# process directly (see the header comment above), sidestepping the multi-hop
# walk's dead-end risk entirely. Claude's own env markers are trustworthy
# input here the same way fm-harness.sh already treats them (env markers
# before ancestry, "Detection layers" in its header) - CLAUDE_PID is simply a
# second, Windows-specific marker in that same trusted layer, not an ancestry
# result, so it is checked before the walk rather than folded into it.
fm_harness_ancestry_pids_windows() {
  local pid chain row extending=0 printed=0
  if [ "${CLAUDECODE:-}" = "1" ] && [ -n "${CLAUDE_PID:-}" ]; then
    case "$CLAUDE_PID" in
      *[!0-9]*) : ;;
      *)
        if fm_harness_win_pid_alive "$CLAUDE_PID"; then
          printf '%s\n' "$CLAUDE_PID"
          return 0
        fi
        ;;
    esac
  fi
  pid=$(fm_harness_win_pid_of "$$") || return 1
  chain=$(fm_harness_win_ancestry_chain "$pid") || return 1
  [ -n "$chain" ] || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    fm_harness_win_row_fields "$row"
    if fm_harness_process_matches "$FM_HARNESS_WIN_COMM" "$FM_HARNESS_WIN_ARGS"; then
      printf '%s\n' "$FM_HARNESS_WIN_PID"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
  done <<EOF
$chain
EOF
  [ "$printed" -eq 1 ]
}

# Windows counterpart of fm_harness_pid_alive. The Win32 table is the only
# authority here: `kill -0` and `ps` answer for MSYS pids, while the lock holds
# a Win32 one, so asking them would compare two different namespaces. A single
# targeted query (chain length 1) - not the whole-table snapshot that drops
# short-lived rows, see fm_harness_win_ancestry_chain.
fm_harness_win_pid_alive() {  # <win32-pid>
  local pid=$1 row
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  row=$(fm_harness_win_ancestry_chain "$pid" | head -n 1) || return 1
  [ -n "$row" ] || return 1
  fm_harness_win_row_fields "$row"
  [ "$FM_HARNESS_WIN_PID" = "$pid" ] || return 1
  fm_harness_process_matches "$FM_HARNESS_WIN_COMM" "$FM_HARNESS_WIN_ARGS"
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  fm_harness_platform_is_windows && { fm_harness_ancestry_pids_windows; return; }
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  fm_harness_platform_is_windows && { fm_harness_win_pid_alive "$pid"; return; }
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
