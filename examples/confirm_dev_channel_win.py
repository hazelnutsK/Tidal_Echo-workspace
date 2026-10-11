#!/usr/bin/env python3
r"""
confirm_dev_channel_win.py — Windows 上自动确认 Claude Code 的 DevChannelsDialog。

只有走「Claude Code + channel/ 插件」这条路才需要。CC 用
    claude --dangerously-load-development-channels server:companion
启动时每次都会弹:

    WARNING: Loading development channels
      y. I am using this for local development
      n. Exit
      Enter y/n:

自建本地 server: 频道进不了 channel allowlist(需 Team/Enterprise),这个框
不吃 --dangerously-skip-permissions,也没有 env/settings 能静默它。无人值守
(开机自启 / 自动重启)时会一直卡在这。

办法:启动 CC 后,往它的子控制台注入按键替它确认。原理是
AttachConsole(pid) + CreateFileW("CONIN$") + WriteConsoleInputW。

⚠️ 2026-09-02(CC 2.1.257)踩到的坑:启动路上其实有**两道**框,前面还有一道
   信任文件夹框,而且新版把它的默认高亮放在了「退出」那一项:

    Quick safety check: Is this a project you created or one you trust?
    ❯ No, exit                    ← 默认高亮在这里
      Yes, I trust this folder

   老脚本无脑注入回车 = 正中 "No, exit" = 新窗口秒退。症状:swap 之后旧窗口关了,
   新窗口一闪就没,身体再也没起来。
   所以现在:先读目标控制台的屏幕(ReadConsoleOutputCharacterW)看停在哪道框,
   按 ❯ 的实际位置决定送回车还是先↓再回车——**不写死方向**,顺序再变也不会选到退出。
   没看到框就一个键都不送:那一下会掉进 REPL 变成一条真发出去的消息。

⚠️ 2026-09-26(CC 2.1.280):CC 默认改用全屏渲染器(alternate screen),
   ReadConsoleOutputCharacterW 在全屏模式下读回来是一片空白 → 脚本以为没框 →
   forge/swap 出来的窗口卡在 dev-channels 框上等人按回车。
   解法在被拉起的 CC 那边:backend\cc-settings.json 写 "tui": "default" 固定经典
   渲染器。自己手动试这个脚本时也要带上那份 --settings,否则时灵时不灵
   (CC 被杀得太快会记一次"全屏没起来",下一次自动退回经典,于是隔一次好一次)。

> Linux / macOS 别用这个 —— 用 tmux 更干净:
>     tmux new-session -d -s cc 'claude --dangerously-load-development-channels server:companion'
>     sleep 3 && tmux send-keys -t cc Enter

用法(Windows):
    # A. 当 launcher:开一个独立控制台跑 CC,并自动确认(适合无人值守)
    python confirm_dev_channel_win.py -- claude --dangerously-load-development-channels server:companion

    # B. 对一个已经在跑的 CC 进程确认(适合从无控制台的服务/调度里调)
    python confirm_dev_channel_win.py --pid 12345
"""

import sys
import time
import ctypes
from ctypes import wintypes

if sys.platform != "win32":
    sys.exit("这个脚本只用于 Windows;Linux/macOS 请用 tmux send-keys(见文件头注释)。")

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
FILE_SHARE_RW = 0x00000003
OPEN_EXISTING = 0x00000003
INVALID_HANDLE_VALUE = wintypes.HANDLE(-1).value
KEY_EVENT = 0x0001
VK_RETURN = 0x0D
VK_DOWN = 0x28

K_ENTER = (VK_RETURN, "\r")
K_DOWN = (VK_DOWN, "\0")

# 屏幕上认框的记号
DIALOG_MARK = "development channels"      # dev-channels 框(编号选项,回车即过)
YN_MARK = "Enter y/n"                     # 万一哪版把它改成 y/n 输入框
TRUST_MARK = "trust this folder"          # 信任文件夹框(选项里有 "No, exit")
CURSOR_MARK = "❯"                    # ❯ 当前高亮行
CLEAR_SECS = 5                            # 答过框后连续这么久没框才算真过完

kernel32.AttachConsole.argtypes = [wintypes.DWORD]
kernel32.AttachConsole.restype = wintypes.BOOL
kernel32.FreeConsole.restype = wintypes.BOOL
kernel32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                 wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
kernel32.CreateFileW.restype = wintypes.HANDLE
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]


