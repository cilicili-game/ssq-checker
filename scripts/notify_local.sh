#!/usr/bin/env bash
# 本机每期开奖后推 Telegram 提醒（替代已停用的 GitHub Actions；GitHub 账号被封）。
# 机器 TZ=Asia/Hong_Kong；双色球开奖日 周二/四/日 晚 ~21:15-21:30 出结果。
#
# 幂等由 CLI 保证：`--notify-new --state-file` 只拉取一次、期号比上次回执更新才推送，
# 推送成功后原子写回执。cron 在开奖日晚间每 15 分钟跑一次：
#   - 结果还没出 / 已推过这期 → 期号不更新 → 静默跳过；
#   - 新一期出现 → 推一条 → 记回执。同一期至多一条（进程在投递后、写回执前被杀的极端
#     情况下会重推一次，即 at-least-once，对提醒来说是安全方向）。
#
# 凭据从 repo 根的 .env 读取（gitignore, chmod 600）：白名单取键、去掉 CR、绝不 source。
set -uo pipefail
umask 077

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1

PY=/home/logan/miniforge3/bin/python      # cron PATH 精简，用绝对解释器
export PYTHONPATH="$REPO_DIR/src"          # 直接用仓库源码，零依赖 stdlib

LOG_DIR="$REPO_DIR/logs"
mkdir -p "$LOG_DIR" || exit 1
RUN_LOG="$LOG_DIR/notify.log"
STATE_FILE="$LOG_DIR/.last_issue"
log() { echo "[$(date '+%F %T %Z')] $*" >> "$RUN_LOG"; }

# 并发护栏：同一时刻只允许一个实例（多次 cron 交叠时不重复）。
if ! exec 9>"$LOG_DIR/.notify.lock"; then
  log "FATAL: 无法打开锁文件"
  exit 1
fi
# -E 75：仅“抢锁失败(有别的实例在跑)”才返回 75；其它错误(坏 fd / 不支持 / IO)
# 保留 flock 自己的非零码，绝不当成“已在运行”而静默成功。
flock -n -E 75 9
fl=$?
if [ "$fl" -eq 75 ]; then
  log "另一实例运行中，跳过"
  exit 0
elif [ "$fl" -ne 0 ]; then
  log "FATAL: flock 失败（rc=$fl）"
  exit 1
fi

# 白名单解析 .env：只取指定键、取最后一次定义、去掉行尾 CR；绝不当 shell 执行（防注入）。
envval() {
  [ -f "$REPO_DIR/.env" ] || return 0
  grep -E "^$1=" "$REPO_DIR/.env" | tail -1 | cut -d= -f2- | tr -d '\r'
}
export TELEGRAM_BOT_TOKEN="$(envval TELEGRAM_BOT_TOKEN)"
export TELEGRAM_CHAT_ID="$(envval TELEGRAM_CHAT_ID)"
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  log "FATAL: .env 缺少 TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID"
  exit 3
fi

# 单次拉取 + 幂等推送 + 原子写回执，全在一个 Python 进程内（内部再加进程锁）。
# 退出码：0=已推送或无新一期（正常）；2=拉取失败（下个 cron 再试）；
#         3=Telegram 投递失败；5=读回执失败（本地状态异常，未推送）。
"$PY" -m ssq_checker --telegram --notify-new --state-file "$STATE_FILE" >>"$RUN_LOG" 2>&1
rc=$?
case "$rc" in
  0) : ;;                                            # 正常（推了或跳过）
  2) log "拉取开奖数据失败（rc=2），稍后重试" ;;
  3) log "Telegram 投递失败（rc=3），不写回执，下个 cron 重推" ;;
  5) log "读回执失败（rc=5），未推送，检查 $STATE_FILE" ;;
  *) log "未预期错误 rc=$rc" ;;
esac
exit "$rc"
