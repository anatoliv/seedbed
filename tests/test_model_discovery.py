import json
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

from promptlib import model_discovery as discovery


class ModelDiscoveryTests(unittest.TestCase):
    def test_cli_clear_sources_really_removes_saved_guidance(self):
        from promptlib.cli import main
        from promptlib.guides import load_registry
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            registry = root / 'models.toml'
            registry.write_text('[models.sample]\nname="Sample"\nguides=["https://example.org/guide"]\n')
            with redirect_stdout(StringIO()):
                self.assertEqual(main(['--root', folder, 'model', 'set', 'sample', '--clear-guides']), 0)
            self.assertEqual(load_registry(registry)['sample'].guides, [])

    def test_corrupt_cached_catalog_is_replaced(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            cache = root / '.cache/model-catalog.json'
            cache.parent.mkdir()
            cache.write_text('["invalid"]')
            data = {'openai': {'models': {'gpt-new': {
                'release_date': '2026-01-01', 'modalities': {'output': ['text']}}}}}
            with patch.object(discovery, 'read_url', return_value=json.dumps(data)):
                self.assertFalse(discovery.suggestions(root)['cached'])

    def test_recent_text_models_exclude_deprecated_audio_aliases_and_snapshots(self):
        def model(released, outputs=['text'], status=None):
            return dict(name='Example', release_date=released,
                        modalities={'output': outputs}, status=status)
        data = {'openai': {'models': {
            'gpt-new': model('2026-09-01'), 'gpt-old': model('2025-01-01'),
            'gpt-gone': model('2026-09-02', status='deprecated'),
            'audio': model('2026-09-03', ['audio']),
            'gpt-latest': model('2026-09-04'),
            'gpt-20260901': model('2026-09-01'),
            'gpt-future': model('2099-01-01'), '../bad': model('2026-09-01')}}}
        self.assertEqual([m['id'] for m in discovery.catalog_models(data)], ['gpt-new', 'gpt-old'])

    def test_catalog_keeps_last_good_refresh_and_reports_offline(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            data = {'openai': {'models': {'gpt-new': {
                'name': 'GPT New', 'release_date': '2026-01-01',
                'modalities': {'output': ['text']}}}}}
            with patch.object(discovery, 'read_url', return_value=json.dumps(data)):
                first = discovery.suggestions(root, refresh=True)
            with patch.object(discovery, 'read_url', side_effect=OSError('offline')):
                result = discovery.suggestions(root, refresh=True)
                cached = discovery.suggestions(root)
            self.assertEqual(result['models'], first['models'])
            self.assertTrue(result['cached'])
            self.assertIn('offline', result['warning'])
            self.assertEqual(cached['updated'], first['updated'])

    def test_discovery_matches_official_model_links_and_never_guesses_paths(self):
        html = '''<a href="/api/docs/models/gpt-new">Model</a>
                  <a href="https://other.example/gpt-new">Wrong host</a>
                  <a href="/api/docs/models/gpt-newer">Different model</a>'''
        with patch.object(discovery, 'read_url', return_value=html):
            result = discovery.documentation('gpt-new', 'GPT New', 'openai')
        urls = [s['url'] for s in result['sources']]
        self.assertIn('https://developers.openai.com/api/docs/models/gpt-new', urls)
        self.assertEqual(len(urls), 2)
        self.assertFalse(any('other.example' in url or 'gpt-newer' in url for url in urls))

    def test_unknown_vendor_does_not_fetch_or_invent_documentation(self):
        with patch.object(discovery, 'read_url') as read:
            result = discovery.documentation('private-model', 'My model', 'custom')
        read.assert_not_called()
        self.assertEqual(result['sources'], [])
        self.assertTrue(result['warning'])

    def test_missing_vendor_pages_return_actionable_status(self):
        with patch.object(discovery, 'read_url', side_effect=OSError('offline')):
            result = discovery.documentation('claude-opus', 'Claude Opus', 'claude')
        self.assertEqual(result['sources'], [])
        self.assertIn('Could not check', result['warning'])

    def test_dated_claude_id_matches_undated_doc_slug(self):
        html = '<a href="/docs/en/models/claude-haiku-4-5">Haiku</a>'
        with patch.object(discovery, 'read_url', return_value=html):
            result = discovery.documentation('claude-haiku-4-5-20251001', '', 'claude')
        self.assertTrue(any(s['url'].endswith('claude-haiku-4-5') for s in result['sources']))
