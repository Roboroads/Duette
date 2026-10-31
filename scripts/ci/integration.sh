#!/usr/bin/env bash
# Headless integration checks on a macOS runner (or a Mac you can spare): installs the driver
# with its CI test devices, grants the TCC permissions, runs duettectl's commands against the real
# HAL and writes a pass/fail table. Run from .github/workflows/integration.yml.
#
# Usage: scripts/ci/integration.sh <phase> [args]
#   setup               build what is missing, grant TCC, install build/test-out/Duette.driver
#   blocking            every check; each must pass on the runner
#   soak [MIN] [FRAMES] the long engine run (default 10 minutes at 128 frames)
#   summary             the table, to stdout and $GITHUB_STEP_SUMMARY; uninstalls the driver
#   all                 setup, blocking, summary
#
# Results go to build/integration/: results.tsv (every check, from duettectl --report),
# commands.tsv (one line per command) and one log per command.
#
# It changes the machine: it writes TCC.db rows, restarts coreaudiod, installs and uninstalls the
# plug-in and changes the default devices. So it runs only in GitHub Actions, or where
# DUETTE_ALLOW_LOCAL=1 says the Mac can take it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
repo_root=$(pwd)
out=$repo_root/build/integration
cli=$repo_root/build/out/duettectl
driver=$repo_root/build/test-out/Duette.driver
results=$out/results.tsv
commands=$out/commands.tsv
mkdir -p "$out"

if [ "$(uname -s)" != Darwin ]; then
  echo "integration.sh: macOS only" >&2
  exit 2
fi
if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${DUETTE_ALLOW_LOCAL:-}" != 1 ]; then
  echo "integration.sh: this rewrites TCC.db, restarts coreaudiod and uninstalls the driver." >&2
  echo "It runs in GitHub Actions; on a Mac you can spare, set DUETTE_ALLOW_LOCAL=1." >&2
  exit 2
fi

# Runs a command with a time limit (macOS has no timeout(1)); exit status 124 when it ran out.
with_timeout() { # seconds command...
  local limit=$1
  shift
  "$@" &
  local pid=$!
  (
    sleep "$limit"
    kill -TERM "$pid" 2>/dev/null && sleep 5 && kill -KILL "$pid" 2>/dev/null
  ) &
  local watcher=$! rc=0
  wait "$pid" || rc=$?
  if kill -0 "$watcher" 2>/dev/null; then
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
  else
    rc=124
  fi
  return "$rc"
}

# Helpers a command started and did not stop (afplay, a reader or player duettectl).
kill_leftovers() {
  pkill -x afplay 2>/dev/null || true
  pkill -f "$cli reader" 2>/dev/null || true
  pkill -f "$cli play" 2>/dev/null || true
}

# ---------------------------------------------------------------------------------- helpers

# Runs one duettectl command. A stack sample is taken shortly before its watchdog would fire,
# so a call that never returns shows where it is stuck.
#   run_cmd <group> <id> <seconds> <headline checks> -- <duettectl args...>
run_cmd() {
  local group=$1 id=$2 limit=$3 headline=$4
  shift 5
  local log=$out/$id.log
  local started=$SECONDS rc=0
  echo "::group::$id: duettectl $*"
  "$cli" --report "$results" --label "$id" --timeout "$limit" "$@" >"$log" 2>&1 &
  local pid=$!
  (
    sleep $((limit > 15 ? limit - 8 : limit))
    if kill -0 "$pid" 2>/dev/null; then
      echo "==> $id is still running after $((limit - 8)) s; sampling it" >>"$log.sample"
      sample "$pid" 3 -mayDie -file "$out/$id.sample.txt" >/dev/null 2>&1 || true
    fi
    # duettectl's own watchdog ends it at `limit`; if even that is stuck, end it here.
    sleep 20
    kill -KILL "$pid" 2>/dev/null || true
  ) &
  local watcher=$!
  wait "$pid" || rc=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  kill_leftovers
  cat "$log"
  if [ -f "$out/$id.sample.txt" ]; then
    echo "---- stack sample of the stuck command (main and audio threads) ----"
    grep -E 'Thread_|Call graph|AudioDevice|AudioHardware|HALC_|HALS_|TCC|tcc|xpc|mach_msg|semaphore|duettectl' \
      "$out/$id.sample.txt" | head -n 80 || true
  fi
  echo "::endgroup::"
  printf '%s\t%s\t%s\t%s\t%s\n' "$group" "$id" "$rc" "$((SECONDS - started))" "$headline" >>"$commands"
  if [ "$rc" -eq 0 ]; then
    echo "PASS $id"
  else
    echo "FAIL $id (exit $rc)"
  fi
  return "$rc"
}

