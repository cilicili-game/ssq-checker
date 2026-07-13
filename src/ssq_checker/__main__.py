"""CLI entrypoint: python -m ssq_checker [--reds 01 02 ...] [--blue 07] [--bets bets.csv]"""
from __future__ import annotations

import argparse
import fcntl
import os
import sys
import tempfile

from .bets import load_bets
from .checker import (
    bet_winnings,
    check_prize,
    format_bets_report,
    format_report,
    normalize,
)
from .fetcher import fetch_all_draws, fetch_latest_draw
from .history import sync_history
from .notify import send_telegram
from .stats import write_stats

DEFAULT_REDS = ["01", "02", "03", "04", "08", "09"]
DEFAULT_BLUE = "07"
DEFAULT_BETS_PATH = "bets.csv"
DEFAULT_START_DATE = "2025-01-01"
DEFAULT_DATA_DIR = "docs/data"


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Check SSQ draw against your bet table or fixed numbers.")
    p.add_argument("--reds", nargs=6, default=None,
                   help="6 red balls (1-33) for a one-off check. Overrides the bet table.")
    p.add_argument("--blue", default=None,
                   help="1 blue ball (1-16) for a one-off check.")
    p.add_argument("--bets", default=None,
                   help=f"Path to the bet-table CSV. Default: {DEFAULT_BETS_PATH} "
                        "(used automatically if it exists and --reds is not given). "
                        "If explicitly set to a missing file the command errors out.")
    p.add_argument("--json", action="store_true", help="Output JSON instead of formatted report.")
    p.add_argument("--telegram", action="store_true",
                   help="Also send the report to Telegram. Reads TELEGRAM_BOT_TOKEN "
                        "and TELEGRAM_CHAT_ID from the environment.")
    p.add_argument("--notify-new", action="store_true",
                   help="Idempotent cron mode (with --telegram + --state-file): fetch "
                        "once, send only if the latest draw's issue is newer than the "
                        "one recorded in the state file, then record it atomically. "
                        "Repeated runs send at most one message per new draw.")
    p.add_argument("--state-file", default=None,
                   help="Issue-receipt file for --notify-new (stores the last notified issue).")
    p.add_argument("--sync-history", action="store_true",
                   help="Record any not-yet-stored draws into the month-partitioned "
                        "history (for the Pages dashboard). Past records are frozen.")
    p.add_argument("--start-date", default=DEFAULT_START_DATE,
                   help=f"First draw date to include in history. Default: {DEFAULT_START_DATE}.")
    p.add_argument("--data-dir", default=DEFAULT_DATA_DIR,
                   help=f"Directory holding the month history files. Default: {DEFAULT_DATA_DIR}.")
    args = p.parse_args(argv)
    args.bets_path = args.bets if args.bets is not None else DEFAULT_BETS_PATH

    # `--blue` only makes sense alongside `--reds` (the one-off path); without
    # `--reds` we can't tell whether the user wants the bet table or a defaulted
    # red set, so refuse rather than silently ignore the flag.
    if args.blue is not None and args.reds is None:
        p.error("--blue requires --reds")

    if args.notify_new and not (args.telegram and args.state_file):
        p.error("--notify-new requires --telegram and --state-file")

    if args.sync_history:
        return _sync_history(args)

    # Mode selection: explicit --reds forces a one-off single check. Otherwise
    # the bet table is used if present; an explicit --bets pointing at a missing
    # file is a hard error (don't silently fall back to defaults and report the
    # wrong numbers).
    if args.reds is not None:
        use_table = False
    elif args.bets is not None and not os.path.exists(args.bets_path):
        print(f"❌ 投注表不存在：{args.bets_path}", file=sys.stderr)
        return 4
    else:
        use_table = os.path.exists(args.bets_path)

    try:
        draw = fetch_latest_draw()
    except Exception as e:
        print(f"❌ 拉取双色球开奖数据失败：{e}", file=sys.stderr)
        return 2

    if use_table:
        try:
            bets = load_bets(args.bets_path)
        except (OSError, ValueError) as e:
            print(f"❌ 读取投注表失败（{args.bets_path}）：{e}", file=sys.stderr)
            return 4
        results = [(b, check_prize(b.reds, b.blue, draw)) for b in bets]
        report = format_bets_report(draw, results)
        payload = {
            "issue": draw.issue, "date": draw.date,
            "draw_reds": draw.reds_sorted, "draw_blue": draw.blue,
            "total_cost": sum(b.cost for b in bets),
            "bets": [
                {
                    "reds": b.reds, "blue": b.blue, "multiplier": b.multiplier,
                    "cost": b.cost, "red_hits": r.red_hits,
                    "red_matched": r.red_matched, "blue_hit": r.blue_hit,
                    "tier": r.tier, "winnings": bet_winnings(r, b.multiplier),
                }
                for b, r in results
            ],
        }
    else:
        user_reds = normalize(args.reds if args.reds is not None else DEFAULT_REDS)
        user_blue = f"{int(args.blue if args.blue is not None else DEFAULT_BLUE):02d}"
        result = check_prize(user_reds, user_blue, draw)
        report = format_report(draw, user_reds, user_blue, result)
        payload = {
            "issue": draw.issue, "date": draw.date,
            "draw_reds": draw.reds_sorted, "draw_blue": draw.blue,
            "user_reds": user_reds, "user_blue": user_blue,
            "red_hits": result.red_hits, "red_matched": result.red_matched,
            "blue_hit": result.blue_hit,
            "tier": result.tier, "amount": result.amount,
        }

    # Idempotent cron mode: hold an exclusive lock across the whole
    # read-receipt -> send -> write-receipt transaction so two concurrent
    # --notify-new runs can't both decide the draw is new and double-send.
    lock_fd = None
    if args.notify_new:
        try:
            lock_fd = _acquire_notify_lock(args.state_file)
        except OSError as e:
            print(f"❌ 获取通知锁失败：{e}", file=sys.stderr)
            return 5
        if lock_fd is None:
            # Another instance owns the transaction; it will handle this draw.
            return 0
    try:
        # This single fetch is the one we act on. Skip entirely (no output, no
        # send) unless this draw is strictly newer than what we recorded.
        if args.notify_new:
            try:
                last = _read_state(args.state_file)
            except OSError as e:
                # A real read error (perms, I/O, path-is-dir) must NOT be read as
                # "never notified" — that would resend. Abort before sending.
                print(f"❌ 读取回执失败：{e}", file=sys.stderr)
                return 5
            if last is not None and _issue_num(draw.issue) <= _issue_num(last):
                return 0

        if args.json:
            import json as _json
            print(_json.dumps(payload, ensure_ascii=False, indent=2))
        else:
            print(report)

        if args.telegram:
            token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
            chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")
            try:
                send_telegram(report, token, chat_id)
            except Exception as e:
                print(f"❌ Telegram 投递失败：{e}", file=sys.stderr)
                return 3
            # Record only after a confirmed send. If the receipt write fails, the
            # message was still delivered, so we don't fail the run — the next run
            # just resends (at-least-once, the safe direction for a reminder).
            if args.notify_new:
                try:
                    _write_state_atomic(args.state_file, draw.issue)
                except OSError as e:
                    print(f"⚠️ 已推送但写回执失败（下次会重推）：{e}", file=sys.stderr)

        return 0
    finally:
        if lock_fd is not None:
            os.close(lock_fd)


