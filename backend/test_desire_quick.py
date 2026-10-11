# 快速冒烟：内核数学是否符合文档口径（跑完即弃，不进正式测试）
import io
import json
import time

import desire

out = []
st = desire.new_state(now=1000.0)

# 1) 8小时无人理：attachment 该涨，fatigue/stress 该消
desire.tick(st, now=1000.0 + 8 * 3600, local_hour=15)
out.append(("after 8h idle", {k: round(v, 3) for k, v in st["drive"].items()}))
assert st["drive"]["attachment"] > 0.9, "attachment should climb high after 8h"
assert st["drive"]["stress"] == 0.0, "stress should decay to 0"

# 2) 她来消息：attachment 乘性回落
before = st["drive"]["attachment"]
desire.event(st, "her_message")
out.append(("her_message", {"attachment": round(st["drive"]["attachment"], 3), "was": round(before, 3)}))
assert st["drive"]["attachment"] < before * 0.65

# 3) 念头：同 text 再喂加强；拍推进衰减；强念头升执念
desire.add_thought(st, "想看她发的那张照片", "attachment", strength=0.5)
desire.add_thought(st, "想看她发的那张照片", "attachment")  # refeed +0.15
desire.add_thought(st, "隧道换网络会不会又断", "duty", strength=0.75)
desire.add_thought(st, "隧道换网络会不会又断", "duty")  # 0.90 → 直接过 0.80 线升执念
t2 = [t for t in st["thoughts"] if t["drive"] == "duty"][0]
assert t2["kind"] == "fixation", "0.90 strength should be fixation"
desire.tick_thoughts(st)  # 一拍：闪念衰减，执念加强→过0.85反哺 duty
out.append(("thoughts after 1 beat", st["thoughts"]))
out.append(("duty after fixation feed", round(st["drive"]["duty"], 3)))

# 4) 挑意图 + fatigue 闸
intent = desire.pick_intent(st)
out.append(("intent", intent))
st["drive"]["fatigue"] = 0.9
assert desire.pick_intent(st)["want_action"] == "rest", "fatigue gate should force rest"
st["drive"]["fatigue"] = 0.2

# 5) public_state 可序列化
json.dumps(desire.public_state(st), ensure_ascii=False)

io.open(r"C:\Users\sxc\Tidal_Echo\backend\test_desire_quick.out.json", "w", encoding="utf-8").write(
    json.dumps(out, ensure_ascii=False, indent=1)
)
print("all assertions passed")
