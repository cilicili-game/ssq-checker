"""Tests for CLI mode selection (no network)."""
import unittest.mock as m

import pytest

from ssq_checker import __main__ as cli
from ssq_checker.fetcher import Draw


def test_explicit_missing_bets_exits_4_without_fetch(tmp_path, capsys):
    bad = tmp_path / "does-not-exist.csv"
    # fetch_latest_draw must NOT be called when --bets is missing.
    with m.patch.object(cli, "fetch_latest_draw", side_effect=AssertionError("must not fetch")):
        rc = cli.main(["--bets", str(bad)])
    assert rc == 4
    assert "投注表不存在" in capsys.readouterr().err


def test_explicit_bets_used_when_present(tmp_path):
    f = tmp_path / "b.csv"
    f.write_text("红球,蓝球,倍数\n01 02 03 04 08 09,07,5\n", encoding="utf-8")
    draw = Draw(issue="2026070", date="2026-06-21",
                reds=["11", "12", "13", "14", "15", "16"], blue="08")
    with m.patch.object(cli, "fetch_latest_draw", return_value=draw):
        rc = cli.main(["--bets", str(f)])
    assert rc == 0


def test_blue_without_reds_is_rejected(capsys):
    with pytest.raises(SystemExit) as e:
        cli.main(["--blue", "11"])
    assert e.value.code == 2  # argparse error
    assert "--blue requires --reds" in capsys.readouterr().err


def test_reds_flag_overrides_table(tmp_path):
    # When --reds is given explicitly, the table is ignored even if bets.csv exists.
    f = tmp_path / "b.csv"
    f.write_text("红球,蓝球,倍数\n01 02 03 04 08 09,07,5\n", encoding="utf-8")
    draw = Draw(issue="2026070", date="2026-06-21",
                reds=["11", "12", "13", "14", "15", "16"], blue="08")
    with m.patch.object(cli, "fetch_latest_draw", return_value=draw):
        rc = cli.main(["--bets", str(f), "--reds", "01", "02", "03", "04", "05", "06", "--blue", "07"])
    assert rc == 0


# --- Idempotent --notify-new cron mode ---
_ONEOFF = ["--reds", "01", "02", "03", "04", "05", "06", "--blue", "07"]


def _run_notify(state_path, draw, **patch):
    args = [*_ONEOFF, "--telegram", "--notify-new", "--state-file", str(state_path)]
    with m.patch.object(cli, "fetch_latest_draw", return_value=draw), \
         m.patch.object(cli, "send_telegram", **patch) as send:
        rc = cli.main(args)
    return rc, send


def _draw(issue):
    return Draw(issue=issue, date="2026-06-21",
                reds=["11", "12", "13", "14", "15", "16"], blue="08")


def test_notify_new_requires_telegram_and_state(capsys):
    with pytest.raises(SystemExit) as e:
        cli.main([*_ONEOFF, "--notify-new"])
    assert e.value.code == 2
    assert "--notify-new requires --telegram and --state-file" in capsys.readouterr().err


def test_notify_new_first_run_sends_and_records(tmp_path):
    state = tmp_path / "last"
    rc, send = _run_notify(state, _draw("2026070"))
    assert rc == 0 and send.call_count == 1
    assert state.read_text(encoding="utf-8") == "2026070"


def test_notify_new_skips_when_not_newer(tmp_path):
    state = tmp_path / "last"
    state.write_text("2026070", encoding="utf-8")
    rc, send = _run_notify(state, _draw("2026070"))  # same issue
    assert rc == 0 and send.call_count == 0
    assert state.read_text(encoding="utf-8") == "2026070"


def test_notify_new_skips_on_rollback(tmp_path):
    state = tmp_path / "last"
    state.write_text("2026070", encoding="utf-8")
    rc, send = _run_notify(state, _draw("2026069"))  # older than recorded
    assert rc == 0 and send.call_count == 0


def test_notify_new_sends_on_newer_issue(tmp_path):
    state = tmp_path / "last"
    state.write_text("2026069", encoding="utf-8")
    rc, send = _run_notify(state, _draw("2026070"))
    assert rc == 0 and send.call_count == 1
    assert state.read_text(encoding="utf-8") == "2026070"


def test_notify_new_no_record_on_send_failure(tmp_path):
    state = tmp_path / "last"
    rc, send = _run_notify(state, _draw("2026070"), side_effect=RuntimeError("boom"))
    assert rc == 3 and send.call_count == 1
    assert not state.exists()  # receipt not written -> next run retries


def test_notify_new_skips_when_lock_held(tmp_path):
    # A concurrent instance holding the transaction lock => this run must not send.
    state = tmp_path / "last"
    fd = cli._acquire_notify_lock(str(state))
    assert fd is not None
    try:
        rc, send = _run_notify(state, _draw("2026070"))
    finally:
        import os
        os.close(fd)
    assert rc == 0 and send.call_count == 0
    assert not state.exists()  # nothing recorded; the lock owner handles the draw


def test_notify_new_lock_error_is_not_silent_skip(tmp_path):
    # A non-contention lock error (e.g. EIO) must NOT look like "another instance
    # is running" -> it must fail loudly (rc=5), not silently succeed with no send.
    state = tmp_path / "last"
    with m.patch("fcntl.flock", side_effect=OSError("lock blew up")):
        rc, send = _run_notify(state, _draw("2026070"))
    assert rc == 5 and send.call_count == 0


def test_notify_new_read_error_aborts_before_send(tmp_path):
    # A state path that is a directory raises a non-ENOENT OSError on read; the
    # run must abort (rc=5) WITHOUT sending, rather than treat it as "no receipt".
    state = tmp_path / "statedir"
    state.mkdir()
    rc, send = _run_notify(state, _draw("2026070"))
    assert rc == 5 and send.call_count == 0


def test_notify_new_delivery_ok_but_receipt_write_fails(tmp_path):
    # Telegram accepted the message but the receipt write blows up: the run still
    # succeeds (message delivered); receipt stays absent so the next run resends.
    state = tmp_path / "last"
    args = [*_ONEOFF, "--telegram", "--notify-new", "--state-file", str(state)]
    with m.patch.object(cli, "fetch_latest_draw", return_value=_draw("2026070")), \
         m.patch.object(cli, "send_telegram") as send, \
         m.patch.object(cli, "_write_state_atomic", side_effect=OSError("disk full")):
        rc = cli.main(args)
    assert rc == 0 and send.call_count == 1
    assert not state.exists()
