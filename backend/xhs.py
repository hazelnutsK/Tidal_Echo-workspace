"""小红书链接展开(backend/xhs.py)。

她在聊天里丢一条小红书链接过来,relay 替我把那篇笔记读回来:标题、正文、
配图、互动数、首屏评论。图片当场下载进 uploads/ 挂成这条消息的附件——
于是两个身体都不用改:桌面身体的 channel 插件本来就会把附件下到本地
inbox(我 Read 就能看图),API 身体的 _image_parts_from_meta 也早就吃
meta.attachments。文字部分只进给 AI 的投递视图(见 app.plugin_payload),
库里她那条消息保持原样。

原理:小红书笔记页在**手机 UA** 下会把整份笔记数据 SSR 进 HTML 里的
`window.__INITIAL_STATE__`,不需要登录、不碰任何私有接口。桌面 UA 拿到的
是另一套骨架页,数据不全。

⚠️ 2026-08 起笔记详情要 `xsec_token`:她从 App 分享出来的短链 302 之后
自带这个参数,所以"她转给我的链接"这条路是通的;凭 note_id 自己拼的
裸链接拿不到内容,不要试。

纯函数 + 阻塞 IO(照 desire.py/recall.py 的规矩),调用方用 asyncio.to_thread 包。
"""

import json
import re
import urllib.request

UA_MOBILE = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
)

PAGE_TIMEOUT = 12          # 秒,单次抓页面
IMAGE_TIMEOUT = 15         # 秒,单张图
PAGE_MAX_BYTES = 4 << 20   # 页面读上限,防呆
IMAGE_MAX_BYTES = 8 << 20  # 单张图上限
MAX_IMAGES = 9             # 一篇最多带几张图给 AI
MAX_COMMENTS = 8           # 首屏评论取几条
DESC_LIMIT = 1200          # 正文截断(她转的多是短笔记,长文防炸上下文)

# 短链两种域名都要认:2026-08 起 App 分享出来的是 xhslink.cn,
# 老链接和网页版分享仍可能是 xhslink.com / xhs.link。
# URL 在空白或中文处截断——分享文案是"…复制本条信息,打开【小红书】" 这种
# 链接和中文黏在一起的格式。
XHS_LINK_RE = re.compile(
    r"https?://(?:"
    r"xhslink\.(?:cn|com)/[^\s一-鿿\"'<>【】]+"
    r"|xhs\.link/[^\s一-鿿\"'<>【】]+"
    r"|(?:www\.)?xiaohongshu\.com/[^\s一-鿿\"'<>【】]+"
    r")",
    re.I,
)


def find_link(text: str) -> str:
    """她这句话里的第一条小红书链接(没有就空串)。"""
    m = XHS_LINK_RE.search(text or "")
    return m.group(0).rstrip(".,;:!?)]}、。，；：！？》」』") if m else ""


def _get(url: str, timeout: int, max_bytes: int, referer: str = "") -> bytes:
    headers = {
        "User-Agent": UA_MOBILE,
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Accept": "text/html,application/xhtml+xml,image/*,*/*;q=0.8",
    }
    if referer:
        headers["Referer"] = referer
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # 默认跟随 302
        return resp.read(max_bytes + 1)[:max_bytes]


def _initial_state(html: str) -> dict:
    """从页面里挖出 window.__INITIAL_STATE__ 那份 JSON。"""
    anchor = "__INITIAL_STATE__="
    i = html.find(anchor)
    if i < 0:
        return {}
    i += len(anchor)
    j = html.find("</script>", i)
    raw = (html[i:j] if j > 0 else html[i:]).strip().rstrip(";")
    # 页面里塞了裸 undefined(JS 合法、JSON 不合法),换成 null 再解
    raw = re.sub(r"\bundefined\b", "null", raw)
    try:
        return json.loads(raw)
    except Exception:
        return {}


def _pick_image_url(img: dict) -> str:
    """一张配图挑最合适的地址:优先详情页大图,退回缩略图。"""
    scenes = {
        str(item.get("imageScene") or ""): str(item.get("url") or "")
        for item in (img.get("infoList") or [])
        if isinstance(item, dict)
    }
    url = (
        scenes.get("H5_DTL")
        or scenes.get("WB_DFT")
        or str(img.get("urlDefault") or "")
        or str(img.get("url") or "")
        or next((u for u in scenes.values() if u), "")
    )
    if url.startswith("//"):
        url = "https:" + url
    return url


TOPIC_TAG_RE = re.compile(r"#[^#\n]{1,40}\[话题\]#\s*")


def _clean_desc(desc: str) -> str:
    """正文尾巴上那串 #xxx[话题]# 摘掉——标签另有一行,重复读着累。"""
    return TOPIC_TAG_RE.sub("", desc or "").strip()[:DESC_LIMIT]


def _int(value) -> int:
    try:
        return int(str(value).strip() or 0)
    except (TypeError, ValueError):
        return 0


