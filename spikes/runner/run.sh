#!/bin/bash
# Throwaway spike: what does a GitHub macos-15 arm64 runner allow for Core Audio tests?
# Uses BlackHole 2ch (binary from brew) as a stand-in HAL plug-in. Not product code.
# Writes a findings table to $GITHUB_STEP_SUMMARY. Bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${RUNNER_TEMP:-/tmp}/duette-spike"
rm -rf "$WORK"
mkdir -p "$WORK"
BIN="$WORK/duette-spike-probe"
ROWS="$WORK/rows.md"
: > "$ROWS"
SUMMARY="${GITHUB_STEP_SUMMARY:-$WORK/summary.md}"
HAL=/Library/Audio/Plug-Ins/HAL
UDB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
SDB="/Library/Application Support/com.apple.TCC/TCC.db"
TONE="$WORK/tone440.wav"
TONE_PID=""

row() {
  local q r e
  q=$(printf '%s' "$1" | tr '|\n' '/ ')
  r=$(printf '%s' "$2" | tr '|\n' '/ ')
  e=$(printf '%s' "$3" | tr '|\n' '/ ')
  printf '| %s | %s | %s |\n' "$q" "$r" "$e" >> "$ROWS"
  printf 'ROW: %s => %s (%s)\n' "$q" "$r" "$e"
}
kv() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

finish() {
  stop_tone
  {
    echo "## macOS runner capability spike"
    echo
    echo "Throwaway spike for S3. BlackHole 2ch from brew stands in for our HAL plug-in."
    echo
    echo "| Question | Result | Evidence |"
    echo "|---|---|---|"
    cat "$ROWS"
  } >> "$SUMMARY"
}
trap finish EXIT

with_timeout() {
  local secs=$1
  shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
  local watcher=$!
  wait "$pid"
  local rc=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return $rc
}

# Runs the probe; leaves its RESULT line in LAST and its output file in PROBE_OUT.
probe() {
  PROBE_OUT="$WORK/probe-$1-$RANDOM.txt"
  PROBE_TIMEOUT="${PROBE_TIMEOUT:-25}" "$BIN" "$@" > "$PROBE_OUT" 2>&1
  PRC=$?
  cat "$PROBE_OUT"
  LAST=$(grep '^RESULT' "$PROBE_OUT" | tail -n1)
  [ -n "$LAST" ] || LAST="RESULT status=no-result rc=$PRC"
}

start_tone() {
  afplay "$TONE" >> "$WORK/afplay.log" 2>&1 &
  TONE_PID=$!
  sleep 1.5
  if kill -0 "$TONE_PID" 2>/dev/null; then TONE_OK=yes; else TONE_OK=no; echo "afplay exited early"; fi
}
stop_tone() {
  if [ -n "$TONE_PID" ]; then
    kill "$TONE_PID" 2>/dev/null
    wait "$TONE_PID" 2>/dev/null
    TONE_PID=""
  fi
}

# ---------------------------------------------------------------- environment
group "environment"
sw_vers
uname -a
id
SIP_RAW=$(csrutil status 2>&1 | tr '\n' ' ')
echo "$SIP_RAW"
xcode-select -p
xcrun swiftc --version 2>&1
SDK=$(xcrun --show-sdk-version 2>/dev/null)
echo "SDK $SDK"
endgroup
row "macOS, arch, SDK" "$(sw_vers -productVersion) $(uname -m)" "SDK $SDK; $(xcrun swiftc --version 2>&1 | head -n1)"
case "$SIP_RAW" in
  *"status: disabled"*) SIP=disabled ;;
  *"status: enabled"*) SIP=enabled ;;
  *) SIP=other ;;
esac
row "SIP state" "$SIP" "csrutil: $SIP_RAW"

group "process ancestry"
ANCESTORS=""
p=$$
while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
  c=$(ps -o comm= -p "$p" 2>/dev/null)
  echo "$p $c"
  ANCESTORS="$ANCESTORS$c
"
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
done
endgroup

