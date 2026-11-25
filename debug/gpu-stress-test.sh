#!/bin/bash
# CX3566-Z GPU DVFS stress test (panfrost, kernel 6.1 flippy)
#
# Verifies the round-4 OPP table under sustained load:
#   Phase A: pin governor=performance, confirm 800 MHz + vdd_gpu 950 mV hold
#   Phase B: real rendering load (kmscube) + CPU co-stress, watch thermals
#   Verdict: PASS/FAIL summary; governor is always restored on exit.
#
# Usage:  sudo ./gpu-stress-test.sh [pin_seconds] [load_seconds]
# Defaults: 90s pin soak + 150s load. Log: /root/gpu-stress-<time>.log

DEVFREQ=/sys/class/devfreq/fde60000.gpu
PIN_SECS=${1:-90}
LOAD_SECS=${2:-150}
LOG=/root/gpu-stress-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1

say() { echo "[$(date +%H:%M:%S)] $*"; }

if [ "$(id -u)" != "0" ]; then say "FAIL: run as root"; exit 1; fi
if [ ! -d "$DEVFREQ" ]; then say "FAIL: no devfreq node at $DEVFREQ (panfrost not bound?)"; exit 1; fi

ORIG_GOV=$(cat "$DEVFREQ/governor")
restore() {
    echo "$ORIG_GOV" > "$DEVFREQ/governor" 2>/dev/null
    say "governor restored to $ORIG_GOV"
}
trap restore EXIT

gpu_regulator() {
    for r in /sys/class/regulator/regulator.*; do
        if [ "$(cat "$r/name" 2>/dev/null)" = "vdd_gpu" ]; then
            cat "$r/microvolts" 2>/dev/null
            return
        fi
    done
    echo "n/a"
}

max_temp() {
    local m=0 t
    for z in /sys/class/thermal/thermal_zone*; do
        t=$(cat "$z/temp" 2>/dev/null) || continue
        [ "$t" -gt "$m" ] && m=$t
    done
    echo $((m / 1000))
}

fault_count() {
    dmesg | grep -i panfrost | grep -icE "fault|timeout|error|hang"
}

FAULTS_BEFORE=$(fault_count)
MAX_TEMP_SEEN=0
MIN_FREQ_LOAD=999999999
FAIL=0

say "=== CX3566-Z GPU stress test ==="
say "governor=$ORIG_GOV  available=$(cat "$DEVFREQ/available_frequencies")"
say "idle: freq=$(cat "$DEVFREQ/cur_freq")  vdd_gpu=$(gpu_regulator) uV  temp=$(max_temp) C  faults_before=$FAULTS_BEFORE"

# ---------- Phase A: pinned at max ----------
say "--- Phase A: pin to performance for ${PIN_SECS}s ---"
echo performance > "$DEVFREQ/governor"
sleep 2
PIN_FREQ=$(cat "$DEVFREQ/cur_freq")
PIN_VOLT=$(gpu_regulator)
say "pinned: freq=$PIN_FREQ  vdd_gpu=$PIN_VOLT uV"
[ "$PIN_FREQ" = "800000000" ] || { say "FAIL: pinned freq is $PIN_FREQ, expected 800000000"; FAIL=1; }
if [ "$PIN_VOLT" != "n/a" ] && [ "$PIN_VOLT" != "950000" ]; then
    say "FAIL: vdd_gpu at 800 MHz is $PIN_VOLT uV, expected 950000"; FAIL=1
fi
END=$((SECONDS + PIN_SECS))
while [ $SECONDS -lt $END ]; do
    T=$(max_temp); [ "$T" -gt "$MAX_TEMP_SEEN" ] && MAX_TEMP_SEEN=$T
    F=$(cat "$DEVFREQ/cur_freq")
    if [ "$F" != "800000000" ]; then say "WARN: freq dropped to $F while pinned"; fi
    sleep 5
done
say "Phase A done: temp_max_so_far=${MAX_TEMP_SEEN} C"

# ---------- Phase B: rendering load + CPU co-stress ----------
say "--- Phase B: load for ${LOAD_SECS}s ---"
LOAD_DESC="pinned only (no renderer found)"
LOAD_PIDS=""
if command -v kmscube >/dev/null 2>&1; then
    timeout "$LOAD_SECS" kmscube -D /dev/dri/card0 > /tmp/kmscube.out 2>&1 &
    LOAD_PIDS="$!"
    LOAD_DESC="kmscube on /dev/dri/card0"
elif command -v glmark2-es2-drm >/dev/null 2>&1; then
    timeout "$LOAD_SECS" glmark2-es2-drm > /tmp/kmscube.out 2>&1 &
    LOAD_PIDS="$!"
    LOAD_DESC="glmark2-es2-drm"
else
    say "NOTE: kmscube not installed (apt install -y kmscube); running pinned soak + CPU stress only"
fi
say "load: $LOAD_DESC + 4x CPU burn"
for i in 1 2 3 4; do ( timeout "$LOAD_SECS" sh -c 'while :; do :; done' ) & LOAD_PIDS="$LOAD_PIDS $!"; done

END=$((SECONDS + LOAD_SECS))
while [ $SECONDS -lt $END ]; do
    T=$(max_temp); [ "$T" -gt "$MAX_TEMP_SEEN" ] && MAX_TEMP_SEEN=$T
    F=$(cat "$DEVFREQ/cur_freq")
    [ "$F" -lt "$MIN_FREQ_LOAD" ] && MIN_FREQ_LOAD=$F
    if [ $((SECONDS % 30)) -lt 5 ]; then say "  load: freq=$F temp=$(max_temp) C"; fi
    sleep 5
done
# Wait only for our own load children. A bare `wait` also waits for the
# tee process substitution and deadlocks (found the hard way, 2026-11-25).
wait $LOAD_PIDS 2>/dev/null
if [ -s /tmp/kmscube.out ]; then
    say "renderer output (tail): $(tail -2 /tmp/kmscube.out | tr '\n' ' ')"
fi
say "Phase B done: freq_min_under_load=$MIN_FREQ_LOAD  temp_max=${MAX_TEMP_SEEN} C"

# ---------- Verdict ----------
FAULTS_AFTER=$(fault_count)
say "=== SUMMARY ==="
say "faults: before=$FAULTS_BEFORE after=$FAULTS_AFTER"
say "max temp seen: ${MAX_TEMP_SEEN} C"
[ "$FAULTS_AFTER" != "$FAULTS_BEFORE" ] && { say "FAIL: new panfrost fault/timeout lines appeared"; FAIL=1; }
[ "$MAX_TEMP_SEEN" -ge 85 ] && { say "FAIL: temperature reached ${MAX_TEMP_SEEN} C (>= 85)"; FAIL=1; }
[ "$MAX_TEMP_SEEN" -ge 80 ] && say "WARN: temperature peaked at ${MAX_TEMP_SEEN} C (80-84)"
if [ $FAIL = 0 ]; then
    say "RESULT: PASS - 800 MHz @ 950 mV held under load, no faults, thermals OK"
else
    say "RESULT: FAIL - see lines above; fallback is the .bak-r3 DTB (fixed 594 MHz)"
fi
say "full log: $LOG"
