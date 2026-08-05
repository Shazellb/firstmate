#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone. Pinned to the
# posix dispatch (FM_HARNESS_PLATFORM_OVERRIDE) so these POSIX comm/args
# semantics are exercised the same way on every test host, including one that
# is itself Windows - see fm_harness_platform_is_windows's own header comment.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" FM_HARNESS_PLATFORM_OVERRIDE=posix bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

# --- pi bare-interpreter regression -------------------------------------------
# pi's own npm-installed launcher execs a bare node process
# (`exec node .../pi-coding-agent/dist/cli.js "$@"`) without rewriting argv[0],
# so neither the comm nor argv0 checks ever see "pi" - and FM_HARNESS_RE's
# ^pi$/^pi-signed$ alternatives are anchored to the WHOLE args line specifically
# so the short, generic word "pi" cannot false-positive inside unrelated args
# (e.g. "pip", "piano", "spinner"), which means they can never match a real
# invocation's full command line either. Platform-agnostic: this is a plain
# fm_harness_process_matches call, no ps/ancestry involved, so it runs the same
# on every host regardless of what fixed this repo's own CI.
test_pi_bare_interpreter_matches_via_path_component() {
  local dir fakebin
  dir="$TMP_ROOT/pi-bare-interpreter"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"

  lib_eval "$fakebin" \
    "fm_harness_process_matches node '/usr/bin/node /home/u/.npm-global/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js -p hello'" \
    || fail "a bare node process running pi-coding-agent's cli.js was not recognized as the pi harness"

  lib_eval "$fakebin" \
    "fm_harness_process_matches node '/usr/bin/node /opt/tools/pi/bin/cli.js --once'" \
    || fail "a bare node process running an exact pi/ path component was not recognized"

  lib_eval "$fakebin" \
    "fm_harness_process_matches node '/usr/bin/node /opt/tools/pi-signed/bin/cli.js --once'" \
    || fail "a bare node process running an exact pi-signed/ path component was not recognized"

  # Still must not false-positive on ordinary words that merely start with "pi".
  if lib_eval "$fakebin" \
    "fm_harness_process_matches node '/usr/bin/node /opt/pipeline/dist/cli.js --once'"; then
    fail "a bare node process running an unrelated 'pipeline' path was wrongly recognized as pi"
  fi
  if lib_eval "$fakebin" \
    "fm_harness_process_matches node '/usr/bin/node /home/u/piano-tuner/dist/cli.js --once'"; then
    fail "a bare node process running an unrelated 'piano-tuner' path was wrongly recognized as pi"
  fi
  pass "session-lock: a bare node process running pi's own launcher path is recognized as the pi harness"
}

# --- Windows (MSYS-family) ancestry -------------------------------------------
# Same unit-layer approach as the POSIX cases above, but shadowing powershell.exe
# and /proc/<pid>/winpid instead of ps, and pinning
# FM_HARNESS_PLATFORM_OVERRIDE=windows instead of relying on the real host's
# uname - fm-session-lock-lib.sh dispatches to a completely different code path
# once fm_harness_platform_is_windows is true (see its own header comment for
# why: MSYS's ps has no -o support at all, and MSYS reports every process's
# ppid as 1). Runs on any host: none of this depends on a real Windows machine,
# only on the fakes below and the override.
win_lib_eval() {  # <fakebin> <proc-root> <expression>
  local fakebin=$1 procroot=$2 expr=$3
  PATH="$fakebin:$PATH" FM_PROC_OVERRIDE="$procroot" FM_HARNESS_PLATFORM_OVERRIDE=windows bash -c "
    . \"\$0\"
    $expr
  " "$LIB"
}

