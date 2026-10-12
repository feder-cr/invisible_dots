"""Every answer comes back whole: no `max_chars`, no cut, no envelope.

⛔ UNTIL 0.71 THE ANSWERS WERE CUT. `browser_read_text` stopped at 6000
characters with a last line asking the model to raise `max_chars`;
`browser_evaluate` and the browser listing became `{"truncated": true,
"preview": ...}` above the same number; `browser_snapshot` dropped elements from
the end with a hint to raise `max_chars`. A cut answer is one the model acts on
as if it were the page, and asking for a bigger number is a second call for what
the first should have given. The owner's decision, 2026-10-12: answers come back
whole, and a caller who wants less narrows the selector.

Each test below is the known-bad turned around: put the cap back, in any of
the four places, and one of them fails.
"""
from __future__ import annotations

import asyncio
import json

from invisible_playwright_mcp.mcp import actions, server

LONG = "x" * 20000


class _Found:
    def __init__(self, texts):
        self.first = self
        self._texts = texts

    async def all_inner_texts(self):
        return self._texts


class _Page:
    def __init__(self, texts=(), value=None):
        self._texts = list(texts)
        self._value = value
        #: Which door each evaluation went through.
        self.doors = []

    def locator(self, _selector):
        return _Found(self._texts)

    async def evaluate(self, _expression):
        self.doors.append("evaluate")
        return self._value

    async def evaluate_read(self, _expression):
        self.doors.append("evaluate_read")
        return self._value


class _Session:
    def __init__(self, page):
        self._page = page

    def page(self, page_id=None):
        return self._page


def test_a_long_text_comes_back_whole_and_unmarked():
    out = asyncio.run(actions.read_text(_Session(_Page([LONG])), "body"))
    assert out == LONG


def test_a_selector_that_matches_nothing_says_so():
    out = asyncio.run(actions.read_text(_Session(_Page([])), "#nope"))
    assert out == "(no element matches '#nope')"


def test_an_evaluation_comes_back_whole_and_parses():
    value = {"rows": [{"n": i, "text": "row %d" % i} for i in range(2000)]}
    out = asyncio.run(actions.evaluate(_Session(_Page(value=value)), "window.rows"))
    assert json.loads(out) == value
    assert len(out) > 20000


def test_a_snapshot_lists_every_element():
    elements = [{"tag": "a", "selector": "#l%d" % i, "text": "Result %d" % i,
                 "at": [10, 20 * i], "in_view": True} for i in range(500)]
    page = _Page(value={"title": "list", "url": "https://example.com/",
                        "interactive_elements": elements})
    d = json.loads(asyncio.run(actions.snapshot(_Session(page))))
    assert len(d["interactive_elements"]) == 500
    assert "omitted_elements" not in d and "hint" not in d


def test_no_tool_takes_or_mentions_a_cap():
    tools = {t.name: t for t in asyncio.run(server.mcp.list_tools())}
    for name, tool in tools.items():
        assert "max_chars" not in (tool.inputSchema.get("properties") or {}), name
        text = (tool.description or "").lower()
        assert "max_chars" not in text and "cut at" not in text, name
    assert not hasattr(actions, "DEFAULT_MAX_CHARS")
    assert not hasattr(actions, "json_capped")
    assert not hasattr(actions, "capped_elements")


def test_the_reads_ask_evaluate_read_and_the_models_code_asks_evaluate():
    """The snapshot and read_html are reads without effects: read again on the
    page that replaced the one they went to. The model's code is not: it is
    sent once, and a navigation under it is Playwright's error (invisible-
    playwright 0.35.2)."""
    page = _Page(value={"title": "t", "url": "https://example.com/",
                        "interactive_elements": []})
    asyncio.run(actions.snapshot(_Session(page)))
    assert page.doors == ["evaluate_read"]
    page = _Page(value="<html><body><p>x</p></body></html>")
    asyncio.run(actions.read_html(_Session(page), "text"))
    assert page.doors == ["evaluate_read"]
    page = _Page(value=1)
    asyncio.run(actions.evaluate(_Session(page), "1"))
    assert page.doors == ["evaluate"]
