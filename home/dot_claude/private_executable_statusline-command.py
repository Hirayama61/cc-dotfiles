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

# グラデーションの色定義(Panda Syntax パレットに統一)
COLOR_GREEN = (25, 249, 216)   # mint   #19f9d8 低使用率
COLOR_YELLOW = (255, 184, 108)  # orange #ffb86c 中
COLOR_RED = (255, 75, 130)    # red    #ff4b82 高
COLOR_DEEP_RED = (255, 44, 109)   # deep   #ff2c6d 危険


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
        level = filled - i * steps
        if level >= steps:
            chars.append(BRAILLE[steps])  # 満杯: ⣿
        elif level <= 0:
            chars.append(BRAILLE[0])  # 空セル
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


def safe_float(value, default: float = 0.0) -> float:
    """値を float に変換する。変換不能(非数値文字列・None・型不一致)なら default を返す。

    harness が stdin に流す JSON の各フィールドの型は保証されず、used_percentage 等が
    "abc" 等の非数値文字列で来うる。未捕捉 ValueError で statusline を落とさないため吸収する。
    """
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


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


def render(data: dict) -> str:
    """ステータスライン文字列を組み立てる。

    各フィールドは dict とは限らない(harness のスキーマ変更・型ゆれ)ので、
    入れ子の取得は `isinstance(x, dict)` でガードしてから .get() する。
    """
    # ---------- フィールドのパース ----------
    model = data.get("model")
    model_name = model.get("display_name", "Unknown") if isinstance(model, dict) else "Unknown"

    ctx = data.get("context_window")
    used_pct = (ctx.get("used_percentage", 0) if isinstance(ctx, dict) else 0) or 0

    cwd = data.get("cwd", "")
    if not isinstance(cwd, str):
        cwd = ""

    rate_limits = data.get("rate_limits")

    ctx_pct = safe_float(used_pct)

    # レートリミット情報
    rl_5h_pct = None
    rl_5h_resets = None
    rl_7d_pct = None
    rl_7d_resets = None

    if isinstance(rate_limits, dict):
        five_hour = rate_limits.get("five_hour")
        seven_day = rate_limits.get("seven_day")
        if isinstance(five_hour, dict):
            rl_5h_pct = five_hour.get("used_percentage")
            rl_5h_resets = five_hour.get("resets_at")
        if isinstance(seven_day, dict):
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
    sections.append(fmt("5h", safe_float(rl_5h_pct), reset_str))

    # 7日間レートリミット
    reset_str = time_until(rl_7d_resets) if rl_7d_resets else ""
    sections.append(fmt("7d", safe_float(rl_7d_pct), reset_str))

    # gitブランチ
    sections.append(f"{DIM}⎇{RESET} {git_branch or '-'}")

    return sep.join(sections)


def main():
    # ---------- stdinからJSON読み込み ----------
    try:
        raw = sys.stdin.read()
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        print("parse error", end="")
        return

    if not isinstance(data, dict):
        print("status err", end="")
        return

    # statusline は決して例外を漏らさない契約。render が想定外の入力で落ちても
    # 最終フォールバックで安全な短文を出し、本体プロセスに非ゼロ exit を返さない。
    try:
        print(render(data), end="")
    except Exception:
        print("status err", end="")


if __name__ == "__main__":
    main()