# Records a check that duettectl did not make (for example from the DuetteKit tests).
add_check() { # id name status value detail
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >>"$results"
}

tcc_clients() {
  local responsible_pid responsible_path p c
  responsible_pid=$("$cli" whoami 2>/dev/null | sed -n 's/^RESPONSIBLE_PID=//p' | head -n 1)
  responsible_path=$(ps -o comm= -p "${responsible_pid:-1}" 2>/dev/null || true)
  {
    echo "$cli"
    echo /usr/bin/afplay
    echo "$responsible_path"
    p=$$
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
      c=$(ps -o comm= -p "$p" 2>/dev/null || true)
      echo "$c"
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    done
  } | grep '^/' | sort -u
}

user_tcc_db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
system_tcc_db="/Library/Application Support/com.apple.TCC/TCC.db"

# Sets Microphone and AudioCapture (System Audio Recording) for every client in both TCC
# databases: auth_value 2 allows, 0 denies. The inserts are S3's, which tccd honours on the
# runner (authValue=2 authReason=4). They must be in place before the first tap.
tcc_set() { # auth_value [services...]
  local value=$1
  shift
  local services=${*:-kTCCServiceMicrophone kTCCServiceAudioCapture}
  local client svc db
  while IFS= read -r client; do
    [ -n "$client" ] || continue
    for svc in $services; do
      for db in "$user_tcc_db" "$system_tcc_db"; do
        sudo sqlite3 "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags) VALUES ('$svc', '$client', 1, $value, 4, 1, 0);" \
          || echo "::warning::TCC insert failed: $db $svc $client"
      done
    done
  done <<EOF
$(tcc_clients)
EOF
  sudo killall tccd 2>/dev/null || true
  killall tccd 2>/dev/null || true
  sleep 1
}

tcc_show() {
  local db
  for db in "$user_tcc_db" "$system_tcc_db"; do
    echo "== $db"
    sudo sqlite3 "$db" "SELECT service, client, auth_value, auth_reason FROM access WHERE service IN ('kTCCServiceMicrophone','kTCCServiceAudioCapture') ORDER BY service, client;" || true
  done
}

restart_coreaudiod() {
  sudo killall coreaudiod 2>/dev/null || sudo launchctl kickstart -k system/com.apple.audio.coreaudiod || true
  sleep 2
}

# ------------------------------------------------------------------------------------ phases

