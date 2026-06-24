#!/bin/sh
# On-demand analytics digest → ntfy "monitor" category (→ #monitoring + phone).
# Computes today's CPU/RAM/player stats from bedrock-data/monitoring/health.csv and
# draws a Unicode sparkline "graph" of each over time — no chart library, one awk pass.
#   Run:  just digest-now    (also fires automatically at UTC-midnight from the monitor)
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"; cd "$DIR" || exit 1
NOTIFY_TITLE="${NOTIFY_TITLE:-Minecraft (bedrock)}"
. "$DIR/scripts/notify-lib.sh" 2>/dev/null || true

HE="bedrock-data/monitoring/health.csv"
EV="bedrock-data/monitoring/events.csv"
DAY="$(date -u +%Y-%m-%d)"
# Include rotated logs (health.csv.1, health.csv.2, …) written by the monitor's
# docker-style rotation. List health files oldest→newest so the sparkline and the
# "now" reading stay chronological; counts below don't care about order.
he_files=""; i=99; while [ "$i" -ge 1 ]; do [ -f "$HE.$i" ] && he_files="$he_files $HE.$i"; i=$((i-1)); done
[ -f "$HE" ] && he_files="$he_files $HE"
[ -n "$he_files" ] || he_files=/dev/null
joins=$(cat "$EV" "$EV".* 2>/dev/null | grep -c ',connected,')
leaves=$(cat "$EV" "$EV".* 2>/dev/null | grep -c ',disconnected,')
crashes=$(docker logs bedrock 2>&1 | grep -c 'free(): invalid next size')

MSG=$(awk -F, -v day="$DAY" -v joins="${joins:-0}" -v leaves="${leaves:-0}" -v crashes="${crashes:-0}" '
function tomib(s,  v){ v=s+0; if(s ~ /[Gg]i?B/) return v*1024; if(s ~ /[Kk]i?B/) return v/1024; return v }
function spark(arr,n,  i,mn,mx,s,lvl,K,idx){
  if(n<1) return "(no data)"; mn=arr[1]; mx=arr[1];
  for(i=1;i<=n;i++){ if(arr[i]<mn)mn=arr[i]; if(arr[i]>mx)mx=arr[i] }
  K=(n<24?n:24); s="";
  for(i=0;i<K;i++){ idx=(n<=K? i+1 : int(i*(n-1)/(K-1))+1);
    lvl=(mx>mn)? int((arr[idx]-mn)/(mx-mn)*7+0.5) : 0;
    if(lvl<0)lvl=0; if(lvl>7)lvl=7; s=s blk[lvl] }
  return s }
BEGIN{ blk[0]="▁";blk[1]="▂";blk[2]="▃";blk[3]="▄";blk[4]="▅";blk[5]="▆";blk[6]="▇";blk[7]="█" }
FNR==1 { next }
index($1,day)==1 {
  n++; cpu[n]=$3+0; mem[n]=tomib($4); p=$2+0;
  csum+=cpu[n]; if(cpu[n]>cmax)cmax=cpu[n];
  msum+=mem[n]; if(mem[n]>mmax)mmax=mem[n];
  if(p>pmax)pmax=p; lp=p; lc=cpu[n]; lm=mem[n] }
END{
  if(n<1){ printf "📊 digest %s — no samples yet today (monitor running? `just monitor-up`)", day; exit }
  printf "📊 daily digest — %s  (%d samples)\n", day, n;
  printf "👥 players: now %d · peak %d · %d joins / %d leaves\n", lp, pmax, joins, leaves;
  printf "🔥 CPU: now %d%% · avg %d%% · max %d%%\n   %s\n", lc, csum/n, cmax, spark(cpu,n);
  printf "🧠 RAM: now %.1fG · avg %.1fG · max %.1fG\n   %s\n", lm/1024, (msum/n)/1024, mmax/1024, spark(mem,n);
  printf "💥 crashes since boot: %d", crashes }' $he_files)

publish_bus "$MSG" default "monitor,bar_chart"
