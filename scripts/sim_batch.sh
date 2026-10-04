#!/usr/bin/env bash
# =============================================================================
# 模擬批次跑：同一組 seed 連跑 N 次，每次產出可比較的紀錄
# =============================================================================
# 用法：
#   scripts/sim_batch.sh                     # seed 1..20，輸出到 logs_sim_batch/batch_<date>
#   SEEDS="1 2 3" scripts/sim_batch.sh
#   OUTDIR=/path/to/dir scripts/sim_batch.sh
#
# 這支腳本刻意放在 repo 裡。前一輪（batch_20260918）的批次腳本與分析器寫在
# scratchpad，事後整個消失 —— 結果是 20 次跑的原始資料還在，卻沒有任何東西
# 能重現或延續那次量測。長跑批次的產物與產生它的程式都必須落在 host 的 repo 裡。
#
# 所有串流（status_json、pose_trace）都直接 pipe 到 host 檔案，不經過容器
# 的 /tmp —— 容器一 recreate 就沒了，而批次跑很長，中途掛掉時已經寫下的
# 部分必須留得住。
# -----------------------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SEEDS="${SEEDS:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20}"
OUTDIR="${OUTDIR:-$REPO/logs_sim_batch/batch_$(date +%Y%m%d_%H%M%S)}"

# 與 batch_20260918 的設定保持一致，否則跟 baseline 不可比。
ARENA="${ARENA:-finals}"
DRUM_STYLE="${DRUM_STYLE:-random}"
RECORD_IMAGES="${RECORD_IMAGES:-false}"
PERCEPTION="${PERCEPTION:-true}"
MISSION_TIMEOUT="${MISSION_TIMEOUT:-1000}"
ORCA_NS="${ORCA_NAMESPACE:-orca_auv}"
POSE_INTERVAL="${POSE_INTERVAL:-1.0}"   # baseline 是 ~2.8s；加密以便做幾何分析

COMPOSE_ARGS="-f docker-compose.yml -f docker-compose.x86.yml"
compose() { docker compose $COMPOSE_ARGS "$@"; }

mkdir -p "$OUTDIR"
BATCH_LOG="$OUTDIR/batch.log"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$BATCH_LOG"; }

# ── 環境快照 ────────────────────────────────────────────────────────────────
{
  echo "# 批次環境快照"
  echo "開始時間: $(date '+%F %T')"
  echo "seeds: $SEEDS"
  echo "arena=$ARENA drum_style=$DRUM_STYLE record_images=$RECORD_IMAGES" \
       "headless=true perception=$PERCEPTION"
  echo "mission_timeout=${MISSION_TIMEOUT}s pose_interval=${POSE_INTERVAL}s"
  echo
  echo "## git"
  git rev-parse HEAD
  git submodule status
  echo
  echo "## gpu"
  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv 2>/dev/null || echo "(no nvidia-smi)"
} > "$OUTDIR/environment.md"

# 容器內的 status echo。只 kill host 端的 `docker compose exec` 不會帶走它：
# 它會繼續寫進同一個 host 檔案（stdout 管線還開著），batch_flare5x_cam120 的
# run 1 就這樣累積到 34 MB／156k 行，各次 mission_time_s 被汙染成同一個值。
# make stop 也不會清它 —— STOP_AUTONOMY 只砍 `ros2 launch` 與 install 底下的
# 行程，`ros2 topic echo` 兩者都不是。
kill_status_echo() {
  compose exec -T autonomy bash -lc \
    "pkill -f '[r]os2 topic echo --field data /orca/decision/status_json'" \
    >/dev/null 2>&1 || true
}
stop_streams() {
  kill "$STATUS_PID" "$POSE_PID" 2>/dev/null || true
  wait "$STATUS_PID" "$POSE_PID" 2>/dev/null || true
  kill_status_echo
}
teardown() { kill_status_echo; make --no-print-directory stop >/dev/null 2>&1 || true; }
trap 'log "收到中斷訊號，收尾中"; teardown; exit 130' INT TERM

