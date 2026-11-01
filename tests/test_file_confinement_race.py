"""Real directory replacement between discovery and open must not escape a root."""
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from src.search_platform.folders import _read_confined


class FileConfinementRaceTests(unittest.TestCase):
    def test_intermediate_component_replaced_by_symlink_is_not_followed(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()/'root'; child = root/'sub'; child.mkdir(parents=True)
            outside = Path(scratch).resolve()/'outside'; outside.mkdir()
            (child/'note.txt').write_bytes(b'allowed')
            (outside/'note.txt').write_bytes(b'outside secret')
            original = os.open
            swapped = False
            def racing_open(path, flags, *args, **kwargs):
                nonlocal swapped
                if path == 'sub' and not swapped:
                    child.rename(root/'old-sub')
                    child.symlink_to(outside,target_is_directory=True)
                    swapped = True
                return original(path,flags,*args,**kwargs)
            with patch('src.search_platform.folders.os.open',side_effect=racing_open):
                with self.assertRaises(OSError):
                    _read_confined(str(root),str(child/'note.txt'))
            self.assertTrue(swapped)
            self.assertEqual((outside/'note.txt').read_bytes(),b'outside secret')

    def test_pinned_directory_survives_name_replacement(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()/'root'; child = root/'sub'; child.mkdir(parents=True)
            outside = Path(scratch).resolve()/'outside'; outside.mkdir()
            (child/'note.txt').write_bytes(b'allowed')
            (outside/'note.txt').write_bytes(b'outside secret')
            original = os.open
            def racing_open(path,flags,*args,**kwargs):
                if path == 'note.txt':
                    child.rename(root/'old-sub')
                    child.symlink_to(outside,target_is_directory=True)
                return original(path,flags,*args,**kwargs)
            with patch('src.search_platform.folders.os.open',side_effect=racing_open):
                self.assertEqual(_read_confined(str(root),str(child/'note.txt')),b'allowed')
