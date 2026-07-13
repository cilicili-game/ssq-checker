# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Chinese welfare lottery (双色球 / SSQ) draw checker. It fetches the latest draw, compares it against a fixed set of user numbers, and prints a prize report. **Pure Python stdlib, zero runtime dependencies** — this is a deliberate design constraint; do not add runtime dependencies. It was extracted from an AI cron job because the prize logic is fully rule-based and needs no AI.

## Commands

```bash
pip install -e .            # install (or .[dev] for pytest)
pip install -e ".[dev]"

pytest -q                   # run all tests
pytest tests/test_checker.py::test_5_reds_plus_blue_wins_3rd -v   # single test

ssq-checker                                          # run with Logan's default numbers
PYTHONPATH=src python -m ssq_checker                 # run without installing
ssq-checker --reds 05 12 18 22 27 33 --blue 11       # custom numbers
ssq-checker --json                                   # JSON output for piping
```

Lint (per project memory): `ruff check` — note there is currently no ruff config in `pyproject.toml`.

## Architecture

Modules under `src/ssq_checker/`, one-way dependency flow `fetcher → checker → {bets, notify} → history → __main__` (`bets` imports `checker`; `checker` only type-hints `Bet` under `TYPE_CHECKING` to avoid a cycle; `history` imports `bets`/`checker`/`fetcher`):

- **`fetcher.py`** — `Draw` dataclass + network/parsing. `fetch_latest_draw()` pulls the append-only text feed and parses the **last non-empty line** as the latest draw. `parse_line()` splits whitespace and takes fixed positional fields: `[0]`=issue, `[1]`=date, `[2:8]`=6 reds (draw order), `[8]`=blue; trailing fields (sales/pool/payouts) are ignored.
- **`checker.py`** — pure prize logic, no I/O. `PRIZE_TABLE` maps `(red_hits, blue_hit)` → `(tier, fixed_amount)`. This table is the source of truth for all prize rules. `check_prize()` returns a frozen `PrizeResult`. `bet_winnings(result, multiplier)` returns won RMB (0 = no prize, int = fixed tier × multiplier, `None` = pool-based unknown). `normalize()` zero-pads numbers. `format_report()` = single-bet message; `format_bets_report()` = multi-bet table message with per-bet status and totals.
- **`bets.py`** — loads the user's `bets.csv` bet table. `Bet(reds, blue, multiplier)` with `.cost` = `BET_PRICE_RMB(2) × multiplier`. `parse_bets(text)`/`load_bets(path)` validate each row (6 distinct reds 1-33, blue 1-16, multiplier ≥1) and raise `ValueError` with 1-based line context. Accepts Chinese or English headers; reds are space-separated in one cell; `#`/blank lines skipped; file read as `utf-8-sig` (tolerates BOM/Excel).
- **`notify.py`** — `send_telegram(text, token, chat_id)` posts to the Telegram Bot API via stdlib urllib. Raises on missing creds or non-`ok` API response.
- **`history.py`** — **append-only, month-partitioned** profit/loss history for the Pages dashboard. `sync_history(data_dir, draws, bets, start_date)` records any draw (date ≥ `start_date`) whose `issue` isn't already stored, writing `docs/data/YYYY-MM.json` (list of frozen records) + `docs/data/index.json` (manifest: month list + order-independent totals + `current_bets` + `latest`). **Past records are never recomputed** — each `build_record()` snapshots the bets active at record time, so changing `bets.csv` only affects future draws. Cumulative net is computed client-side (not stored). `fetch_all_draws()`/`parse_all()` in `fetcher.py` provide the full feed. `_load_months()` loads only exact `YYYY-MM.json` files (via `_MONTH_FILE_RE`) so sibling files like `stats.json` are never parsed as month records.
- **`stats.py`** — pure red/blue **distribution stats** over the full feed (independent of bets; not start-date-bounded). `compute_stats(draws)` returns per-ball `count`/`gap`(当前遗漏)/`max_gap`(最大遗漏)/`avg_gap`(平均遗漏 = `(total-count)/(count+1)`) for all 33 reds + 16 blues, plus `total_draws` + `span`. `write_stats(data_dir, draws)` writes `docs/data/stats.json`, preserving `generated_at` when the body is unchanged (diff-clean re-runs). Frequency (出现概率) is derived client-side from `count/total_draws`. Wired into `--sync-history` (runs after `sync_history`).
- **`__main__.py`** — argparse CLI. `--sync-history` (with `--data-dir`, `--start-date`) runs the history sync **and** distribution-stats write, then exits. Otherwise **mode selection**: explicit `--reds` → one-off single check; else if `bets.csv` (or `--bets PATH`) exists → table mode; else single-bet defaults (reds `01 02 03 04 08 09`, blue `07`). `--telegram` delivers the report from env `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID`. Exit codes: 2 = fetch failure, 3 = Telegram delivery failure, 4 = bad bet table.

### Pages dashboard

`docs/index.html` is a zero-dependency static page (vanilla JS, inline SVG chart). It fetches `data/index.json`, then each `data/YYYY-MM.json`, concatenates records, computes cumulative net client-side, and renders headline net / totals / chart / per-draw table. It then fetches `data/stats.json` (optional — section skipped if absent) and renders the **号码分布统计** section: heatmap bar charts (color = hot/cold) + detail tables (出现次数/概率/当前遗漏/最大遗漏/平均遗漏) for reds 01–33 and blue 01–16. All feed-derived values are HTML-escaped or numeric-coerced before `innerHTML`. **No GitHub CI** — `docs/data` is generated locally via `ssq-checker --sync-history`, committed, and pushed; Pages serves `master:/docs` directly (**Deploy from a branch**, not Actions). The old `.github/workflows/draw.yml` has been removed.

### Key invariants

- **Ball numbers are always zero-padded 2-char strings** ("01".."33" reds, "01".."16" blue) throughout the pipeline. Comparisons rely on this; use `normalize()` at boundaries.
- Jackpot/2nd prize (`一等奖`/`二等奖`) are pool-based, represented as `amount=None`. `amount=None` also means "no prize" when `tier` is None — distinguish via `tier`.
- A user ticket is treated as a **single 6+1 bet**; `PRIZE_TABLE` is single-bet only.

## Data source

`https://www.17500.cn/getData/ssq.TXT` is the only source that works for plain HTTP fetches. `cwl.gov.cn` returns 403 for datacenter IPs; `datachart.500.com` is a SPA. If the source format changes, `parse_line()` positional indices are what break — pin a real sample line in `tests/test_fetcher.py` (already done) and update there.

## Testing notes

Tests are network-free: `test_fetcher.py` feeds real sample lines to `parse_line()`, and `test_checker.py` constructs `Draw` objects directly. Every prize tier (1st–6th + no-prize) has a dedicated test in `test_checker.py`. When changing prize rules, update `PRIZE_TABLE` and the corresponding tier test together.

## Scheduling

Runs on a schedule (draw days: Sun/Tue/Thu) via **local cron** on this host — `scripts/notify_local.sh` calls `ssq-checker --telegram --notify-new --state-file <f>` (idempotent, at-least-once; creds from repo-root `.env`). GitHub Actions delivery has been retired.