TOTAL=$(echo $SEEDS | wc -w)
IDX=0
for SEED in $SEEDS; do
  IDX=$((IDX + 1))
  RUN_DIR="$OUTDIR/$(printf 'run_%02d_seed_%s' "$IDX" "$SEED")"
  mkdir -p "$RUN_DIR"
  log "=== run $IDX/$TOTAL  SEED=$SEED  -> $RUN_DIR"

  teardown

  # ── 1. 起模擬 + control + autonomy ────────────────────────────────────────
  if ! make --no-print-directory sim_launch \
        HEADLESS=true ARENA="$ARENA" SEED="$SEED" DRUM_STYLE="$DRUM_STYLE" \
        RECORD_IMAGES="$RECORD_IMAGES" PERCEPTION="$PERCEPTION" \
        > "$RUN_DIR/make_sim.log" 2>&1; then
    log "  ✗ 堆疊啟動失敗（見 make_sim.log），跳過這個 seed"
    echo '{"error":"launch_failed"}' > "$RUN_DIR/launch_error.json"
    continue
  fi

  # ── 2. 開始串流記錄（直接落在 host）──────────────────────────────────────
  compose exec -T autonomy bash -lc \
    'source /opt/ros/humble/setup.bash 2>/dev/null; \
     source /workspaces/isaac_ros-dev/install/setup.bash 2>/dev/null; \
     ros2 topic echo --field data /orca/decision/status_json' \
    > "$RUN_DIR/status.jsonl" 2>"$RUN_DIR/status_echo.err" &
  STATUS_PID=$!

  (
    while :; do
      POSE=$(compose exec -T sim bash -lc \
               'source /opt/ros/humble/setup.bash 2>/dev/null; ign model -m orca_auv -p' \
             2>/dev/null | tr '\n' '|')
      [ -n "$POSE" ] && printf '%s %s\n' "$(date +%s.%N)" "$POSE"
      sleep "$POSE_INTERVAL"
    done
  ) > "$RUN_DIR/pose_trace.txt" 2>/dev/null &
  POSE_PID=$!

  # 給 DDS 探索一點時間收斂再解鎖；太早呼叫服務會收不到回應。
  sleep 15

  # ── 3. 解鎖：把 supervisor 切到 AUTONOMOUS_AND_DEPTH_HOLD ────────────────
  # 少了這一步，整個堆疊看起來完全正常 —— 容器都在、BT 在 tick、感知有鎖定、
  # status_json 照常發布 —— 但載具一動也不動：supervisor 預設擋掉決策層的
  # wrench（見 docs/SIMULATION_FINDINGS.md §2.1），力根本到不了推進器。
  # 唯一的徵兆是 pose_trace 裡的 x 從頭到尾等於出生點。
  # 剛啟動的堆疊 DDS 探索還沒收斂，此時的第一個 ros2 service call 常常**收不到
  # 回應** —— 伺服器端有執行（mode 讀回值會前進），但 CLI 一直等，於是用 && 串
  # 起來的第二個呼叫永遠不會執行，模式停在 DEPTH_HOLD。
  #
  # 所以這裡不信任服務的回傳值，一律以 mode topic 的讀回值為準，並重試到讀回
  # AUTONOMOUS_AND_DEPTH_HOLD 為止。呼叫之間用 ';' 而不是 '&&'：即使前一個被
  # timeout 砍掉，後一個仍要送出。每個呼叫各自有 timeout，單次卡住不會吃掉
  # 整個預算。
  ARMED=0
  for ATTEMPT in 1 2 3 4 5; do
    {
      echo "=== attempt $ATTEMPT ==="
      timeout 120 docker compose $COMPOSE_ARGS exec -T control bash -lc \
        "source /opt/ros/humble/setup.bash; source /root/rpi_ros2_ws/install/setup.bash; \
         timeout 25 ros2 service call /$ORCA_NS/system_manager/set_mode/depth_hold std_srvs/srv/Trigger; \
         timeout 25 ros2 service call /$ORCA_NS/system_manager/set_mode/autonomous std_srvs/srv/Trigger; \
         echo '--- mode readback ---'; \
         timeout 20 ros2 topic echo --once /$ORCA_NS/system_manager/mode" 2>&1
    } >> "$RUN_DIR/arm.log" 2>&1
    if grep -q 'AUTONOMOUS_AND_DEPTH_HOLD' "$RUN_DIR/arm.log"; then
      ARMED=1
      log "  已解鎖（第 $ATTEMPT 次嘗試）"
      break
    fi
    sleep 5
  done

  if [ "$ARMED" -ne 1 ]; then
    log "  ✗ 解鎖失敗（5 次重試後 mode 仍非 AUTONOMOUS_AND_DEPTH_HOLD），跳過這個 seed"
    stop_streams
    continue
  fi

  # ── 4. 發任務開始訊號 ─────────────────────────────────────────────────────
  # 跟解鎖同一類競態：`ros2 topic pub --once` 發完就退出，若此時 DDS 還沒探索
  # 到 decision_node 的訂閱，訊息直接掉在地上 —— 堆疊全部正常、status_json 照
  # 常發布，但 mission_started 永遠是 false，載具停在出生點直到逾時。所以改成
  # 連發數次，並以 status.jsonl 裡真的出現 mission_started:true 為準，重試到確認。
  STARTED=0
  for ATTEMPT in 1 2 3 4 5; do
    {
      echo "=== attempt $ATTEMPT ==="
      timeout 60 docker compose $COMPOSE_ARGS exec -T autonomy bash -lc \
        'source /opt/ros/humble/setup.bash 2>/dev/null; \
         source /workspaces/isaac_ros-dev/install/setup.bash 2>/dev/null; \
         ros2 topic pub -t 5 -r 2 /orca/decision/start_mission std_msgs/msg/Bool "{data: true}"' 2>&1
    } >> "$RUN_DIR/start_mission.log" 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if grep -q '"mission_started": *true' "$RUN_DIR/status.jsonl" 2>/dev/null; then
        STARTED=1; break
      fi
      sleep 1
    done
    [ "$STARTED" -eq 1 ] && break
  done

  if [ "$STARTED" -ne 1 ]; then
    log "  ✗ 任務啟動失敗（5 次重試後 mission_started 仍為 false），跳過這個 seed"
    stop_streams
    continue
  fi
  log "  任務已啟動（第 $ATTEMPT 次嘗試），等結束（上限 ${MISSION_TIMEOUT}s）"

  # ── 5. 等 mission_complete 或逾時 ────────────────────────────────────────
  T0=$(date +%s); OUTCOME="TIMEOUT"
  while :; do
    ELAPSED=$(( $(date +%s) - T0 ))
    if [ "$ELAPSED" -ge "$MISSION_TIMEOUT" ]; then break; fi
    if grep -q '"mission_complete": *true' "$RUN_DIR/status.jsonl" 2>/dev/null; then
      OUTCOME="COMPLETED"; break
    fi
    if ! kill -0 "$STATUS_PID" 2>/dev/null; then OUTCOME="STATUS_STREAM_DIED"; break; fi
    sleep 2
  done
  log "  結束：$OUTCOME（${ELAPSED}s）"

  # ── 6. 收尾：停串流、把容器內的 log 撈出來 ───────────────────────────────
  stop_streams

  for svc_log in "sim:/tmp/sim.log" "control:/tmp/control.log" "autonomy:/tmp/autonomy.log"; do
    SVC="${svc_log%%:*}"; PATH_IN="${svc_log##*:}"
    compose exec -T "$SVC" bash -lc "cat $PATH_IN" > "$RUN_DIR/$(basename "$PATH_IN")" 2>/dev/null || true
  done

  printf '{"seed":%s,"run":%d,"outcome":"%s","wall_s":%d}\n' \
    "$SEED" "$IDX" "$OUTCOME" "$ELAPSED" > "$RUN_DIR/timing.json"
done

teardown
log "批次結束，輸出在 $OUTDIR"
log "分析：scripts/sim_batch_analyze.py $OUTDIR"