class COORD(ctypes.Structure):
    _fields_ = [("X", wintypes.SHORT), ("Y", wintypes.SHORT)]


class SMALL_RECT(ctypes.Structure):
    _fields_ = [("Left", wintypes.SHORT), ("Top", wintypes.SHORT),
                ("Right", wintypes.SHORT), ("Bottom", wintypes.SHORT)]


class CONSOLE_SCREEN_BUFFER_INFO(ctypes.Structure):
    _fields_ = [("dwSize", COORD), ("dwCursorPosition", COORD),
                ("wAttributes", wintypes.WORD), ("srWindow", SMALL_RECT),
                ("dwMaximumWindowSize", COORD)]


kernel32.GetConsoleScreenBufferInfo.argtypes = [wintypes.HANDLE,
                                                ctypes.POINTER(CONSOLE_SCREEN_BUFFER_INFO)]
kernel32.GetConsoleScreenBufferInfo.restype = wintypes.BOOL
kernel32.ReadConsoleOutputCharacterW.argtypes = [wintypes.HANDLE, wintypes.LPWSTR,
                                                 wintypes.DWORD, COORD,
                                                 ctypes.POINTER(wintypes.DWORD)]
kernel32.ReadConsoleOutputCharacterW.restype = wintypes.BOOL


class KEY_EVENT_RECORD(ctypes.Structure):
    _fields_ = [
        ("bKeyDown", wintypes.BOOL),
        ("wRepeatCount", wintypes.WORD),
        ("wVirtualKeyCode", wintypes.WORD),
        ("wVirtualScanCode", wintypes.WORD),
        ("uChar", wintypes.WCHAR),
        ("dwControlKeyState", wintypes.DWORD),
    ]


class INPUT_RECORD(ctypes.Structure):
    class _U(ctypes.Union):
        _fields_ = [("KeyEvent", KEY_EVENT_RECORD)]
    _anonymous_ = ("u",)
    _fields_ = [("EventType", wintypes.WORD), ("u", _U)]


def _read_screen() -> str:
    """读当前(已 Attach 的)控制台可见区文本。失败返回空串。"""
    handle = INVALID_HANDLE_VALUE
    try:
        handle = kernel32.CreateFileW("CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_RW,
                                      None, OPEN_EXISTING, 0, None)
        if handle == INVALID_HANDLE_VALUE:
            return ""
        info = CONSOLE_SCREEN_BUFFER_INFO()
        if not kernel32.GetConsoleScreenBufferInfo(handle, ctypes.byref(info)):
            return ""
        width = info.srWindow.Right - info.srWindow.Left + 1
        lines = []
        buf = ctypes.create_unicode_buffer(width + 1)
        read = wintypes.DWORD(0)
        for y in range(info.srWindow.Top, info.srWindow.Bottom + 1):
            if kernel32.ReadConsoleOutputCharacterW(
                    handle, buf, width, COORD(info.srWindow.Left, y), ctypes.byref(read)):
                lines.append(buf[:read.value])
        return "\n".join(lines)
    except Exception:
        return ""
    finally:
        if handle and handle != INVALID_HANDLE_VALUE:
            kernel32.CloseHandle(handle)


def _send_keys(keys) -> bool:
    """往当前(已 Attach 的)控制台输入缓冲送一串按键。
    keys 可以是字符串(逐字符,'\\r' 走 VK_RETURN),也可以是 [(虚拟键码, 字符)] 列表。"""
    if isinstance(keys, str):
        keys = [(VK_RETURN, ch) if ch == "\r" else (0, ch) for ch in keys]
    handle = INVALID_HANDLE_VALUE
    try:
        handle = kernel32.CreateFileW("CONIN$", GENERIC_WRITE, FILE_SHARE_RW,
                                      None, OPEN_EXISTING, 0, None)
        if handle == INVALID_HANDLE_VALUE:
            return False
        recs = (INPUT_RECORD * (len(keys) * 2))()
        i = 0
        for vk, ch in keys:
            for down in (1, 0):                  # 一次完整按键 = 按下 + 抬起
                recs[i].EventType = KEY_EVENT
                ke = recs[i].KeyEvent
                ke.bKeyDown = down
                ke.wRepeatCount = 1
                ke.wVirtualKeyCode = vk
                ke.wVirtualScanCode = 0x1C if vk == VK_RETURN else 0
                ke.uChar = ch
                ke.dwControlKeyState = 0
                i += 1
        written = wintypes.DWORD(0)
        return bool(kernel32.WriteConsoleInputW(handle, recs, len(recs), ctypes.byref(written)))
    finally:
        if handle and handle != INVALID_HANDLE_VALUE:
            kernel32.CloseHandle(handle)


