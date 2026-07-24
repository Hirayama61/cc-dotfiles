#!/usr/bin/env python3
"""Claude Code ステータスライン - Braille Dotsスタイル

stdinからJSONを受け取り、Braille文字のプログレスバーで
モデル名・コンテキスト使用率・レートリミット・gitブランチを表示する。
"""

import json
import os
import stat as stat_mod
import subprocess
import sys
import time
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


def ctx_key(transcript_path: str) -> str:
    """transcript_path から ctx キーを導出する。

    hooks/lib/context-paths.sh の claude_ctx_key と同一導出(等価性は
    tests/lib/context-paths.bats の二言語契約テストで固定)。
    不正な segment(空 / . / .. / スラッシュ残存)は空を返す。
    """
    if not transcript_path:
        return ""
    raw = transcript_path
    if raw.endswith(".jsonl"):
        raw = raw[: -len(".jsonl")]
    key = os.path.basename(raw)
    if key in ("", ".", "..") or "/" in key:
        return ""
    return key


def write_usage(data: dict) -> None:
    """コンテキスト使用率を hook 群へ受け渡す usage.json を書く。

    hook の stdin には使用率が来ないため、statusline がここで cache へ書き出し
    context-pressure 系 hook が読む(唯一の供給源)。used_percentage は会話開始前
    null になる(実測 2026-07-23)ので、その間は書かない(0 と未計測を区別する)。
    失敗は statusline 描画を壊さないためすべて握る(hook 側は fail-open で素通し)。
    """
    try:
        pct = data.get("context_window", {}).get("used_percentage")
        transcript_path = data.get("transcript_path") or ""
        ctx = ctx_key(transcript_path)
        if pct is None or not ctx:
            return
        base = os.environ.get("XDG_CACHE_HOME") or ""
        if not base.startswith("/"):
            base = os.path.join(os.path.expanduser("~"), ".cache")
        ctx_dir = os.path.join(base, "claude-context", ctx)
        os.makedirs(ctx_dir, mode=0o700, exist_ok=True)
        # bash 側 claude_ctx_cache_ensure と同じ検証(非 symlink・自ユーザ所有)。
        # 既存 dir が symlink 等で不正ならリンク先へ書かず中止する。
        st = os.lstat(ctx_dir)
        if stat_mod.S_ISLNK(st.st_mode) or not stat_mod.S_ISDIR(st.st_mode):
            return
        if st.st_uid != os.getuid():
            return
        # makedirs(exist_ok=True) は既存 dir の mode を直さないため明示的に締める
        if stat_mod.S_IMODE(st.st_mode) != 0o700:
            os.chmod(ctx_dir, 0o700)
        payload = {
            "pct": float(pct),
            "transcript_path": transcript_path,
            "updated_at": int(time.time()),
        }
        tmp = os.path.join(ctx_dir, ".usage.json.tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, os.path.join(ctx_dir, "usage.json"))
    except Exception:
        pass


def main():
    # ---------- stdinからJSON読み込み ----------
    try:
        raw = sys.stdin.read()
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        print("parse error", end="")
        return

    write_usage(data)

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