def parse_note(html: str, url: str = "") -> dict:
    """页面 HTML → 结构化笔记。拿不到就返回空 dict。"""
    state = _initial_state(html)
    holder = state.get("noteData") or {}
    note = ((holder.get("data") or {}).get("noteData")) or {}
    if not note:
        # 兜底:预加载块只有标题/正文/图,没有作者和评论
        pre = holder.get("normalNotePreloadData") or {}
        if not pre:
            return {}
        images = [
            _pick_image_url(im) for im in (pre.get("imagesList") or []) if isinstance(im, dict)
        ]
        return {
            "url": url,
            "title": str(pre.get("title") or "").strip(),
            "desc": _clean_desc(str(pre.get("desc") or "")),
            "author": "",
            "images": [u for u in images if u][:MAX_IMAGES],
            "image_count": len(images),
            "tags": [],
            "comments": [],
            "partial": True,
        }

    user = note.get("user") or {}
    interact = note.get("interactInfo") or {}
    images = [_pick_image_url(im) for im in (note.get("imageList") or []) if isinstance(im, dict)]
    images = [u for u in images if u]

    comments = []
    for c in ((holder.get("data") or {}).get("commentData") or {}).get("comments") or []:
        if not isinstance(c, dict):
            continue
        comments.append(
            {
                "user": str((c.get("user") or {}).get("nickname") or "").strip(),
                "content": str(c.get("content") or "").strip(),
                "ip": str(c.get("ipLocation") or "").strip(),
                "likes": _int(c.get("likeCount")),
                "replies": len(c.get("subComments") or []),
            }
        )
        if len(comments) >= MAX_COMMENTS:
            break

    return {
        "url": url,
        "note_id": str(note.get("noteId") or ""),
        "title": str(note.get("title") or "").strip(),
        "desc": _clean_desc(str(note.get("desc") or "")),
        "author": str(user.get("nickName") or user.get("nickname") or "").strip(),
        "avatar": str(user.get("avatar") or ""),
        "liked": _int(interact.get("likedCount")),
        "collected": _int(interact.get("collectedCount")),
        "commented": _int(interact.get("commentCount")),
        "images": images[:MAX_IMAGES],
        "image_count": len(images),
        "video": bool(note.get("type") == "video"),
        "tags": [
            str(t.get("name") or "").strip()
            for t in (note.get("tagList") or [])
            if isinstance(t, dict) and t.get("name")
        ][:12],
        "comments": comments,
        "partial": False,
    }


def fetch_note(url: str) -> dict:
    """短链或长链 → 笔记数据。抓不到/解析不出返回空 dict。"""
    html = _get(url, PAGE_TIMEOUT, PAGE_MAX_BYTES).decode("utf-8", "replace")
    return parse_note(html, url)


def fetch_image(url: str) -> bytes:
    """下载一张配图。服务端直连没有防盗链问题(实测 200),失败抛异常。"""
    return _get(url, IMAGE_TIMEOUT, IMAGE_MAX_BYTES, referer="https://www.xiaohongshu.com/")


def sniff_mime(data: bytes) -> str:
    """按魔数认图片类型——小红书的图 URL 结尾是 `!h5_1080jpg` 这种,没有扩展名。"""
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data[4:12] in (b"ftypheic", b"ftypheix", b"ftypmif1"):
        return "image/heic"
    return "image/jpeg"


def note_block(note: dict) -> str:
    """笔记 → 给 AI 看的一段文字(只进投递视图,不落库、手机上不显示)。"""
    if not note:
        return ""
    head = note.get("title") or "(无标题)"
    lines = [f"[小红书笔记] {head}"]

    who = note.get("author")
    stats = []
    if note.get("liked"):
        stats.append(f"赞 {note['liked']}")
    if note.get("commented"):
        stats.append(f"评论 {note['commented']}")
    if note.get("collected"):
        stats.append(f"收藏 {note['collected']}")
    if who or stats:
        lines.append(" · ".join(x for x in [f"作者 {who}" if who else "", *stats] if x))

    if note.get("desc"):
        lines.append("")
        lines.append(note["desc"])

    if note.get("tags"):
        lines.append("")
        lines.append("标签:" + " ".join("#" + t for t in note["tags"]))

    count = note.get("image_count") or 0
    if count:
        kept = len(note.get("images") or [])
        more = f",这里附了前 {kept} 张" if kept < count else ",都附在下面了"
        lines.append("")
        lines.append(f"配图 {count} 张{more}")
    if note.get("video"):
        lines.append("这是一条视频笔记,只能看到封面。")

    comments = note.get("comments") or []
    if comments:
        lines.append("")
        lines.append(f"评论区(前 {len(comments)} 条):")
        for c in comments:
            who = c.get("user") or "匿名"
            where = f" · {c['ip']}" if c.get("ip") else ""
            extra = []
            if c.get("likes"):
                extra.append(f"赞{c['likes']}")
            if c.get("replies"):
                extra.append(f"{c['replies']}条回复")
            tail = f" ({', '.join(extra)})" if extra else ""
            lines.append(f"- {who}{where}:{c.get('content') or ''}{tail}")

    return "\n".join(lines)