def _trust_keys(screen: str):
    """信任框:选中"Yes, I trust this folder"再回车。
    ⚠️ 不写死方向——2.1.257 起默认高亮是第一项 "No, exit",按顺序猜会选到退出。
    先看 ❯ 停在哪一行:已经在 trust 那行就直接回车,否则往下挪一格再回车。"""
    lines = screen.split("\n")
    for line in lines:
        if CURSOR_MARK in line:
            return [K_ENTER] if TRUST_MARK in line else [K_DOWN, K_ENTER]
    # 读不到 ❯ 就退回"默认高亮第一项"的假设:trust 不在第一项就往下挪
    opts = [i for i, l in enumerate(lines) if TRUST_MARK in l or "No, exit" in l]
    if opts and TRUST_MARK in lines[opts[0]]:
        return [K_ENTER]
    return [K_DOWN, K_ENTER]


def peek_dialog(pid: int):
    """只读:看 pid 的控制台此刻停在哪个框上,返回 (种类, 屏幕文本)。
    种类:'trust'(信任文件夹) / 'devchan'(dev-channels 编号选项) / 'yn'(y/n 输入框)
         / 'none'(没框) / 'no-console'。"""
    kernel32.FreeConsole()                       # 先脱离自己的 console
    if not kernel32.AttachConsole(pid):          # 接上目标进程的 console
        return "no-console", ""
    try:
        screen = _read_screen()
        if TRUST_MARK in screen:
            return "trust", screen
        if DIALOG_MARK in screen:
            return ("yn" if YN_MARK in screen else "devchan"), screen
        return "none", screen
    finally:
        kernel32.FreeConsole()                   # 还回自己的 console


def answer_dialog(pid: int, kind: str, screen: str) -> bool:
    """替 pid 答这个框。只在 peek_dialog 刚说框还在时调。"""
    if kind == "trust":
        keys = _trust_keys(screen)
    elif kind == "yn":
        keys = "y\r"
    else:
        keys = "\r"                              # dev-channels:默认高亮第一项即"我在本地开发"
    kernel32.FreeConsole()
    if not kernel32.AttachConsole(pid):
        return False
    try:
        return _send_keys(keys)
    finally:
        kernel32.FreeConsole()


ENABLE_QUICK_EDIT_MODE = 0x0040
ENABLE_EXTENDED_FLAGS = 0x0080
kernel32.GetConsoleMode.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
kernel32.GetConsoleMode.restype = wintypes.BOOL
kernel32.SetConsoleMode.argtypes = [wintypes.HANDLE, wintypes.DWORD]
kernel32.SetConsoleMode.restype = wintypes.BOOL


def disable_quick_edit(pid: int) -> str:
    """关掉 pid 所在控制台的快速编辑。
    2026-09-27:她在 companion 窗口里滚动/点了一下,conhost 进了「选择」状态,
    CC 往屏幕写字的那一下被整个挂住——手机那边就只剩沉默。关掉快速编辑后鼠标点窗口不再冻住进程
    (代价:这个窗口里不能拖选复制了)。只动这一个位,其他输入模式原样保留。
    返回 'off'(本来就关着或已关) / 'no-console' / 'failed'。"""
    kernel32.FreeConsole()
    if not kernel32.AttachConsole(pid):
        return "no-console"
    handle = INVALID_HANDLE_VALUE
    try:
        handle = kernel32.CreateFileW("CONIN$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_RW,
                                      None, OPEN_EXISTING, 0, None)
        if handle == INVALID_HANDLE_VALUE:
            return "failed"
        mode = wintypes.DWORD(0)
        if not kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
            return "failed"
        new = (mode.value | ENABLE_EXTENDED_FLAGS) & ~ENABLE_QUICK_EDIT_MODE
        if new != mode.value and not kernel32.SetConsoleMode(handle, new):
            return "failed"
        return "off"
    finally:
        if handle and handle != INVALID_HANDLE_VALUE:
            kernel32.CloseHandle(handle)
        kernel32.FreeConsole()


