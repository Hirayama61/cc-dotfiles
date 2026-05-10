#!/usr/bin/env python3
"""Claude Code ステータスライン - Braille Dotsスタイル

stdinからJSONを受け取り、Braille文字のプログレスバーで
モデル名・コンテキスト使用率・レートリミット・gitブランチを表示する。
"""

import json
import os
import subprocess
import sys
from datetime import datetime, timezone

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
    sep = f" {DIM}│{RESET} "
    sections = []

    # モデル名
    sections.append(model_name)

    # コンテキスト使用率
    sections.append(fmt("ctx", ctx_pct))

    # 5時間レートリミット
    reset_str = time_until(rl_5h_resets) if rl_5h_resets else ""
    sections.append(fmt("5h", float(rl_5h_pct or 0), reset_str))

    # 7日間レートリミット
    reset_str = time_until(rl_7d_resets) if rl_7d_resets else ""
    sections.append(fmt("7d", float(rl_7d_pct or 0), reset_str))

    # gitブランチ
    sections.append(f"{DIM}⎇{RESET} {git_branch or '-'}")

    # ---------- 出力 ----------
    print(sep.join(sections), end="")


if __name__ == "__main__":
    main()