phase_setup() {
  : >"$results"
  : >"$commands"
  rm -f "$out"/*.log "$out"/*.sample.txt "$out"/*.log.sample "$out/setup-done"

  echo "::group::build"
  if [ ! -d "$driver" ]; then
    bash scripts/ci/build-driver.sh
  fi
  if [ ! -x "$cli" ]; then
    DUETTECTL_SKIP_TESTS=1 bash scripts/ci/build-cli.sh
  fi
  echo "::endgroup::"

  echo "::group::machine"
  sw_vers
  csrutil status || true
  "$cli" whoami
  echo "::endgroup::"

  # TCC first: a tap that runs before the grant can leave a permission request pending.
  echo "::group::TCC: allow Microphone and System Audio Recording"
  tcc_clients
  tcc_set 2
  tcc_show
  echo "::endgroup::"

  echo "::group::install the driver with the test devices"
  sudo bash scripts/install.sh --driver "$driver" --no-app
  echo "::endgroup::"

  # The HAL can take a moment to publish the devices after coreaudiod restarts.
  run_cmd setup list 60 "sink.hidden test-mic.listed test-speaker.listed" -- list --test-devices
  touch "$out/setup-done"
}

require_setup() {
  if [ ! -f "$out/setup-done" ]; then
    echo "integration.sh: run the setup phase first (it failed or did not run)" >&2
    exit 1
  fi
}

phase_blocking() {
  require_setup
  local failed=0
  # M1: the driver alone, then the hidden sink as the engine's main device.
  run_cmd blocking selftest 60 "tone.left.440hz off.silence" -- selftest || failed=1
  run_cmd blocking loopback-128 90 "latency latency.worst sample-offset silence-after-stop takes" -- --buffer 128 loopback || failed=1
  run_cmd blocking loopback-64 90 "latency latency.worst sample-offset silence-after-stop takes" -- --buffer 64 loopback || failed=1
  run_cmd blocking hidden-agg 60 "main-subdevice clock-device ioproc-runs engine-tone.440hz" -- hidden-agg || failed=1
  # M2 and M4 on the mic path.
  run_cmd blocking engine 60 "duette.1000hz overloads" -- engine --mic test-mic --seconds 3 --expect '1000@-12' || failed=1
  run_cmd blocking verify-mic 150 "mic.1000hz mic.residual mic-gain-0.5.1000hz mic-mute.silence engine-tone.440hz windows.clean overloads" -- verify-mic || failed=1
  # M3 and M4: a process tap mixed with the mic, at 48 kHz and at 44.1 kHz.
  run_cmd blocking verify-mix 150 "mix.440hz mix.1000hz residual app-gain-0.5.440hz mic-muted.1000hz app-muted.440hz windows.clean overloads" -- verify-mix || failed=1
  run_cmd blocking rate-mismatch 150 "tap mix.440hz mix.1000hz residual app-muted.440hz windows.clean" -- rate-mismatch || failed=1
  # 'dcli' and the feedback-loop warning: readers that read directly, two at once, through an
  # aggregate or through VPIO.
  run_cmd blocking dcli-direct 60 "direct.lists-pid direct.clears" -- dcli --mode direct || failed=1
  run_cmd blocking dcli-concurrent 60 "concurrent.first-listed concurrent.second-listed concurrent.second-clears" -- dcli --mode concurrent || failed=1
  run_cmd blocking dcli-aggregate 60 "aggregate.lists-pid aggregate.clears" -- dcli --mode aggregate || failed=1
  run_cmd blocking dcli-vpio 60 "vpio.lists-pid vpio.clears" -- dcli --mode vpio || failed=1
  run_cmd blocking feedback-loop 120 "dcli.lists-own-process dcli.lists-app detector.fires detector.ignores-own-process controller.warns controller.clears" \
    -- feedback-loop --controller || failed=1

  # DuetteKit's HAL tests, now with the driver installed: testHiddenSinkAsMainSubdeviceRunsTheEngine
  # runs here instead of being skipped.
  echo "::group::DuetteKit HALSmokeTests with the driver installed"
  local log=$out/kit-hal-tests.log rc=0 started=$SECONDS
  with_timeout 900 swift test --package-path Packages/DuetteKit --scratch-path build/kit/debug --filter HALSmokeTests >"$log" 2>&1 || rc=$?
  [ "$rc" -ne 124 ] || echo "::error::DuetteKit HALSmokeTests did not finish in 900 s"
  grep -E "Test Case|HAL |error|failed|skipped" "$log" | tail -n 80 || true
  echo "::endgroup::"
  printf '%s\t%s\t%s\t%s\t%s\n' blocking kit-hal-tests "$rc" "$((SECONDS - started))" "hidden-sink-engine" >>"$commands"
  if grep -q "testHiddenSinkAsMainSubdeviceRunsTheEngine\]' passed" "$log"; then
    add_check kit-hal-tests hidden-sink-engine PASS "passed" "DuetteKit testHiddenSinkAsMainSubdeviceRunsTheEngine"
  else
    add_check kit-hal-tests hidden-sink-engine FAIL "did not pass" "skipped or failed: see kit-hal-tests.log"
    failed=1
  fi
  [ "$rc" -eq 0 ] || failed=1

  # TCC denial: what an app sees when System Audio Recording is off. Last, and put back after.
  echo "::group::TCC: deny System Audio Recording"
  tcc_set 0 kTCCServiceAudioCapture
  restart_coreaudiod
  "$cli" list >/dev/null 2>&1 || true
  echo "::endgroup::"
  run_cmd blocking tcc-denied 150 "state denied.tap-zeros denied.1000hz denied.hint" -- verify-mix --expect-denied || failed=1
  echo "::group::TCC: allow System Audio Recording again"
  tcc_set 2 kTCCServiceAudioCapture
  restart_coreaudiod
  "$cli" list >/dev/null 2>&1 || true
  echo "::endgroup::"
  return "$failed"
}

# UID of the machine's own output device with this name, from duettectl list.
output_uid() { # name
  "$cli" list 2>/dev/null | sed -n "s/.*device [0-9]* '$1' uid=\(.*\) in=[0-9]* out=[1-9].*/\1/p" | head -n 1
}