def quick_edit_state(pid: int) -> str:
    """只读:pid 控制台的快速编辑此刻开着没。返回 'on' / 'off' / 'no-console' / 'failed'。"""
    kernel32.FreeConsole()
    if not kernel32.AttachConsole(pid):
        return "no-console"
    handle = INVALID_HANDLE_VALUE
    try:
        handle = kernel32.CreateFileW("CONIN$", GENERIC_READ, FILE_SHARE_RW,
                                      None, OPEN_EXISTING, 0, None)
        mode = wintypes.DWORD(0)
        if handle == INVALID_HANDLE_VALUE or not kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
            return "failed"
        return "on" if mode.value & ENABLE_QUICK_EDIT_MODE else "off"
    finally:
        if handle and handle != INVALID_HANDLE_VALUE:
            kernel32.CloseHandle(handle)
        kernel32.FreeConsole()


def auto_confirm(pid: int, window: int = 60, interval: float = 1.0,
                 max_answers: int = 6) -> None:
    """在 window 秒内轮询:框渲染出来就替它答,答完框全没了即收工。
    启动路上不止一道框(信任文件夹 → dev-channels),所以答完一道要接着看下一道。
    框有防抢答窗口(刚渲染那一下的按键会被吃掉并重新计时),答不上就下一轮再答。
    ⚠️ 判断"框还在不在"一律走只读的 peek_dialog——框刚关掉那一瞬若误判成还在
    并补送按键,那一下会掉进 REPL 变成一条真发出去的消息。所以答完先静置再只读复查,
    且总答题数封顶 max_answers。全程不抛错(最坏退回人工点一下)。"""
    deadline = time.time() + window
    answers = 0
    clear_since = None
    while time.time() < deadline and answers < max_answers:
        try:
            kind, screen = peek_dialog(pid)
        except Exception:
            kind, screen = "error", ""
        if kind in ("trust", "devchan", "yn"):
            clear_since = None
            try:
                if answer_dialog(pid, kind, screen):
                    answers += 1
                    print(f"[devchan] answered {kind}", file=sys.stderr, flush=True)
            except Exception:
                pass
            time.sleep(1.5)                      # 等它重绘,别在过渡态上再判一次
            continue
        # 两道框之间有一瞬空屏(2026-09-26 实测):答完信任框马上复查会落在空当里,
        # 误以为全答完了,dev-channels 框就没人管。所以要连续 CLEAR_SECS 秒没框才收工。
        if answers and kind == "none":
            clear_since = clear_since or time.time()
            if time.time() - clear_since >= CLEAR_SECS:
                print(f"[devchan] all clear (answers={answers})", file=sys.stderr, flush=True)
                return
        else:
            clear_since = None
        time.sleep(interval)
    if answers:
        print(f"[devchan] answered {answers}x but a dialog may still be up",
              file=sys.stderr, flush=True)
    else:
        print(f"[devchan] no dialog seen in {window}s (nothing sent)",
              file=sys.stderr, flush=True)


def _confirm_then_lock(pid: int) -> None:
    """launcher 线程:先答完开机框,再关快速编辑(CC 起来后再关一次,防它启动时改过输入模式)。"""
    try:
        auto_confirm(pid)
    finally:
        print(f"[devchan] quick-edit {disable_quick_edit(pid)}", file=sys.stderr, flush=True)


def main(argv: list) -> int:
    if "--no-quickedit" in argv:                 # 给已经在跑的窗口补关:--no-quickedit <pid> [<pid>...]
        for p in argv[argv.index("--no-quickedit") + 1:]:
            print(f"{p}: {quick_edit_state(int(p))} -> {disable_quick_edit(int(p))}")
        return 0
    if "--pid" in argv:
        pid = int(argv[argv.index("--pid") + 1])
        auto_confirm(pid)
        return 0

    # launcher 模式:-- 之后是要启动的命令
    if "--" in argv:
        cmd = argv[argv.index("--") + 1:]
    else:
        cmd = argv[1:]
    if not cmd:
        print(__doc__)
        return 2

    import subprocess
    import threading
    CREATE_NEW_CONSOLE = 0x00000010              # 给 CC 独立 console,便于干净地 Attach
    proc = subprocess.Popen(cmd, creationflags=CREATE_NEW_CONSOLE)
    print(f"[devchan] launched pid={proc.pid}: {' '.join(cmd)}", file=sys.stderr, flush=True)
    disable_quick_edit(proc.pid)                 # 越早越好:开机框那几十秒里她点一下窗口也会冻住
    threading.Thread(target=_confirm_then_lock, args=(proc.pid,), daemon=True).start()
    try:
        return proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
        return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