# A fake powershell.exe standing in for fm-session-lock-win-ancestry.ps1: reads
# -StartPid from argv and prints the pre-scripted chain for it from
# FM_TEST_WIN_CHAIN_<pid>, one line already in the pid<TAB>ppid<TAB>image<TAB>args
# shape the real .ps1 produces. Ignores -File entirely, so it works whether or
# not the real script exists on this host.
fake_powershell() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
set -u
startpid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -StartPid) startpid=$2; shift 2 ;;
    *) shift ;;
  esac
done
var="FM_TEST_WIN_CHAIN_$startpid"
eval "printf '%s\n' \"\${$var:-}\""
SH
  chmod +x "$fakebin/powershell.exe"
}

test_windows_claude_pid_fast_path_skips_the_walk() {
  local dir fakebin procroot
  dir="$TMP_ROOT/windows-claude-pid"
  fakebin=$(fm_fakebin "$dir")
  procroot="$dir/proc"
  fake_powershell "$fakebin"

  got=$(CLAUDECODE=1 CLAUDE_PID=37884 \
    FM_TEST_WIN_CHAIN_37884=$'37884\t40456\tC:/npm/claude.exe\tC:/npm/claude.exe --agent claude' \
    win_lib_eval "$fakebin" "$procroot" 'fm_harness_ancestry_pid') \
    || fail "the CLAUDE_PID fast path did not resolve an ancestry pid"
  [ "$got" = 37884 ] || fail "expected the CLAUDE_PID fast path to resolve 37884, got '$got'"
  pass "session-lock windows: CLAUDE_PID is used directly, without walking Win32 ParentProcessId"
}

test_windows_walk_finds_pi_through_bare_node_hop() {
  local dir fakebin procroot chain
  dir="$TMP_ROOT/windows-pi-walk"
  fakebin=$(fm_fakebin "$dir")
  procroot="$dir/proc"
  fake_powershell "$fakebin"
  mkdir -p "$procroot/5001"
  printf '11111\n' > "$procroot/5001/winpid"

  # 11111 (bash) -> 22222 (bash) -> 33333 (node, pi-coding-agent in args): the
  # real shape observed from a live `pi -p` run.
  chain=$'11111\t22222\tC:/Git/usr/bin/bash.exe\t"C:/Git/usr/bin/bash.exe" -c "pi_probe.sh"\n22222\t33333\tC:/Git/usr/bin/bash.exe\t"C:/Git/usr/bin/bash.exe" -c "..."\n33333\t44444\tC:/Program Files/nodejs/node.exe\tC:/Program Files/nodejs/node.exe C:/npm/node_modules/@earendil-works/pi-coding-agent/dist/cli.js -p x'

  # $$ is bash's own read-only pid, so the fixture can't just point it at
  # 5001 - drive fm_harness_win_ancestry_chain and the same match/extend loop
  # fm_harness_ancestry_pids_windows uses, directly against the seeded start pid.
  got=$(FM_TEST_WIN_CHAIN_11111="$chain" \
    win_lib_eval "$fakebin" "$procroot" '
      pid=$(fm_harness_win_pid_of 5001)
      chain=$(fm_harness_win_ancestry_chain "$pid")
      extending=0
      while IFS= read -r row; do
        [ -n "$row" ] || continue
        fm_harness_win_row_fields "$row"
        if fm_harness_process_matches "$FM_HARNESS_WIN_COMM" "$FM_HARNESS_WIN_ARGS"; then
          printf "%s\n" "$FM_HARNESS_WIN_PID"
          break
        fi
      done <<EOF
$chain
EOF
    ') || fail "the Windows walk did not resolve any pid for the pi chain"
  [ "$got" = 33333 ] || fail "expected the walk to match pi's node.exe (33333), got '$got'"
  pass "session-lock windows: the best-effort walk finds pi through a bare node.exe hop"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

test_version_named_session_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_pi_bare_interpreter_matches_via_path_component
test_windows_claude_pid_fast_path_skips_the_walk
test_windows_walk_finds_pi_through_bare_node_hop
test_competing_version_named_session_is_seen_as_live
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
