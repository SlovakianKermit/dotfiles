#!/bin/bash
# netmon.sh - one WAN/mesh health sample. Runs via systemd --user timer every 5 min.
# Columns (TSV): ts gw_loss gw_avg gw_max cf_loss cf_avg cf_max q9_loss q9_avg q9_max spdA_mbps spdB_mbps agg_mbps
LOG="$HOME/.cache/netmon.log"
mkdir -p "$(dirname "$LOG")"
TS=$(date '+%F %T')

ping_stats() {
    local o avg max loss
    o=$(ping -c4 -i0.3 -W1 "$1" 2>/dev/null)
    loss=$(echo "$o" | grep -oP '\d+(\.\d+)?(?=% packet loss)' | head -1)
    [ -z "$loss" ] && loss=100
    line=$(echo "$o" | grep -oP '= \K[0-9.]+/[0-9.]+/[0-9.]+' | head -1)
    if [ -z "$line" ]; then
        echo "100 -1 -1"
    else
        avg=$(echo "$line" | cut -d/ -f2)
        max=$(echo "$line" | cut -d/ -f3)
        echo "$loss $avg $max"
    fi
}

GW=$(ping_stats 192.168.0.1)
CF=$(ping_stats 1.1.1.1)
Q9=$(ping_stats 9.9.9.9)

A='https://ftp.halifax.rwth-aachen.de/archlinux/iso/latest/archlinux-x86_64.iso'
B='https://mirror.netcologne.de/archlinux/iso/latest/archlinux-x86_64.iso'
( curl -4 -so /dev/null -m 8 -w '%{speed_download}' "$A" > /tmp/netmon_a.tmp 2>/dev/null ) &
( curl -4 -so /dev/null -m 8 -w '%{speed_download}' "$B" > /tmp/netmon_b.tmp 2>/dev/null ) &
wait
SA=$(cat /tmp/netmon_a.tmp 2>/dev/null); SB=$(cat /tmp/netmon_b.tmp 2>/dev/null)
SA=${SA:-0}; SB=${SB:-0}
A_M=$(awk -v x="$SA" 'BEGIN{printf "%.0f", x*8/1e6}')
B_M=$(awk -v x="$SB" 'BEGIN{printf "%.0f", x*8/1e6}')
AGG=$(awk -v x="$SA" -v y="$SB" 'BEGIN{printf "%.0f", (x+y)*8/1e6}')

echo -e "$TS\t$(echo $GW | tr ' ' '\t')\t$(echo $CF | tr ' ' '\t')\t$(echo $Q9 | tr ' ' '\t')\t$A_M\t$B_M\t$AGG" >> "$LOG"
