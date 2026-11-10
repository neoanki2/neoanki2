#!/usr/bin/env python3
"""Freshness boundary tests without launching or modifying any real container."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
s=importlib.util.spec_from_file_location('review',Path(__file__).with_name('review-macos-app.py'));m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class FreshContainerTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.path=Path(self.temp.name)/'container'
 def test_absent_and_installer_created_empty_are_fresh(self):
  self.assertEqual(m.fresh_container_baseline(self.path)['state'],'absent')
  (self.path/'Data/Library/Application Support').mkdir(parents=True)
  (self.path/'.com.apple.containermanagerd.metadata.plist').write_bytes(b'protected macOS metadata')
  result=m.fresh_container_baseline(self.path)
  self.assertEqual(result['state'],'installer-created-empty');self.assertFalse(result['regular_files'][0]['contents_inspected'])
 def test_existing_library_or_preferences_never_count_as_fresh(self):
  for name in ('Data/Library/Application Support/NeoAnki2/library.sqlite','Data/Library/Preferences/com.neoanki2.ios.plist'):
   with self.subTest(name=name):
    p=self.path/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b'existing user state')
    with self.assertRaisesRegex(m.mac.ReleaseError,'existing app state'):m.fresh_container_baseline(self.path)
    p.unlink()
 def test_shared_folder_links_are_not_followed(self):
  outside=Path(self.temp.name)/'documents';outside.mkdir();(outside/'private.txt').write_text('never read')
  (self.path/'Data').mkdir(parents=True);(self.path/'Data/Documents').symlink_to(outside,target_is_directory=True)
  result=m.fresh_container_baseline(self.path);self.assertIn('Data/Documents',result['symlinks']);self.assertEqual(result['regular_files'],[])
 def test_redirected_app_storage_is_rejected(self):
  self.path.mkdir();(self.path/'Data').symlink_to(Path(self.temp.name),target_is_directory=True)
  with self.assertRaisesRegex(m.mac.ReleaseError,'redirected'):m.fresh_container_baseline(self.path)
 def test_unreadable_app_directory_does_not_silently_pass(self):
  self.path.mkdir()
  def denied(*args,**kwargs):kwargs['onerror'](PermissionError('denied'));return iter(())
  with patch.object(m.os,'walk',side_effect=denied),self.assertRaisesRegex(m.mac.ReleaseError,'Cannot inspect'):m.fresh_container_baseline(self.path)
if __name__=='__main__':unittest.main()
