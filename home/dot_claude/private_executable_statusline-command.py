#!/usr/bin/env python3
"""Claude Code ステータスライン - Braille Dotsスタイル

stdinからJSONを受け取り、Braille文字のプログレスバーで
モデル名・コンテキスト使用率・レートリミット・行数変更・gitブランチを表示する。
"""

import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import Optional

# ---------- 定数 ----------
# Braille文字セット（8段階: 空→満）
BRAILLE = " ⣀⣄⣤⣦⣶⣷⣿"

# ANSIエスケープ
DIM = "\033[2m"
RESET = "\033[0m"

# グラデーションの色定義
COLOR_GREEN = (151, 201, 195)
COLOR_YELLOW = (229, 192, 123)
COLOR_RED = (224, 108, 117)
COLOR_DEEP_RED = (192, 64, 64)


def _lerp(a: tuple, b: tuple, t: float) -> tuple:
    """2色間の線形補間"""
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(pct: float) -> str:
    """使用率(0-100)に応じたTrueColorのANSIエスケープコードを返す

    0-50%:  緑 → 黄
    50-80%: 黄 → 赤
    80-100%: 赤 → 深赤
    """
    pct = max(0.0, min(100.0, pct))
    if pct <= 50:
        r, g, b = _lerp(COLOR_GREEN, COLOR_YELLOW, pct / 50)
    elif pct <= 80:
        r, g, b = _lerp(COLOR_YELLOW, COLOR_RED, (pct - 50) / 30)
    else:
        r, g, b = _lerp(COLOR_RED, COLOR_DEEP_RED, (pct - 80) / 20)
    return f"\033[38;2;{r};{g};{b}m"


def braille_bar(pct: float, width: int = 8) -> str:
    """使用率(0-100)からBrailleプログレスバーを生成する

    各文字は8段階（BRAILLE配列のインデックス0-7）で表現。
    width文字分の合計ステップ数に対してpctを割り当て、
    満杯の文字→部分的な文字→空文字の順で構成する。
    """
    steps = len(BRAILLE) - 1  # 7段階（0除く）
    total = width * steps
    filled = pct / 100.0 * total
    chars = []
    for i in range(width):
        # この文字位置に割り当てられるレベル
        level = filled - i * steps
        if level >= steps:
            chars.append(BRAILLE[steps])  # 満杯: ⣿
        elif level <= 0:
            chars.append(BRAILLE[0])  # 空: スペース→⣀の前の空
        else:
            chars.append(BRAILLE[int(level)])
    return "".join(chars)


def fmt(label: str, pct: float, reset_str: str = "") -> str:
    """DIMラベル + グラデーションバー + 数値 のフォーマット

    reset_str が指定されている場合はリセット時刻も表示する。
    """
    color = gradient(pct)
    bar = braille_bar(pct)
    pct_int = int(round(pct))
    result = f"{DIM}{label}{RESET} {color}{bar}{RESET} {pct_int}%"
    if reset_str:
        result += f" {reset_str}"
    return result


def time_until(resets_at) -> str:
    """リセット時刻から残り時間を人間が読みやすい形式で返す

    resets_at はUnixエポック秒（int/float）またはISO8601文字列。
    例: "3h12m", "2d8h", "45m", "0m"
    """
    try:
        now = datetime.now(timezone.utc)
        if isinstance(resets_at, (int, float)):
            reset_dt = datetime.fromtimestamp(resets_at, tz=timezone.utc)
        else:
            reset_dt = datetime.fromisoformat(str(resets_at).replace("Z", "+00:00"))
        diff = reset_dt - now
        total_seconds = max(0, int(diff.total_seconds()))
    except (ValueError, AttributeError, OSError, OverflowError):
        return ""

    days = total_seconds // 86400
    hours = (total_seconds % 86400) // 3600
    minutes = (total_seconds % 3600) // 60

    if days > 0:
        return f"{days}d{hours}h"
    elif hours > 0:
        return f"{hours}h{minutes:02d}m"
    else:
        return f"{minutes}m"


