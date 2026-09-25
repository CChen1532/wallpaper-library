#!/usr/bin/env python3
"""Journal for a manually operated, reversible two-Space wallpaper trial.

This tool never reads or changes macOS wallpaper settings. The operator must
compare every value and image with System Settings and Mission Control.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
from datetime import datetime, timezone


MANIFEST = "manifest.json"
SEAL = "manifest.sha256"
JOURNAL = "journal.json"


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def canonical(data):
    return (json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def atomic_write(path, data):
    fd, temporary = tempfile.mkstemp(prefix=".recovery-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_json(path):
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def image_path(root, relative):
    if (not isinstance(relative, str) or not relative.startswith("evidence/")
            or ".." in Path(relative).parts):
        raise ValueError("证据图片必须位于 recovery/evidence/ 内")
    candidate = root / relative
    if candidate.is_symlink() or not candidate.is_file():
        raise ValueError("证据图片缺失或为符号链接: " + relative)
    try:
        candidate.resolve(strict=True).relative_to(root.resolve(strict=True))
    except ValueError as error:
        raise ValueError("证据图片越出恢复目录: " + relative) from error
    if candidate.suffix.lower() not in (".png", ".jpg", ".jpeg", ".heic"):
        raise ValueError("证据图片格式必须是 PNG/JPEG/HEIC: " + relative)
    if candidate.stat().st_size < 100:
        raise ValueError("证据图片过小: " + relative)
    with candidate.open("rb") as stream:
        header = stream.read(16)
    if not (header.startswith(b"\x89PNG\r\n\x1a\n")
            or header.startswith(b"\xff\xd8\xff")
            or (header[4:8] == b"ftyp" and header[8:12] in (b"heic", b"heix", b"mif1"))):
        raise ValueError("证据图片内容不是 PNG/JPEG/HEIC: " + relative)
    return candidate


def hash_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def template_space(label, prefix):
    return {
        "label": label,
        "wallpaper": {
            "selected_name": "",
            "collection": "",
            "catalog_item": "",
            "show_as_screen_saver": None,
            "show_on_all_spaces": None,
            "other_visible_options": {},
        },
        "settings_image": "evidence/" + prefix + "-settings.png",
        "desktop_image": "evidence/" + prefix + "-desktop.png",
    }


def create(root, display_id):
    root.mkdir(parents=True, exist_ok=False)
    (root / "evidence").mkdir()
    manifest = {
        "schema": 1,
        "display_id": display_id,
        "space_count": 0,
        "mission_control_image": "evidence/mission-control.png",
        "shared_desktop_visual": None,
        "targets": [template_space("桌面 1", "desktop-1"),
                    template_space("桌面 2", "desktop-2")],
        "sentinel": None,
        "screen_saver": {
            "selected_name": "",
            "show_on_all_spaces": None,
            "settings_image": "evidence/screen-saver.png",
        },
        "evidence_sha256": {},
    }
    atomic_write(root / MANIFEST, canonical(manifest))
    print("已创建草稿；先填写编号桌面数（不计全屏应用）、两个目标桌面的选项和截图。")


def validate_space(space, require_desktop_image=True):
    if not isinstance(space, dict) or not isinstance(space.get("label"), str) or not space["label"].strip():
        raise ValueError("Space 标签缺失")
    wallpaper = space.get("wallpaper")
    if not isinstance(wallpaper, dict):
        raise ValueError(space["label"] + " 缺少墙纸记录")
    for key in ("selected_name", "collection", "catalog_item"):
        if not isinstance(wallpaper.get(key), str) or not wallpaper[key].strip():
            raise ValueError(space["label"] + " 缺少 " + key)
    for key in ("show_as_screen_saver", "show_on_all_spaces"):
        if type(wallpaper.get(key)) is not bool:
            raise ValueError(space["label"] + " 缺少明确的 " + key)
    if wallpaper["show_on_all_spaces"]:
        raise ValueError(space["label"] + " 开启了“在所有空间中显示”，不能隔离两个 Space")
    if not isinstance(wallpaper.get("other_visible_options"), dict):
        raise ValueError(space["label"] + " 缺少其他可见选项记录")
    required_images = ("settings_image", "desktop_image") if require_desktop_image else ("settings_image",)
    for key in required_images:
        if not isinstance(space.get(key), str) or not space[key]:
            raise ValueError(space["label"] + " 缺少 " + key)
    if not require_desktop_image and space.get("desktop_image") is not None:
        raise ValueError(space["label"] + " 已使用共用桌面截图，desktop_image 应为空")


def validate_manifest(root, manifest):
    if manifest.get("schema") != 1 or not isinstance(manifest.get("display_id"), int) or manifest["display_id"] <= 0:
        raise ValueError("恢复清单版本或显示器 ID 无效")
    count = manifest.get("space_count")
    if type(count) is not int or count < 2:
        raise ValueError("必须记录 Mission Control 中的实际编号桌面数（不计全屏应用）")
    targets = manifest.get("targets")
    if not isinstance(targets, list) or len(targets) != 2:
        raise ValueError("必须恰好记录两个目标 Space")
    shared = manifest.get("shared_desktop_visual")
    if shared is not None and not isinstance(shared, dict):
        raise ValueError("共用桌面截图记录无效")
    for space in targets:
        validate_space(space, require_desktop_image=shared is None)
    sentinel = manifest.get("sentinel")
    if count > 2:
        if sentinel is None:
            raise ValueError("有其他 Space 时须记录至少一个未参与的对照 Space")
        validate_space(sentinel, require_desktop_image=shared is None)
    elif sentinel is not None:
        raise ValueError("只有两个 Space 时不应填写对照 Space")
    spaces = targets + ([sentinel] if sentinel else [])
    labels = [item["label"] for item in spaces]
    if len(labels) != len(set(labels)):
        raise ValueError("Space 标签重复")
    if len(spaces) > count:
        raise ValueError("记录的 Space 数多于实际数量")
    if shared is not None:
        if (type(shared.get("user_confirmed_same_wallpaper")) is not bool
                or not shared["user_confirmed_same_wallpaper"]
                or not isinstance(shared.get("applies_to"), list)
                or shared["applies_to"] != labels
                or not isinstance(shared.get("image"), str)
                or not shared["image"]):
            raise ValueError("共用桌面截图须有用户确认，并按顺序覆盖全部记录的 Space")
        if any(space["wallpaper"] != spaces[0]["wallpaper"] for space in spaces[1:]):
            raise ValueError("共用桌面截图对应的 Space 墙纸设置不一致")
    images = [manifest.get("mission_control_image")]
    screen_saver = manifest.get("screen_saver")
    if (not isinstance(screen_saver, dict)
            or not isinstance(screen_saver.get("selected_name"), str)
            or not screen_saver["selected_name"].strip()
            or type(screen_saver.get("show_on_all_spaces")) is not bool):
        raise ValueError("缺少独立屏幕保护程序的原选择或选项")
    images.append(screen_saver.get("settings_image"))
    for space in spaces:
        images.append(space["settings_image"])
        if shared is None:
            images.append(space["desktop_image"])
    if shared is not None:
        images.append(shared["image"])
    if len(images) != len(set(images)):
        raise ValueError("证据图片路径重复")
    return {relative: hash_file(image_path(root, relative)) for relative in images}


def verify(root):
    manifest = read_json(root / MANIFEST)
    seal_path = root / SEAL
    if not seal_path.is_file():
        raise ValueError("恢复清单未封存")
    if seal_path.read_text(encoding="ascii").strip() != hashlib.sha256(canonical(manifest)).hexdigest():
        raise ValueError("封存后清单发生变化")
    hashes = validate_manifest(root, manifest)
    if hashes != manifest.get("evidence_sha256"):
        raise ValueError("证据图片发生变化")
    journal = read_json(root / JOURNAL)
    if not isinstance(journal, dict) or journal.get("state") not in ("sealed", "recovery_pending", "completed"):
        raise ValueError("恢复日志状态无效")
    if not isinstance(journal.get("restored"), dict):
        raise ValueError("恢复日志状态无效")
    for key in ("sentinel_verified", "screen_saver_verified"):
        if journal.get(key) is not False and not isinstance(journal.get(key), dict):
            raise ValueError("恢复日志状态无效")
    expected = {space["label"] for space in manifest["targets"]}
    if not set(journal["restored"]).issubset(expected):
        raise ValueError("恢复日志状态无效")
    entries = list(journal.get("restored", {}).values())
    if journal.get("sentinel_verified"):
        entries.append(journal["sentinel_verified"])
    if journal.get("screen_saver_verified"):
        entries.append(journal["screen_saver_verified"])
    for entry in entries:
        if not isinstance(entry, dict) or hash_file(image_path(root, entry["evidence"])) != entry["evidence_sha256"]:
            raise ValueError("恢复后的证据图片发生变化")
    if journal["state"] == "completed":
        if (set(journal["restored"]) != expected
                or bool(journal["sentinel_verified"]) != bool(manifest["sentinel"])
                or not journal["screen_saver_verified"]):
            raise ValueError("恢复日志已标完成但核对不全")
    return manifest, journal


def seal(root):
    if (root / SEAL).exists() or (root / JOURNAL).exists():
        raise ValueError("恢复清单已经封存")
    manifest = read_json(root / MANIFEST)
    manifest["evidence_sha256"] = validate_manifest(root, manifest)
    manifest["sealed_at"] = now()
    atomic_write(root / MANIFEST, canonical(manifest))
    atomic_write(root / SEAL, (hashlib.sha256(canonical(manifest)).hexdigest() + "\n").encode("ascii"))
    atomic_write(root / JOURNAL, canonical({"state": "sealed", "restored": {},
                                            "sentinel_verified": False,
                                            "screen_saver_verified": False,
                                            "updated_at": now()}))
    verify(root)
    print("清单和图片已封存；仍须人工核对 Space 对应关系并另获壁纸更改许可。")


def update_journal(root, journal):
    journal["updated_at"] = now()
    atomic_write(root / JOURNAL, canonical(journal))


def begin(root):
    _, journal = verify(root)
    if journal["state"] != "sealed":
        raise ValueError("试验已开始或结束")
    journal["state"] = "recovery_pending"
    journal["began_at"] = now()
    update_journal(root, journal)
    print("已先记录待恢复状态。只有获本次明确许可后，才能在系统设置中更改壁纸。")


def matching_space(manifest, label):
    for item in manifest["targets"] + ([manifest["sentinel"]] if manifest["sentinel"] else []):
        if item["label"] == label:
            return item
    raise ValueError("未知 Space: " + label)


def ensure_new_evidence(manifest, journal, relative):
    if relative in manifest["evidence_sha256"]:
        raise ValueError("恢复截图必须是新文件，不能复用更改前的图片")
    recorded = list(journal["restored"].values())
    for key in ("sentinel_verified", "screen_saver_verified"):
        if journal[key]:
            recorded.append(journal[key])
    if any(item["evidence"] == relative for item in recorded):
        raise ValueError("同一恢复截图不能用于多个核对项目")


def check_observation(original, args):
    wallpaper = original["wallpaper"]
    observed = {
        "selected_name": args.selected_name,
        "collection": args.collection,
        "catalog_item": args.catalog_item,
        "show_as_screen_saver": args.screen_saver == "on",
        "show_on_all_spaces": args.all_spaces == "on",
        "other_visible_options": json.loads(args.other_options_json),
    }
    for key, value in observed.items():
        if wallpaper[key] != value:
            raise ValueError(original["label"] + " 恢复值与封存清单不符: " + key)
    return observed


def mark_observed(root, args, sentinel=False):
    manifest, journal = verify(root)
    if journal["state"] != "recovery_pending":
        raise ValueError("未进入待恢复状态")
    original = matching_space(manifest, args.space)
    if sentinel != (manifest["sentinel"] is not None and original == manifest["sentinel"]):
        raise ValueError("目标 Space 与对照 Space 的命令不能混用")
    observed = check_observation(original, args)
    evidence = image_path(root, args.evidence)
    ensure_new_evidence(manifest, journal, args.evidence)
    entry = {"observed": observed, "evidence": args.evidence,
             "evidence_sha256": hash_file(evidence), "checked_at": now()}
    if sentinel:
        journal["sentinel_verified"] = entry
    else:
        journal["restored"][args.space] = entry
    update_journal(root, journal)
    print(args.space + " 已记录人工目视核对；工具无法自行判读截图内容。")


def mark_screen_saver(root, args):
    manifest, journal = verify(root)
    if journal["state"] != "recovery_pending":
        raise ValueError("未进入待恢复状态")
    original = manifest["screen_saver"]
    if (args.selected_name != original["selected_name"]
            or (args.all_spaces == "on") != original["show_on_all_spaces"]):
        raise ValueError("屏幕保护程序与封存清单不符")
    evidence = image_path(root, args.evidence)
    ensure_new_evidence(manifest, journal, args.evidence)
    journal["screen_saver_verified"] = {
        "selected_name": args.selected_name,
        "show_on_all_spaces": args.all_spaces == "on",
        "evidence": args.evidence,
        "evidence_sha256": hash_file(evidence),
        "checked_at": now(),
    }
    update_journal(root, journal)
    print("独立屏幕保护程序已记录人工目视核对。")


def complete(root):
    manifest, journal = verify(root)
    if journal["state"] != "recovery_pending":
        raise ValueError("未进入待恢复状态")
    expected = {space["label"] for space in manifest["targets"]}
    if set(journal["restored"]) != expected:
        raise ValueError("两个目标 Space 尚未全部核对恢复")
    if manifest["sentinel"] and not journal["sentinel_verified"]:
        raise ValueError("未参与的对照 Space 尚未核对")
    if not journal["screen_saver_verified"]:
        raise ValueError("独立屏幕保护程序尚未核对")
    for entry in (list(journal["restored"].values())
                  + ([journal["sentinel_verified"]] if manifest["sentinel"] else [])
                  + [journal["screen_saver_verified"]]):
        if hash_file(image_path(root, entry["evidence"])) != entry["evidence_sha256"]:
            raise ValueError("恢复后的证据图片发生变化")
    journal["state"] = "completed"
    journal["completed_at"] = now()
    update_journal(root, journal)
    print("恢复核对记录完整；画面内容仍须由操作者与封存截图逐项对照。")


def guide(root):
    manifest, journal = verify(root)
    print("状态: " + journal["state"])
    for space in manifest["targets"] + ([manifest["sentinel"]] if manifest["sentinel"] else []):
        wallpaper = space["wallpaper"]
        print(" | ".join([space["label"], wallpaper["collection"],
                          wallpaper["selected_name"],
                          wallpaper["catalog_item"],
                          "屏保=" + ("开" if wallpaper["show_as_screen_saver"] else "关"),
                          "所有空间=" + ("开" if wallpaper["show_on_all_spaces"] else "关")]))
    screen_saver = manifest["screen_saver"]
    print("独立屏保 | " + screen_saver["selected_name"] + " | 所有空间="
          + ("开" if screen_saver["show_on_all_spaces"] else "关"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("create", "seal", "verify", "begin", "guide", "mark-restored",
                    "mark-sentinel", "mark-screen-saver", "complete"):
        item = sub.add_parser(command)
        item.add_argument("directory", type=Path)
        if command == "create":
            item.add_argument("--display-id", type=int, required=True)
        if command in ("mark-restored", "mark-sentinel"):
            item.add_argument("--space", required=True)
            item.add_argument("--selected-name", required=True)
            item.add_argument("--collection", required=True)
            item.add_argument("--catalog-item", required=True)
            item.add_argument("--screen-saver", choices=("on", "off"), required=True)
            item.add_argument("--all-spaces", choices=("on", "off"), required=True)
            item.add_argument("--other-options-json", default="{}")
            item.add_argument("--evidence", required=True)
        if command == "mark-screen-saver":
            item.add_argument("--selected-name", required=True)
            item.add_argument("--all-spaces", choices=("on", "off"), required=True)
            item.add_argument("--evidence", required=True)
    args = parser.parse_args()
    try:
        root = args.directory.resolve(strict=args.command != "create")
        if args.command == "create":
            if args.display_id <= 0:
                raise ValueError("显示器 ID 必须大于 0")
            create(root, args.display_id)
        elif args.command == "seal":
            seal(root)
        elif args.command == "verify":
            _, journal = verify(root)
            print("恢复清单有效；状态=" + journal["state"])
        elif args.command == "begin":
            begin(root)
        elif args.command == "guide":
            guide(root)
        elif args.command == "mark-restored":
            mark_observed(root, args)
        elif args.command == "mark-sentinel":
            mark_observed(root, args, sentinel=True)
        elif args.command == "mark-screen-saver":
            mark_screen_saver(root, args)
        elif args.command == "complete":
            complete(root)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        parser.exit(2, "recovery: " + str(error) + "\n")


if __name__ == "__main__":
    main()