# ---------------------------------------------------------------- build probe
group "build probe"
xcrun swiftc -O -target arm64-apple-macosx14.2 -o "$BIN" "$HERE"/*.swift 2>&1
BUILD_RC=$?
codesign -dv "$BIN" 2>&1 | head -n5
endgroup
if [ "$BUILD_RC" -ne 0 ]; then
  row "Probe builds" "no" "swiftc rc=$BUILD_RC; see the build group in the log"
  exit 1
fi
row "Aggregate and tap key names on this SDK" "yes" "probe compiles using kAudioAggregateDeviceMainSubDeviceKey, TapListKey, TapAutoStartKey, kAudioSubTapUIDKey, kAudioSubTapDriftCompensationKey, CATapDescription"

group "responsible process"
probe whoami
RESP_PATH=$(sed -n 's/^RESPONSIBLE_PATH=//p' "$PROBE_OUT" | head -n1)
endgroup
row "TCC responsible process for a CLI in a step" "$RESP_PATH" "$LAST"

# ---------------------------------------------------------------- TCC
group "TCC databases"
for db in "$UDB" "$SDB"; do
  echo "== $db"
  sudo ls -l "$db"
  sudo sqlite3 "$db" ".schema access"
  sudo sqlite3 "$db" "SELECT service, client, client_type, auth_value, auth_reason FROM access WHERE service IN ('kTCCServiceMicrophone','kTCCServiceAudioCapture','kTCCServiceScreenCapture','kTCCServiceSystemPolicyAllFiles') ORDER BY service;"
done
endgroup
PRE_U=$(sudo sqlite3 "$UDB" "SELECT service || '=' || client || '(' || auth_value || ')' FROM access WHERE service IN ('kTCCServiceMicrophone','kTCCServiceAudioCapture');" 2>&1 | tr '\n' ' ')
PRE_S=$(sudo sqlite3 "$SDB" "SELECT service || '=' || client || '(' || auth_value || ')' FROM access WHERE service IN ('kTCCServiceMicrophone','kTCCServiceAudioCapture');" 2>&1 | tr '\n' ' ')
row "Image's existing mic/audio-capture grants" "see evidence" "user: ${PRE_U:-none}; system: ${PRE_S:-none}"

tcc_write_test() { # db sudo(yes/no)
  local s=""
  [ "$2" = yes ] && s="sudo"
  if $s sqlite3 "$1" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version) VALUES ('kTCCServiceDuetteSpikeWriteTest','/duette/spike',1,0,4,1); DELETE FROM access WHERE service='kTCCServiceDuetteSpikeWriteTest';" 2> "$WORK/tccw.err"; then
    echo yes
  else
    echo "no: $(head -c 160 "$WORK/tccw.err" | tr '\n' ' ')"
  fi
}
row "User TCC.db writable without sudo" "$(tcc_write_test "$UDB" no)" "sqlite3 insert+delete on $UDB"
row "User TCC.db writable with sudo" "$(tcc_write_test "$UDB" yes)" "sudo sqlite3 insert+delete"
row "System TCC.db writable with sudo" "$(tcc_write_test "$SDB" yes)" "sudo sqlite3 insert+delete on $SDB"

# ---------------------------------------------------------------- baseline devices
group "baseline audio devices"
system_profiler SPAudioDataType 2>&1 | head -n 40
probe list
BASE_LIST=$LAST
endgroup
row "Audio devices present by default" "$(kv "$BASE_LIST" devices)" "names: $(kv "$BASE_LIST" names); plug-ins: $(kv "$BASE_LIST" plugins)"

group "tone file and baseline afplay"
python3 - "$TONE" <<'EOF'
import math, struct, sys, wave
rate, secs = 48000, 30
w = wave.open(sys.argv[1], "wb")
w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
buf = bytearray()
for i in range(rate * secs):
    v = int(0.5 * 32767 * math.sin(2 * math.pi * 440 * i / rate))
    buf += struct.pack("<hh", v, v)
w.writeframes(bytes(buf)); w.close()
EOF
ls -l "$TONE"
start_tone
BASE_AFPLAY=$TONE_OK
stop_tone
cat "$WORK/afplay.log" 2>/dev/null
endgroup
row "afplay runs before any plug-in is installed" "$BASE_AFPLAY" "afplay still running after 1.5 s: $BASE_AFPLAY"

# ---------------------------------------------------------------- HAL plug-in
group "fetch BlackHole 2ch from brew (binary, test stand-in only)"
with_timeout 300 brew fetch --cask blackhole-2ch
PKG=$(brew --cache --cask blackhole-2ch 2>/dev/null)
ls -l "$PKG"
pkgutil --expand-full "$PKG" "$WORK/bhpkg"
DRV=$(find "$WORK/bhpkg" -type d -name '*.driver' | head -n1)
echo "driver: $DRV"
codesign -dv --verbose=2 "$DRV" 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier|flags'
endgroup
if [ -z "$DRV" ]; then
  row "HAL plug-in loads after sudo killall coreaudiod" "not tested" "could not get BlackHole2ch.driver from the brew cask pkg"
  exit 1
fi
DRV_NAME=$(basename "$DRV")

install_driver() { # source bundle
  sudo rm -rf "$HAL/$DRV_NAME"
  sudo mkdir -p "$HAL"
  sudo cp -R "$1" "$HAL/"
  sudo chown -R root:wheel "$HAL/$DRV_NAME"
}

group "install plug-in by copy, then killall coreaudiod"
install_driver "$DRV"
probe list
PRE_KILL=$(kv "$LAST" names)
sudo killall coreaudiod
KILL_RC=$?
sleep 3
probe list
POST_KILL=$(kv "$LAST" names)
POST_PLUGINS=$(kv "$LAST" plugins)
HOW="killall"
case "$POST_KILL" in
  *BlackHole*) LOADED=yes ;;
  *)
    LOADED=no
    sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
    sleep 3
    probe list
    case "$(kv "$LAST" names)" in *BlackHole*) LOADED="only after launchctl kickstart" ;; esac
    ;;
esac
endgroup
row "HAL plug-in loads after sudo killall coreaudiod" "$LOADED" "Developer ID signed BlackHole copied to $HAL; before restart: $PRE_KILL; after killall (rc=$KILL_RC): $POST_KILL; plug-ins: $POST_PLUGINS"

group "make BlackHole the default devices"
probe set-default BlackHole
probe list
endgroup

# ---------------------------------------------------------------- recording and taps per TCC stage
run_stage() { # label
  local label=$1
  group "stage: $label"
  start_tone
  probe record BlackHole 3
  REC=$LAST
  stop_tone
  start_tone
  probe tap "$TONE_PID" 3 nosub
  TAPN=$LAST
  stop_tone
  start_tone
  probe tap "$TONE_PID" 3
  TAPS=$LAST
  stop_tone
  endgroup
  row "CLI records BlackHole input while afplay plays into it ($label)" "$(kv "$REC" nonzero)" "start=$(kv "$REC" start) callbacks=$(kv "$REC" callbacks) peaks=$(kv "$REC" peaks) halSelf=$(kv "$REC" halSelf) status=$(kv "$REC" status)"
  row "Process tap on afplay (unmuted), tap-only private aggregate ($label)" "$(kv "$TAPN" nonzero)" "tap=$(kv "$TAPN" tap) agg=$(kv "$TAPN" agg) start=$(kv "$TAPN" start) aggIn=$(kv "$TAPN" aggIn) callbacks=$(kv "$TAPN" callbacks) peaks=$(kv "$TAPN" peaks) status=$(kv "$TAPN" status)"
  row "Process tap on afplay (unmuted), aggregate with BlackHole as main subdevice ($label)" "$(kv "$TAPS" nonzero)" "tap=$(kv "$TAPS" tap) agg=$(kv "$TAPS" agg) start=$(kv "$TAPS" start) aggIn=$(kv "$TAPS" aggIn) callbacks=$(kv "$TAPS" callbacks) peaks=$(kv "$TAPS" peaks) status=$(kv "$TAPS" status)"
  eval "REC_$2=\$REC; TAPN_$2=\$TAPN; TAPS_$2=\$TAPS"
}

CLIENTS=$( { echo "$BIN"; echo "$RESP_PATH"; printf '%s' "$ANCESTORS"; } | grep '^/' | sort -u)
echo "TCC clients to grant:"
echo "$CLIENTS"

tcc_grant() { # db
  local svc c
  for svc in kTCCServiceMicrophone kTCCServiceAudioCapture; do
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      sudo sqlite3 "$1" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags) VALUES ('$svc', '$c', 1, 2, 4, 1, 0);" \
        || echo "insert failed: $1 $svc $c"
    done <<EOF
$CLIENTS
EOF
  done
  sudo killall tccd 2>/dev/null
  killall tccd 2>/dev/null
  sleep 1
}

run_stage "image defaults, no inserts" 0
tcc_grant "$UDB"
run_stage "after user TCC.db inserts" 1
tcc_grant "$SDB"
run_stage "after user and system TCC.db inserts" 2

group "extra tap variants (after all inserts)"
start_tone
probe tap "$TONE_PID" 3 muted
TAPM=$LAST
stop_tone
start_tone
probe tap global 3 nosub
TAPG=$LAST
stop_tone
endgroup
row "Muted tap + BlackHole subdevice: which input buffer is the tap" "peaks=$(kv "$TAPM" peaks)" "muted tap keeps afplay out of BlackHole, so only the tap buffer should be non-zero; aggIn=$(kv "$TAPM" aggIn) start=$(kv "$TAPM" start) status=$(kv "$TAPM" status)"
row "Global stereo tap, tap-only aggregate" "$(kv "$TAPG" nonzero)" "tap=$(kv "$TAPG" tap) agg=$(kv "$TAPG" agg) start=$(kv "$TAPG" start) peaks=$(kv "$TAPG" peaks) status=$(kv "$TAPG" status)"

# What TCC denial looks like: stage 0 against the first stage that delivered audio.
DENY="no denial seen"
if [ "$(kv "$TAPN_0" nonzero)" != yes ]; then
  DENY="stage 0 tap: tap=$(kv "$TAPN_0" tap) agg=$(kv "$TAPN_0" agg) start=$(kv "$TAPN_0" start) callbacks=$(kv "$TAPN_0" callbacks) nonzero=$(kv "$TAPN_0" nonzero) status=$(kv "$TAPN_0" status)"
fi
row "What tap TCC denial looks like (error or silence)" "see evidence" "$DENY"
DENYM="no denial seen"
if [ "$(kv "$REC_0" nonzero)" != yes ]; then
  DENYM="stage 0 record: start=$(kv "$REC_0" start) callbacks=$(kv "$REC_0" callbacks) nonzero=$(kv "$REC_0" nonzero) status=$(kv "$REC_0" status)"
fi
row "What mic TCC denial looks like (error or silence)" "see evidence" "$DENYM"

# ---------------------------------------------------------------- ad-hoc signed plug-in
group "ad-hoc signed copy of the plug-in"
ADHOC="$WORK/adhoc/$DRV_NAME"
mkdir -p "$WORK/adhoc"
cp -R "$DRV" "$ADHOC"
codesign --force --deep --sign - "$ADHOC" 2>&1
codesign -dv --verbose=2 "$ADHOC" 2>&1 | grep -E 'Identifier|Authority|Signature|flags'
install_driver "$ADHOC"
sudo killall coreaudiod
sleep 3
probe list
ADHOC_NAMES=$(kv "$LAST" names)
endgroup
case "$ADHOC_NAMES" in *BlackHole*) ADHOC_OK=yes ;; *) ADHOC_OK=no ;; esac
row "Ad-hoc signed HAL plug-in loads after killall" "$ADHOC_OK" "devices after restart: $ADHOC_NAMES"

# ---------------------------------------------------------------- logs
group "TCC log excerpt"
with_timeout 120 log show --last 15m --style compact --predicate 'subsystem == "com.apple.TCC" AND (eventMessage CONTAINS[c] "Microphone" OR eventMessage CONTAINS[c] "AudioCapture" OR eventMessage CONTAINS "AUTHREQ")' 2>&1 | tail -n 120
endgroup
group "coreaudiod plug-in log excerpt"
with_timeout 120 log show --last 15m --style compact --predicate '(process == "coreaudiod" OR process CONTAINS "Core Audio Driver") AND (eventMessage CONTAINS[c] "BlackHole" OR eventMessage CONTAINS[c] "plug" OR eventMessage CONTAINS[c] "code sign")' 2>&1 | tail -n 80
endgroup

row "Hidden device (kAudioDevicePropertyIsHidden) as aggregate main subdevice" "open" "needs our own plug-in; BlackHole cannot be hidden"
row "AudioServerPlugInClientInfo.mProcessID equals the CLI's real PID" "open (indirect: see halSelf)" "needs our own plug-in; halSelf in the record rows shows whether coreaudiod lists the recording CLI under its real PID"
exit 0