# The soak wants zero overloads and no dropouts for 10 minutes. The runner is a VM whose I/O
# threads wake late now and then (coreaudiod: "Overload possibly due to safety violation"), so
# first the same shapes run on the machine's own devices with an IOProc that only copies: one
# output device, and an aggregate of an output and a second clock (drift compensated), which is
# what the engine runs. The verdict:
#   PASS            the soak passed;
#   needs hands-on  it failed, but every failed second had an overload and the machine's own
#                   devices overloaded too (checklist steps 6 and 7d decide, on a real Mac);
#   FAIL            anything else.
phase_soak() {
  require_setup
  local minutes=${1:-10} buffer=${2:-128}
  local limit rc=0 controls=0 unexplained group
  local apple null sink=me.roboroads.duette.sink mic=me.roboroads.duette.test-mic
  limit=$(awk -v m="$minutes" 'BEGIN { printf "%d", m * 60 + 240 }')
  apple=$(output_uid 'Apple Virtual Sound Device')
  null=$(output_uid 'Null Audio Device')
  if [ -n "$apple" ]; then
    run_cmd control "control-apple-$buffer" 120 "count" -- --buffer "$buffer" overloads --device "$apple" --seconds 60 || true
    if [ -n "$null" ]; then
      run_cmd control "control-apple-aggregate-$buffer" 120 "count" -- --buffer "$buffer" overloads --device "$apple" --with "$null" --seconds 60 || true
    fi
  fi
  run_cmd control "control-duette-sink-$buffer" 120 "count" -- --buffer "$buffer" overloads --device "$sink" --seconds 60 || true
  run_cmd control "control-duette-aggregate-$buffer" 120 "count" -- --buffer "$buffer" overloads --device "$sink" --with "$mic" --seconds 60 || true
  run_cmd soak "soak-$buffer" "$limit" "windows windows.unexplained overloads reader-overloads dropouts" -- --buffer "$buffer" soak --minutes "$minutes" || rc=$?
  [ "$rc" -ne 0 ] || return 0

  # Overloads the machine's own devices had in the controls.
  controls=$(awk -F'\t' -v b="-$buffer" '$1 ~ /^control-/ && $1 ~ b"$" && $2 == "count" { split($4, a, " "); n += a[1] } END { print n + 0 }' "$results")
  unexplained=$(awk -F'\t' -v id="soak-$buffer" '$1 == id && $2 == "windows.unexplained" { print $3 }' "$results" | tail -n 1)
  if [ "$rc" -ne 124 ] && [ "$unexplained" = PASS ] && [ "$controls" -gt 0 ]; then
    group=hands-on
    add_check "soak-$buffer" verdict INFO "needs hands-on" "every failed second had an overload; the machine's own devices had $controls in the controls"
  else
    group=soak
    add_check "soak-$buffer" verdict FAIL "fail" "failures not explained by the machine: windows.unexplained $unexplained, $controls control overloads, exit $rc"
  fi
  # run_cmd wrote the line as group "soak"; the verdict decides how the summary shows it.
  awk -F'\t' -v OFS='\t' -v id="soak-$buffer" -v g="$group" '$2 == id { $1 = g } { print }' "$commands" >"$commands.tmp"
  mv "$commands.tmp" "$commands"
  [ "$group" = hands-on ]
}