def _issue_num(issue: str | None) -> int:
    """Issues are `YYYYNNN` (e.g. 2026079); compare numerically. Unparseable
    state (corrupt/empty) sorts lowest so a real draw is always considered newer."""
    try:
        return int(issue)
    except (TypeError, ValueError):
        return -1


def _acquire_notify_lock(state_file: str) -> int | None:
    """Non-blocking exclusive lock on `<state-file>.lock`, guarding the whole
    read -> send -> write transaction against concurrent --notify-new runs.
    Returns an open fd (the caller must close it) or None if another instance
    already holds it — in which case that instance owns this draw."""
    d = os.path.dirname(state_file) or "."
    os.makedirs(d, exist_ok=True)
    fd = os.open(state_file + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        # EAGAIN/EWOULDBLOCK: another instance holds it -> real contention.
        os.close(fd)
        return None
    except OSError:
        # Any other lock error (EINTR, ENOTSUP, I/O) is NOT contention: don't
        # mask it as a silent skip, propagate so the run fails loudly.
        os.close(fd)
        raise
    return fd


def _read_state(path: str) -> str | None:
    """Return the recorded issue, or None if no receipt exists yet. Only a
    missing file counts as "never notified"; any other error (perms, I/O, a
    directory in the way) propagates so the caller can abort before sending
    rather than resend on a transient read failure."""
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip() or None
    except FileNotFoundError:
        return None


def _write_state_atomic(path: str, issue: str) -> None:
    """Write the receipt via a same-dir temp file + fsync + atomic rename, so an
    interrupted/failed write can never leave a truncated receipt and a committed
    receipt survives a crash."""
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".state-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(issue)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        dfd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _sync_history(args) -> int:
    try:
        bets = load_bets(args.bets_path)
    except (OSError, ValueError) as e:
        print(f"❌ 读取投注表失败（{args.bets_path}）：{e}", file=sys.stderr)
        return 4
    try:
        draws = fetch_all_draws()
    except Exception as e:
        print(f"❌ 拉取历史开奖数据失败：{e}", file=sys.stderr)
        return 2

    manifest = sync_history(args.data_dir, draws, bets, args.start_date)
    stats = write_stats(args.data_dir, draws)
    s = manifest["summary"]
    verdict = "盈利" if s["net"] > 0 else ("持平" if s["net"] == 0 else "亏损")
    print(f"✅ 历史已同步到 {args.data_dir}（新增{manifest['added']}期，共{s['draws']}期）："
          f"投入¥{s['total_cost']}，中奖¥{s['total_won']}，"
          f"净{verdict} ¥{abs(s['net'])}"
          + (f"（另有{s['pool_wins']}次奖池大奖未计入）" if s["pool_wins"] else ""))
    print(f"✅ 号码分布统计已更新（统计 {stats['total_draws']} 期）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
