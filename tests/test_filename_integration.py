"""CAP-16/S3 integration through real native processes, including bound formats."""
import base64
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from src.search_platform.schema_check import load_tool_schema, validate

ROOT = Path(__file__).resolve().parents[1]


class FilenameIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.environ.get('SEARCH_SIMPLI_NO_ZIG') == '1':
            raise unittest.SkipTest('native CLI deliberately unavailable')
        cls.build = tempfile.TemporaryDirectory()
        if os.environ.get('SEARCHD_BINARY'):
            cls.binary = Path(os.environ['SEARCHD_BINARY'])
        else:
            subprocess.run(['zig', 'build', '-j2', '--prefix', cls.build.name], cwd=ROOT/'zig', check=True, capture_output=True)
            cls.binary = Path(cls.build.name)/'bin/searchd'

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.corpus = self.root/'corpus'
        self.corpus.mkdir()
        self.text = '# Ledger\nCopper silver evidence.\n'
        (self.corpus/'annual-ledger.md').write_text(self.text)
        self.index = self.root/'index'
        self.call('index', self.corpus, '--out', self.index, '--filename-index')

    def call(self, *args):
        result = subprocess.run([str(self.binary), *map(str,args)], cwd=ROOT, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def rpc(self, params, *flags):
        request = {'jsonrpc':'2.0','id':1,'method':'search_knowledge','params':params}
        result = subprocess.run([str(self.binary),'serve',str(self.index),*flags], input=json.dumps(request)+'\n',text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        value = json.loads(result.stdout)
        self.assertNotIn('error',value)
        return value['result']

    def test_v3_preserves_structure_positions_source_and_tool_schema(self):
        self.assertEqual((self.index/'MANIFEST').read_bytes()[:8], b'HYBMAN03')
        found = json.loads(self.call('find', self.index, 'copper silver', '--mode', 'phrase', '--json'))
        self.assertTrue(found['hits'])
        span = json.loads(self.call('read-span', self.index, 'r-legacy', 'annual-ledger.md', '1','2','--json'))
        self.assertEqual(span['text'],self.text)
        response = self.rpc({'query':'annual','retrieval_mode':'lexical','search_field':'filename'})
        self.assertEqual(validate(response,load_tool_schema('search_knowledge','result')), [])
        self.assertEqual(response['results'][0]['root_id'],'r-legacy')
        self.assertEqual(response['results'][0]['section_path'],['Ledger'])

    def test_refresh_keeps_channel_and_root_scope_precedes_filename_statistics(self):
        text = base64.b64encode(b'# Private\nCopper secret evidence.\n').decode()
        batch = {'roots':[{'root_id':'vault','kind':'host','required_labels':['secret']}],
                 'changes':[{'op':'add','root_id':'vault','path':'annual-hidden.md','content_base64':text}]}
        changes = self.root/'changes.json'
        changes.write_text(json.dumps(batch))
        self.call('apply', self.index, '--changes',changes,'--json')
        request = {'query':'annual','retrieval_mode':'lexical','search_field':'both'}
        public = self.rpc(request)
        self.assertEqual([r['citation']['path'] for r in public['results']],['annual-ledger.md'])
        private = self.rpc(request,'--roots','vault','--labels','secret')
        self.assertEqual([r['citation']['path'] for r in private['results']],['vault/annual-hidden.md'])
        self.assertEqual((self.index/'MANIFEST').read_bytes()[:8],b'HYBMAN03')
        self.assertEqual(validate(private,load_tool_schema('search_knowledge','result')), [])

    def test_bound_catalog_corruption_is_not_silently_accepted(self):
        catalog = next(self.index.glob('filenames-*.hybseg'))
        data = bytearray(catalog.read_bytes()); data[-1] ^= 1; catalog.write_bytes(data)
        result = subprocess.run([str(self.binary),'query',str(self.index),'annual','--search-field','filename'],text=True,capture_output=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Checksum',result.stderr)
