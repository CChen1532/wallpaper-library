#!/usr/bin/env python3
"""Safety gates for the manual wallpaper recovery journal."""

import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("scene-wallpaper-recovery.py")
SPEC = importlib.util.spec_from_file_location("scene_wallpaper_recovery", SCRIPT)
RECOVERY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RECOVERY)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "recovery"
        RECOVERY.create(self.root, 1)

    def put_image(self, name):
        path = self.root / "evidence" / name
        path.write_bytes(b"\x89PNG\r\n\x1a\n" + name.encode() + b"x" * 120)
        return "evidence/" + name

    def ready_manifest(self, space_count=3):
        manifest = RECOVERY.read_json(self.root / RECOVERY.MANIFEST)
        manifest["space_count"] = space_count
        manifest["mission_control_image"] = self.put_image("mission-control.png")
        manifest["screen_saver"] = {
            "selected_name": "OtherWallpaper", "show_on_all_spaces": True,
            "settings_image": self.put_image("screen-saver.png"),
        }
        if space_count > 2:
            manifest["sentinel"] = RECOVERY.template_space("桌面 3", "desktop-3")
        spaces = manifest["targets"] + ([manifest["sentinel"]] if manifest["sentinel"] else [])
        for space in spaces:
            wallpaper = space["wallpaper"]
            wallpaper.update({"selected_name": "默认系统壁纸", "collection": "示例集合",
                              "catalog_item": "默认系统壁纸", "show_as_screen_saver": False,
                              "show_on_all_spaces": False})
            space["settings_image"] = self.put_image(space["label"] + "-settings.png")
            space["desktop_image"] = self.put_image(space["label"] + "-desktop.png")
        (self.root / RECOVERY.MANIFEST).write_text(
            json.dumps(manifest, ensure_ascii=False), encoding="utf-8")

    def observation(self, label):
        return argparse.Namespace(space=label, selected_name="默认系统壁纸",
                                  collection="示例集合", catalog_item="默认系统壁纸",
                                  screen_saver="off", all_spaces="off",
                                  other_options_json="{}",
                                  evidence=self.put_image(label + "-restored.png"))

    def test_incomplete_record_cannot_be_sealed(self):
        with self.assertRaisesRegex(ValueError, "实际编号桌面数"):
            RECOVERY.seal(self.root)
        self.assertFalse((self.root / RECOVERY.SEAL).exists())

    def test_modified_prechange_evidence_blocks_trial(self):
        self.ready_manifest()
        RECOVERY.seal(self.root)
        self.assertEqual(RECOVERY.verify(self.root)[1]["state"], "sealed")
        path = self.root / "evidence" / "mission-control.png"
        path.write_bytes(path.read_bytes() + b"tampered")
        with self.assertRaisesRegex(ValueError, "证据图片发生变化"):
            RECOVERY.begin(self.root)

    def test_shared_desktop_image_requires_explicit_confirmation_and_matching_settings(self):
        self.ready_manifest()
        manifest = RECOVERY.read_json(self.root / RECOVERY.MANIFEST)
        spaces = manifest["targets"] + [manifest["sentinel"]]
        for space in spaces:
            space["desktop_image"] = None
        manifest["shared_desktop_visual"] = {
            "image": self.put_image("shared-desktop.png"),
            "applies_to": [space["label"] for space in spaces],
            "user_confirmed_same_wallpaper": False,
        }
        with self.assertRaisesRegex(ValueError, "须有用户确认"):
            RECOVERY.validate_manifest(self.root, manifest)
        manifest["shared_desktop_visual"]["user_confirmed_same_wallpaper"] = True
        manifest["sentinel"]["wallpaper"]["selected_name"] = "OtherWallpaper"
        with self.assertRaisesRegex(ValueError, "设置不一致"):
            RECOVERY.validate_manifest(self.root, manifest)
        manifest["sentinel"]["wallpaper"]["selected_name"] = "默认系统壁纸"
        (self.root / RECOVERY.MANIFEST).write_text(
            json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
        RECOVERY.seal(self.root)
        self.assertEqual(RECOVERY.verify(self.root)[1]["state"], "sealed")

    def test_pending_state_requires_two_restores_and_sentinel(self):
        self.ready_manifest()
        RECOVERY.seal(self.root)
        RECOVERY.begin(self.root)
        with self.assertRaisesRegex(ValueError, "与封存清单不符"):
            wrong = self.observation("桌面 1")
            wrong.selected_name = "另一张壁纸"
            RECOVERY.mark_observed(self.root, wrong)
        RECOVERY.mark_observed(self.root, self.observation("桌面 1"))
        with self.assertRaisesRegex(ValueError, "两个目标 Space"):
            RECOVERY.complete(self.root)
        RECOVERY.mark_observed(self.root, self.observation("桌面 2"))
        with self.assertRaisesRegex(ValueError, "对照 Space"):
            RECOVERY.complete(self.root)
        RECOVERY.mark_observed(self.root, self.observation("桌面 3"), sentinel=True)
        with self.assertRaisesRegex(ValueError, "屏幕保护程序"):
            RECOVERY.complete(self.root)
        RECOVERY.mark_screen_saver(self.root, argparse.Namespace(
            selected_name="OtherWallpaper", all_spaces="on",
            evidence=self.put_image("screen-saver-restored.png")))
        RECOVERY.complete(self.root)
        self.assertEqual(RECOVERY.verify(self.root)[1]["state"], "completed")
        restored = self.root / "evidence" / "桌面 1-restored.png"
        restored.write_bytes(restored.read_bytes() + b"tampered")
        with self.assertRaisesRegex(ValueError, "恢复后的证据图片发生变化"):
            RECOVERY.verify(self.root)


if __name__ == "__main__":
    unittest.main()
