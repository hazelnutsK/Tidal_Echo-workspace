"""双耳语音条：[[voice]] 回复里写了位置标签，就让声音贴在她耳边、绕着她的头走。

渲染本体是 github.com/Saekisui/binaural-voice（KU100 近场 HRIR，25cm 起），
clone 在 BINAURAL_DIR，这里只做它 README「接进自己的应用」那四步：
  1. 念之前把 [左耳] [右耳] [脑后] [面前] [贴近] [退开] 从稿子里拿掉，记下落在第几个字
     （eleven_v3 会把不认识的方括号当演出指令去演）
  2. /with-timestamps 合成，一次拿到音频 + 逐字起止时间
  3. 标签 → 后面那个字的开始秒数
  4. binaural_voice.py 渲染，ffmpeg 压回 mp3（立体声）

2026-09-25 她甩链接说「我想要这个喵」。只对耳机成立。
"""
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BINAURAL_DIR = Path(os.environ.get("RELAY_BINAURAL_DIR", r"C:\Users\sxc\binaural-voice"))
# 没写位置标签的语音条：0=照旧单声道；1=也双耳，随机抽一种走法
BINAURAL_ALWAYS = os.environ.get("RELAY_BINAURAL_ALWAYS", "0") == "1"
# 合成格式：mp3_44100_128 这档套餐本来就能用，拿回来 ffmpeg 解成 wav；
# pcm_* 省一次解码，但 pcm_44100 要 Pro，pcm_24000 高频只到 12kHz
BINAURAL_TTS_FORMAT = os.environ.get("RELAY_BINAURAL_TTS_FORMAT", "mp3_44100_128")
BINAURAL_MP3_BITRATE = os.environ.get("RELAY_BINAURAL_MP3_BITRATE", "192k")

TAG_RE = re.compile(r"\[(左耳|右耳|脑后|面前|贴近|退开)\]\s?")

_WINGET_FFMPEG = Path.home() / "AppData/Local/Microsoft/WinGet/Links/ffmpeg.exe"


def _ffmpeg() -> str:
    exe = os.environ.get("RELAY_FFMPEG") or shutil.which("ffmpeg")
    if exe:
        return exe
    if _WINGET_FFMPEG.exists():
        return str(_WINGET_FFMPEG)
    for p in (Path.home() / "AppData/Local/Microsoft/WinGet/Packages").glob("Gyan.FFmpeg*/*/bin/ffmpeg.exe"):
        return str(p)
    raise RuntimeError("ffmpeg not found")


def has_tags(text: str) -> bool:
    return bool(TAG_RE.search(text or ""))


def strip_tags(text: str) -> str:
    return TAG_RE.sub("", text or "")


def available() -> bool:
    return (BINAURAL_DIR / "binaural_voice.py").exists()


def split_tags(text: str) -> tuple[str, list[tuple[str, int]]]:
    """拿掉位置标签，返回 (要念的稿子, [(标签, 落在稿子第几个字)])。"""
    tts, marks, last = "", [], 0
    for m in TAG_RE.finditer(text):
        tts += text[last:m.start()]
        marks.append((m.group(1), len(tts)))
        last = m.end()
    return tts + text[last:], marks


def _tts_with_timestamps(text: str, lang: str | None, *, api_base: str, api_key: str,
                         voice_id: str, model: str, stability: float, similarity: float,
                         timeout: float) -> dict:
    url = (
        f"{api_base.rstrip('/')}/v1/text-to-speech/{urllib.parse.quote(voice_id)}/with-timestamps"
        f"?output_format={urllib.parse.quote(BINAURAL_TTS_FORMAT)}"
    )
    payload = {
        "text": text,
        "model_id": model,
        "voice_settings": {"stability": stability, "similarity_boost": similarity},
    }
    if lang:
        payload["language_code"] = lang
    req = urllib.request.Request(
        url,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"xi-api-key": api_key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        try:
            detail = exc.read().decode("utf-8", "replace")[:300]
        except Exception:
            detail = str(exc)
        raise RuntimeError(f"elevenlabs with-timestamps {exc.code}: {detail}")


def render(text: str, lang: str | None, **tts_kw) -> tuple[bytes, list[dict]]:
    """带位置标签的稿子 → 双耳立体声 mp3。返回 (mp3, cues)。任何一步失败直接抛，
    调用方负责回落单声道。"""
    tts, marks = split_tags(text)
    tts = tts.strip() if not marks else tts   # 有标签时别 strip，会把字的下标挪歪
    d = _tts_with_timestamps(tts[:900], lang, **tts_kw)
    audio = base64.b64decode(d.get("audio_base64") or "")
    if not audio:
        raise RuntimeError("with-timestamps returned no audio")

    # 对齐表逐字对应发出去的稿子；对不上就不用标签（渲染器会随机抽走法）
    starts = ((d.get("alignment") or {}).get("character_start_times_seconds")) or []
    if marks and len(starts) == len(tts[:900]):
        cues = [{"tag": tag, "t": float(starts[min(at, len(starts) - 1)])} for tag, at in marks]
    else:
        if marks:
            print(f"[binaural] alignment {len(starts)} != text {len(tts)}, cues dropped", file=sys.stderr)
        cues = []

    ffmpeg = _ffmpeg()
    with tempfile.TemporaryDirectory(prefix="binaural-") as tmp:
        tmp = Path(tmp)
        raw, mono, stereo, mp3 = tmp / "raw.bin", tmp / "mono.wav", tmp / "stereo.wav", tmp / "out.mp3"
        raw.write_bytes(audio)
        if BINAURAL_TTS_FORMAT.startswith("pcm_"):
            rate = BINAURAL_TTS_FORMAT.split("_")[1]
            dec = [ffmpeg, "-y", "-loglevel", "error", "-f", "s16le", "-ar", rate, "-ac", "1", "-i", str(raw), str(mono)]
        else:
            dec = [ffmpeg, "-y", "-loglevel", "error", "-i", str(raw), "-ac", "1", str(mono)]
        subprocess.run(dec, check=True, capture_output=True, timeout=60)
        subprocess.run(
            [sys.executable, str(BINAURAL_DIR / "binaural_voice.py"), str(mono), str(stereo),
             json.dumps(cues, ensure_ascii=False)],
            check=True, capture_output=True, timeout=120, cwd=str(BINAURAL_DIR),
        )
        subprocess.run(
            [ffmpeg, "-y", "-loglevel", "error", "-i", str(stereo),
             "-c:a", "libmp3lame", "-b:a", BINAURAL_MP3_BITRATE, str(mp3)],
            check=True, capture_output=True, timeout=60,
        )
        return mp3.read_bytes(), cues