# Turns the results into the job summary: one row per command, then every check.
phase_summary() {
  local table=$out/summary.md
  {
    echo "## Integration (macOS runner)"
    echo
    echo "$(sw_vers -productName) $(sw_vers -productVersion), $(uname -m). Driver: build/test-out/Duette.driver (with test devices)."
    echo
    echo "| Command | Result | Measured |"
    echo "|---|---|---|"
    if [ -f "$commands" ]; then
      while IFS=$'\t' read -r group id rc seconds headline; do
        local status measured=""
        if [ "$rc" = 0 ]; then
          status=PASS
        elif [ "$group" = hands-on ]; then
          status="needs hands-on"
        else
          status=FAIL
        fi
        if [ "$rc" = 124 ]; then status="$status (stuck: watchdog)"; fi
        local name
        for name in $headline; do
          local row
          row=$(awk -F'\t' -v id="$id" -v n="$name" '$1 == id && $2 == n { print $3 ": " $4 }' "$results" | tail -n 1)
          [ -n "$row" ] && measured="${measured:+$measured; }$name $row"
        done
        if [ "$rc" = 124 ]; then
          local stuck
          stuck=$(awk -F'\t' -v id="$id" '$1 == id && $2 == "watchdog" { print $5 }' "$results" | tail -n 1)
          measured="${measured:+$measured; }$stuck"
        fi
        echo "| $id | $status | ${measured:-see log} (${seconds} s) |"
      done <"$commands"
    fi
    echo
    echo "<details><summary>Every check</summary>"
    echo
    echo "| Command | Check | Status | Value | Detail |"
    echo "|---|---|---|---|---|"
    if [ -f "$results" ]; then
      awk -F'\t' '{ printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5 }' "$results"
    fi
    echo
    echo "</details>"
  } >"$table"
  cat "$table"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "$table" >>"$GITHUB_STEP_SUMMARY"
  fi

  echo "::group::coreaudiod: overloads and glitches"
  /usr/bin/log show --last 30m --predicate 'process == "coreaudiod" AND (eventMessage CONTAINS[c] "overload" OR eventMessage CONTAINS[c] "glitch")' \
    2>/dev/null | tail -n 60 || true
  echo "::endgroup::"
  echo "::group::driver log"
  /usr/bin/log show --last 30m --info --predicate 'subsystem == "me.roboroads.duette.driver"' 2>/dev/null | tail -n 400 || true
  echo "::endgroup::"
  echo "::group::uninstall"
  sudo bash scripts/uninstall.sh || true
  echo "::endgroup::"
}

phase=${1:-}
shift || true
case "$phase" in
  setup) phase_setup ;;
  blocking) phase_blocking ;;
  soak) phase_soak "$@" ;;
  summary) phase_summary ;;
  all)
    rc=0
    phase_setup
    phase_blocking || rc=1
    phase_summary
    exit "$rc"
    ;;
  *)
    sed -n '2,20p' "$0"
    exit 2
    ;;
esac
