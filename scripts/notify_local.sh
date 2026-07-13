#!/usr/bin/env bash
# 本机每期开奖后推 Telegram 提醒，并把看板数据 push 到 GitHub（GH Actions 已停用）。
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
GIT=/usr/bin/git                          # 同上，cron 里用绝对 git
export PYTHONPATH="$REPO_DIR/src"          # 直接用仓库源码，零依赖 stdlib

# 看板数据推送用的 cron 独占 worktree（在仓库之外，避免污染主工作区）。
WT_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ssq-checker-pages"
WT_BRANCH=ssq-pages-auto

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

# 把某工作区的公共 git 目录解析为规范绝对路径（校验 worktree 归属用）。
_abs_common() {
  local d p
  d="$1"
  p="$("$GIT" -C "$d" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$p" ] || return 1
  case "$p" in
    /*) ;;
    *)  p="$d/$p" ;;
  esac
  realpath -m "$p" 2>/dev/null || printf '%s\n' "$p"
}

# 把某工作区的顶层目录解析为规范绝对路径（防 symlink 指到主树）。
_abs_top() {
  local d p
  d="$1"
  p="$("$GIT" -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$p" ] || return 1
  realpath -m "$p" 2>/dev/null || printf '%s\n' "$p"
}

# 提醒推送后：刷新看板数据并推到 GitHub（Pages 从 master:/docs 直接托管，无 CI）。
#
# 全部在一个 cron 独占的 linked worktree（$WT_DIR，仓库之外）里做，分支 $WT_BRANCH：
# 从结构上杜绝与用户交互式工作区（HEAD/index/WIP）的任何 TOCTOU 竞争——我们永不碰
# 用户的 /home/logan/Projects/ssq-checker 工作树、暂存区或当前分支；连生成看板数据用的
# 源码和 bets.csv 也取自 worktree（已提交态），不受主工作区未提交改动影响。
#
# 关键设计——每轮都 hard-reset 到 origin/master 再就地重生成，**不保留“已提交但未推送
# 成功”的本地提交**。这对本数据集是安全且更简单的正确选择：
#   * 数据 append-only，且远端只由本 cron 推进；**已发布**（已 push 到 origin/master）的
#     记录都在 origin/master 里，reset 保留它们，sync_history 按 issue 去重从不重算 → 冻结
#     语义不破；
#   * 上次 push 失败时，其数据**尚未发布**，下一轮以（可能已前进的）origin/master 为基、
#     从同一数据源就地重生成并重推——即“重试”，只是靠重生成而非保留提交；
#   * 由此彻底消除分叉/需从分支 ref 重建 worktree/锁死登记等一整类边角问题。
#
# 全 best-effort：任何一步失败都只记日志、返回 0，不影响提醒退出码。
sync_and_push() {
  local main_common main_top wt_common wt_top wt_expect ahead

  # 符号链接护栏（无条件、最先判定）：$WT_DIR 末段若是 symlink，可能别名到别处（含本仓库
  # 另一个 worktree、或悬空/指向非目录），realpath 归一化会掩盖它。必须在任何 realpath /
  # worktree 操作之前止步，绝不在其上做 unlock/prune/add/checkout/reset/clean。
  if [ -L "$WT_DIR" ]; then
    log "worktree 路径是符号链接（$WT_DIR），跳过看板同步/推送（请手动清理）"; return 0
  fi

  # 主仓库基准（规范绝对路径），作为 worktree 归属校验基准。
  main_common="$(_abs_common "$REPO_DIR")"
  main_top="$(_abs_top "$REPO_DIR")"
  wt_expect="$(realpath -m "$WT_DIR" 2>/dev/null || printf '%s\n' "$WT_DIR")"
  if [ -z "$main_common" ] || [ -z "$main_top" ]; then
    log "无法解析主仓库 git 目录，跳过看板同步/推送"; return 0
  fi

  # $WT_DIR 是否为**本仓库注册**的 linked worktree（规范路径精确匹配 worktree list）。
  # 这是“可安全销毁”的正面证据：只有它为真，我们才会用 git 托管方式移除该目录；
  # 任何不在登记表里的目录（陌生仓库/普通目录）一律不碰、更不 rm -rf，避免误删用户数据。
  local is_reg=no _wl _p
  _wl="$("$GIT" -C "$REPO_DIR" worktree list --porcelain 2>/dev/null \
          | awk '/^worktree /{print substr($0,10)}')"
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    [ "$(realpath -m "$_p" 2>/dev/null)" = "$wt_expect" ] && { is_reg=yes; break; }
  done <<EOF
$_wl
EOF

  if [ -d "$WT_DIR" ]; then
    if [ "$is_reg" != yes ]; then
      # 目录存在但不是本仓库注册的 worktree → 陌生占用，绝不销毁；止步等人工处理。
      log "worktree 路径被非本仓库内容占用（$WT_DIR），跳过看板同步/推送（请手动清理）"; return 0
    fi
    # 已注册：再核归属（公共 git 目录一致、顶层恰为 $WT_DIR、且不等于主工作区）。
    wt_common="$(_abs_common "$WT_DIR")"
    wt_top="$(_abs_top "$WT_DIR")"
    if [ "$wt_common" != "$main_common" ] || [ "$wt_top" != "$wt_expect" ] || [ "$wt_top" = "$main_top" ]; then
      # 登记仍在但此刻路径上的内容与登记不符（例如原 worktree 消失后被别的东西占了同一路径）：
      # 绝不 remove/rm（可能误删陌生内容），仅记录并止步，等人工清理。
      log "已注册 worktree 状态异常（common=${wt_common:-无} top=${wt_top:-无}），跳过（请手动清理 $WT_DIR）"
      return 0
    fi
    # 通过全部校验 → 直接复用（后续 checkout -B/reset 会把分支与工作树对齐到 origin/master）。
  fi
  # 即便目录已消失，登记可能仍在（甚至被 lock）：先无条件 unlock 目标路径再 prune，
  # 使残留/锁定登记可被清除，避免 add 因残留锁定登记而永久失败。这是纯恢复性无操作，
  # 正常路径（未锁定/无登记）会报“not locked”——无诊断价值，静默丢弃以免刷屏日志。
  "$GIT" worktree unlock "$WT_DIR" >/dev/null 2>&1 || true
  "$GIT" worktree prune >>"$RUN_LOG" 2>&1 || true
  if [ ! -d "$WT_DIR" ]; then
    if ! "$GIT" worktree add -f -B "$WT_BRANCH" "$WT_DIR" origin/master >>"$RUN_LOG" 2>&1; then
      # 残留锁定登记需要二次 force；此路径已确认不被在用的陌生内容占用（上文已 return）。
      if ! "$GIT" worktree add -f -f -B "$WT_BRANCH" "$WT_DIR" origin/master >>"$RUN_LOG" 2>&1; then
        log "创建 worktree 失败，跳过看板同步/推送"; return 0
      fi
    fi
  fi

  # 拉取远端；失败用现有 origin/master 继续（push 阶段仍以 origin/master..HEAD 校验 ahead）。
  GIT_TERMINAL_PROMPT=0 timeout 60 "$GIT" -C "$WT_DIR" fetch -q origin master >>"$RUN_LOG" 2>&1 \
    || log "worktree fetch 失败（用现有 origin/master 继续）"

  # 硬对齐 origin/master（含把当前分支重置到远端）：worktree 是自动化独占的，
  # 已发布记录都在 origin/master，未发布的下轮重生成——见函数头“关键设计”。失败即止步。
  if ! "$GIT" -C "$WT_DIR" checkout -q -B "$WT_BRANCH" origin/master >>"$RUN_LOG" 2>&1; then
    log "worktree 对齐 origin/master 失败，跳过看板同步/推送"; return 0
  fi
  if ! "$GIT" -C "$WT_DIR" reset -q --hard origin/master >>"$RUN_LOG" 2>&1; then
    log "worktree reset 失败，跳过看板同步/推送"; return 0
  fi
  if ! "$GIT" -C "$WT_DIR" clean -qfdx -- docs/data >>"$RUN_LOG" 2>&1; then
    log "worktree 清理 docs/data 失败，跳过看板同步/推送"; return 0
  fi

  # 用 worktree 自己的源码与 bets.csv 生成看板数据：彻底隔离主工作区的未提交改动。
  # 内联 PYTHONPATH 覆盖顶部导出的主仓库 src；--bets/--data-dir 用 worktree 内绝对路径。
  if ! PYTHONPATH="$WT_DIR/src" "$PY" -m ssq_checker --sync-history \
        --data-dir "$WT_DIR/docs/data" --bets "$WT_DIR/bets.csv" >>"$RUN_LOG" 2>&1; then
    log "同步看板数据失败"; return 0
  fi

  # worktree 已 reset 干净，此刻 docs/data 的任何 diff 都只来自本次 sync；只提交它。
  if [ -n "$("$GIT" -C "$WT_DIR" status --porcelain -- docs/data 2>/dev/null)" ]; then
    "$GIT" -C "$WT_DIR" add -- docs/data >>"$RUN_LOG" 2>&1
    "$GIT" -C "$WT_DIR" commit -q -m "chore: update lottery history & stats [skip ci]" -- docs/data >>"$RUN_LOG" 2>&1 \
      || { log "提交 docs/data 失败"; return 0; }
  fi

  # push：worktree 领先 origin/master 才推。上次 push 失败 → 本轮 reset 后重生成 → 再次领先 → 重推。
  ahead="$("$GIT" -C "$WT_DIR" rev-list --count origin/master..HEAD 2>/dev/null || echo 0)"
  if [ "${ahead:-0}" -gt 0 ]; then
    if GIT_TERMINAL_PROMPT=0 timeout 60 "$GIT" -C "$WT_DIR" push -q origin "HEAD:master" >>"$RUN_LOG" 2>&1; then
      log "看板数据已推送到 GitHub（$ahead 个提交）"
    else
      log "git push 失败（下次以 origin/master 为基重生成并重推）"
    fi
  fi
}

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
  0) sync_and_push ;;                                # 正常（推了或跳过）→ 刷新看板并 push
  2) log "拉取开奖数据失败（rc=2），稍后重试" ;;
  3) log "Telegram 投递失败（rc=3），不写回执，下个 cron 重推" ;;
  5) log "读回执失败（rc=5），未推送，检查 $STATE_FILE" ;;
  *) log "未预期错误 rc=$rc" ;;
esac
exit "$rc"
