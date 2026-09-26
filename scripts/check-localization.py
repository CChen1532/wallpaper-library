#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""界面文案本地化检查。

1. Sources/WallpaperUI 里的每条中文文案都必须能在 en.lproj 找到条目；
2. en.lproj 与 zh-Hans.lproj 的键集合必须一致；
3. 英文条目的值里不能残留中文。

用法：python3 scripts/check-localization.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UI = os.path.join(ROOT, "Sources/WallpaperUI")
EN = os.path.join(ROOT, "Resources/en.lproj/Localizable.strings")
ZH = os.path.join(ROOT, "Resources/zh-Hans.lproj/Localizable.strings")

# 不是界面文案：正则片段、默认素材目录等
ALLOWLIST = {
    r"(?i)\b(intro|opening)\b|开场|片头",
    "Movies/Wallpapers2",
    "Movies/Wallpapers",
    r"^(\d+) (分钟|秒)$",
    r"\($0 / 60) 分钟",
    r"\($0) 秒",
}

STR = re.compile(r'"((?:[^"\\]|\\.)*)"')
CJK = re.compile(r"[\u4e00-\u9fff]")


def read_table(path):
    entries = {}
    if not os.path.exists(path):
        print("缺少本地化表:", path)
        sys.exit(1)
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line.startswith('"') or " = " not in line:
            continue
        end = 1
        while end < len(line):
            if line[end] == "\\":
                end += 2
                continue
            if line[end] == '"':
                break
            end += 1
        key = line[1:end]
        match = re.match(r'^=\s*"(.*)";$', line[end + 1:].strip())
        if match:
            entries[key] = match.group(1)
    return entries


en = read_table(EN)
zh = read_table(ZH)

failures = 0
literals = []
for name in sorted(os.listdir(UI)):
    if not name.endswith(".swift"):
        continue
    for line in open(os.path.join(UI, name), encoding="utf-8"):
        code = re.sub(r"//.*", "", line)
        for match in STR.finditer(code):
            text = match.group(1)
            if not CJK.search(text):
                continue
            # 带 Swift 插值的文案：以 \( 之前的静态前缀作为查表键
            cutoff = text.find("\\(")
            literals.append((name, text[:cutoff] if cutoff > 0 else text))

missing = sorted({t for _, t in literals if t not in en and t not in ALLOWLIST})
if missing:
    failures += len(missing)
    print("以下文案没有英文本地化条目（%d 条）:" % len(missing))
    for text in missing:
        print("   -", text)
else:
    print("界面文案全部有英文本地化条目（检查 %d 条，允许清单 %d 条）" % (len(literals), len(ALLOWLIST)))

only_en = sorted(set(en) - set(zh))
only_zh = sorted(set(zh) - set(en))
if only_en or only_zh:
    failures += len(only_en) + len(only_zh)
    print("en 与 zh-Hans 键不一致：仅 en %d 条、仅 zh-Hans %d 条" % (len(only_en), len(only_zh)))
    for key in (only_en + only_zh)[:10]:
        print("   -", key)
else:
    print("en 与 zh-Hans 键集合一致（各 %d 条）" % len(en))

# 「简体中文」在两种语言下都显示中文，属预期
chinese_values = sorted(k for k, v in en.items() if CJK.search(v) and k != "简体中文")
if chinese_values:
    failures += len(chinese_values)
    print("英文条目里仍有中文（%d 条）:" % len(chinese_values))
    for key in chinese_values[:10]:
        print("   -", key, "=>", en[key])
else:
    print("英文条目的值里没有残留中文")

if failures:
    print("本地化检查失败：%d 处问题" % failures)
    sys.exit(1)
print("本地化检查通过")