def write_tmux_session(
    pane_id: str,
    cwd: str,
    model_name: str,
    ctx_pct: float,
    rl_5h: Optional[float] = None,
    rl_7d: Optional[float] = None,
) -> None:
    """tmux監視用のセッション情報をJSONファイルに書き出す

    TMUX_PANE環境変数がある場合のみ動作し、
    /tmp/claude-sessions/{safe_pane_id}.json に書き出す。
    notification-tracker.shが書き込むidle/waiting状態を尊重し、
    コンテキスト使用率に変化がない場合はstateを上書きしない。
    """
    safe_id = pane_id.replace("%", "pct")
    mon_dir = "/tmp/claude-sessions"
    mon_file = os.path.join(mon_dir, f"{safe_id}.json")

    os.makedirs(mon_dir, exist_ok=True)

    # tmux情報取得
    try:
        tmux_info = subprocess.run(
            [
                "tmux",
                "display-message",
                "-t",
                pane_id,
                "-p",
                "#{window_name}||#{window_index}||#{session_name}",
            ],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if tmux_info.returncode != 0 or not tmux_info.stdout.strip():
            return
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return

    parts = tmux_info.stdout.strip().split("||")
    if len(parts) != 3:
        return

    win_name, win_idx, sess_name = parts

    # 既存のstate判定: idle/waitingはコンテキスト変化がなければ保持する
    state = "active"
    try:
        with open(mon_file, "r") as f:
            existing = json.load(f)
        existing_state = existing.get("state", "active")
        if existing_state in ("idle", "waiting"):
            # コンテキスト使用率の変化で処理再開を検出する
            prev_ctx = existing.get("context_pct_raw", -1)
            if abs(ctx_pct - prev_ctx) < 0.01:
                # 変化なし → idle/waitingを保持
                state = existing_state
            # 変化あり → activeにリセット（デフォルト値のまま）
    except (OSError, json.JSONDecodeError, TypeError, KeyError):
        # ファイル不在・破損時はactiveにフォールバック
        pass

    data = {
        "pane_id": pane_id,
        "state": state,
        "window_name": win_name,
        "window_index": win_idx,
        "session_name": sess_name,
        "pane_path": cwd,
        "model": model_name,
        "context_pct": int(round(ctx_pct)),
        "context_pct_raw": ctx_pct,
        "timestamp": int(time.time()),
    }

    # レートリミット情報を追加
    if rl_5h is not None:
        data["rl_5h"] = round(rl_5h, 1)
    if rl_7d is not None:
        data["rl_7d"] = round(rl_7d, 1)

    # アトミック書き込み（tmp→mv）
    tmp_file = f"{mon_file}.tmp.{os.getpid()}"
    try:
        with open(tmp_file, "w") as f:
            json.dump(data, f)
        os.replace(tmp_file, mon_file)
    except OSError:
        # 書き込み失敗は無視（ステータスライン表示に影響させない）
        try:
            os.unlink(tmp_file)
        except OSError:
            pass


def main():
    # ---------- stdinからJSON読み込み ----------
    try:
        raw = sys.stdin.read()
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        print("parse error", end="")
        return

    # ---------- フィールドのパース ----------
    model_name = data.get("model", {}).get("display_name", "Unknown")
    used_pct = data.get("context_window", {}).get("used_percentage", 0) or 0
    cwd = data.get("cwd", "")
    lines_added = data.get("cost", {}).get("total_lines_added", 0) or 0
    lines_removed = data.get("cost", {}).get("total_lines_removed", 0) or 0
    rate_limits = data.get("rate_limits")

    ctx_pct = float(used_pct)

    # レートリミット情報
    rl_5h_pct = None
    rl_5h_resets = None
    rl_7d_pct = None
    rl_7d_resets = None

    if rate_limits:
        five_hour = rate_limits.get("five_hour", {})
        seven_day = rate_limits.get("seven_day", {})
        rl_5h_pct = five_hour.get("used_percentage")
        rl_5h_resets = five_hour.get("resets_at")
        rl_7d_pct = seven_day.get("used_percentage")
        rl_7d_resets = seven_day.get("resets_at")

    # ---------- gitブランチ取得 ----------
    git_branch = ""
    if cwd and os.path.isdir(cwd):
        try:
            result = subprocess.run(
                ["git", "-C", cwd, "--no-optional-locks", "rev-parse", "--abbrev-ref", "HEAD"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            if result.returncode == 0:
                git_branch = result.stdout.strip()
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

    # ---------- セクション組み立て ----------
    sep = f" {DIM}\u2502{RESET} "
    sections = []

    # モデル名
    sections.append(model_name)

    # コンテキスト使用率（常に表示）
    sections.append(fmt("ctx", ctx_pct))

    # 5時間レートリミット（常に表示）
    reset_str = ""
    if rl_5h_resets:
        reset_str = time_until(rl_5h_resets)
    sections.append(fmt("5h", float(rl_5h_pct or 0), reset_str))

    # 7日間レートリミット（常に表示）
    reset_str = ""
    if rl_7d_resets:
        reset_str = time_until(rl_7d_resets)
    sections.append(fmt("7d", float(rl_7d_pct or 0), reset_str))

    # 行数変更（常に表示）
    sections.append(f"{DIM}±{RESET} +{lines_added}/-{lines_removed}")

    # gitブランチ（常に表示）
    sections.append(f"{DIM}⎇{RESET} {git_branch or '-'}")

    # ---------- tmux監視JSON書き出し ----------
    tmux_pane = os.environ.get("TMUX_PANE")
    if tmux_pane:
        try:
            write_tmux_session(
                pane_id=tmux_pane,
                cwd=cwd,
                model_name=model_name,
                ctx_pct=ctx_pct,
                rl_5h=rl_5h_pct,
                rl_7d=rl_7d_pct,
            )
        except Exception:
            # tmux監視の失敗はステータスライン表示に影響させない
            pass

    # ---------- 出力 ----------
    print(sep.join(sections), end="")


if __name__ == "__main__":
    main()
