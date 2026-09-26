from __future__ import annotations

import importlib.util
import tempfile
import unittest
import urllib.error
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "check-docs-external-links.py"
SPEC = importlib.util.spec_from_file_location("check_docs_external_links", SCRIPT)
assert SPEC and SPEC.loader
links = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(links)


class ExternalURLTests(unittest.TestCase):
    def test_extracts_public_links_and_strips_markdown_punctuation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "guide.md").write_text(
                "Public: `https://example.org/guide`.\n"
                "Local: `http://127.0.0.1:8766`.\n"
                "Reserved: https://service.example/problem.\n"
                "Template: https://github.com/org/repo/{{ revision }}/file.\n",
                encoding="utf-8",
            )

            self.assertEqual(
                links.external_urls(root), {"https://example.org/guide"}
            )

    def test_rejects_private_and_malformed_targets(self) -> None:
        rejected = (
            "http://localhost:8766/health",
            "http://10.0.0.1/status",
            "http://[::1]/status",
            "https://neoanki.example/problem",
            "http://example.org:bad-port/",
        )
        for url in rejected:
            with self.subTest(url=url):
                self.assertFalse(links.is_public_http_url(url))

    def test_retries_transient_failures(self) -> None:
        calls = 0

        class Response:
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

        def open_url(*_, **__):
            nonlocal calls
            calls += 1
            if calls < 3:
                raise urllib.error.URLError("temporary")
            return Response()

        self.assertIsNone(
            links.check(
                "https://example.org/guide",
                open_url=open_url,
                sleep=lambda _: None,
            )
        )
        self.assertEqual(calls, 3)

    def test_reports_permanent_http_failure_without_retrying(self) -> None:
        calls = 0

        def open_url(request, **_):
            nonlocal calls
            calls += 1
            raise urllib.error.HTTPError(
                request.full_url, 404, "Not Found", {}, None
            )

        self.assertEqual(
            links.check(
                "https://example.org/missing",
                open_url=open_url,
                sleep=lambda _: None,
            ),
            "https://example.org/missing: HTTP 404",
        )
        self.assertEqual(calls, 1)


if __name__ == "__main__":
    unittest.main()
