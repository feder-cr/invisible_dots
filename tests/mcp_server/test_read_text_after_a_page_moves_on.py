"""`browser_read_text` right after `browser_navigate`, on pages that replace
themselves, in a browser.

⛔ THE KNOWN-BAD INPUT, from the invisible_dots VMs (2026-10-12): a read right
after navigating to a page that calls `location.replace` 50 ms after `load`
failed with the engine's raw "Failed to find execution context" 9 times in 10.
`read_text` found the element with one call and read it with a second, and the
page moved on between them. It finds and reads in one call now, and from
invisible-playwright 0.35.0 a call caught by the move is made again on the page
that took its place.

The pages: a redirect from the `<head>`, and 0, 50 and 300 ms after `load`,
each to the same site and to another one (127.0.0.1 to localhost, which the
browser puts in another process). Five rounds each: a race missed once in five
is still a race. A selector that matches nothing still says so at once.

⛔ AND THE SNAPSHOT AND READ_HTML, EACH AS THE FIRST READ AFTER THE NAVIGATION.
They run their own fixed reads in the page's world; until invisible-playwright
0.35.2 they went through `page.evaluate`, which from 0.35.2 sends the code once
and raises Playwright's navigation error when the page moves under it (the
model's code must not run twice, [B285]). They ask `page.evaluate_read`, which
reads again on the page that replaced the one they went to.

⛔ AND THE SAME REPORT'S 45 s `browser_navigate`. Each round navigates while
the previous page's own `location.replace` may be in flight, and Firefox lets
that one win: ours is never heard of again, no commit and no abort. The wait
used to run to the timeout; since invisible-core 41.36.0 the first document
committed after the command decides, and when it is not ours the navigation
answers at once with upstream Playwright's "is interrupted by another
navigation to", naming the page the browser went to. A round may end that
way. It may not take long, and the read after it still answers with the page.
"""
from __future__ import annotations

import asyncio
import http.server
import threading
import time

import pytest

from invisible_playwright_mcp.mcp import actions

ROUNDS = 5
LANDED = b"<!doctype html><html><body><p id=p>LANDED-TEXT</p></body></html>"


def _after_load(ms: int, cross_site: bool) -> bytes:
    target = ("location.origin.replace('127.0.0.1','localhost')+'/landed'"
              if cross_site else "'/landed'")
    return (("<!doctype html><html><body><p id=p>FIRST-TEXT</p><script>"
             "addEventListener('load', () => setTimeout(() => "
             "location.replace(%s), %d))</script></body></html>")
            % (target, ms)).encode()


PAGES = {
    "/head": (b"<!doctype html><html><head><script>location.replace('/landed')"
              b"</script></head><body><p id=p>FIRST-TEXT</p></body></html>"),
    "/landed": LANDED,
}
for _ms in (0, 50, 300):
    PAGES["/r%d" % _ms] = _after_load(_ms, False)
    PAGES["/x%d" % _ms] = _after_load(_ms, True)


def _serve():
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = PAGES.get(self.path.split("?")[0], LANDED)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, "http://127.0.0.1:%d" % srv.server_address[1]


@pytest.fixture(scope="module")
def reads():
    """Every page, five rounds, read at once after navigating: the answers."""
    from invisible_playwright_mcp.mcp.plan import plan_session
    from invisible_playwright_mcp.mcp.session import StealthSession

    srv, base = _serve()

    async def run():
        session = StealthSession(**plan_session().kwargs)
        out = {}
        try:
            await session.start()
            for path in ("/head", "/r0", "/r50", "/r300", "/x0", "/x50", "/x300"):
                for i in range(ROUNDS):
                    # Each step on its own: a navigation that fails must fail
                    # this page's test, not the whole file, and the read runs
                    # whatever the navigation answered.
                    began = time.monotonic()
                    try:
                        went = await actions.navigate(session, "%s%s?i=%d" % (base, path, i))
                    except Exception as exc:  # noqa: BLE001 - the test reads it
                        went = "raised %s: %s" % (type(exc).__name__, exc)
                    took = time.monotonic() - began
                    try:
                        got = await actions.read_text(session, "#p")
                    except Exception as exc:  # noqa: BLE001 - the test reads it
                        got = "raised %s: %s" % (type(exc).__name__, exc)
                    out.setdefault(path, []).append((went, took, got))
            # Each read first after its own navigation: a read that follows
            # another one meets a page that has had time to settle.
            for kind, read in (("snapshot", lambda: actions.snapshot(session)),
                               ("read_html", lambda: actions.read_html(session, "text"))):
                for path in ("/head", "/r0", "/r50", "/r300", "/x0", "/x50", "/x300"):
                    for i in range(ROUNDS):
                        try:
                            await actions.navigate(session, "%s%s?%s=%d"
                                                   % (base, path, kind, i))
                        except Exception:  # noqa: BLE001 - the read is the point
                            pass
                        try:
                            got = await read()
                        except Exception as exc:  # noqa: BLE001 - the test reads it
                            got = "raised %s: %s" % (type(exc).__name__, exc)
                        out.setdefault((kind, path), []).append(got)
            out["miss"] = await actions.read_text(session, "#nothing-here")
        finally:
            await session.close()
        return out

    try:
        yield asyncio.run(run())
    finally:
        srv.shutdown()


@pytest.mark.e2e
@pytest.mark.parametrize("path", ["/head", "/r0", "/r50", "/r300", "/x0", "/x50", "/x300"])
def test_a_read_right_after_navigate_answers_with_the_page(reads, path):
    """Known-bad: count() then first.evaluate(), and the page moving on between
    them - the read raised "Failed to find execution context". The answer is
    of the page as it is at that moment: either document's text, or, when the
    read lands in the replacing document before its parser reached the
    paragraph, the honest "no element matches"."""
    for _went, _took, got in reads[path]:
        assert (got in ("FIRST-TEXT", "LANDED-TEXT")
                or got.startswith("(no element matches")), got


@pytest.mark.e2e
@pytest.mark.parametrize("path", ["/head", "/r0", "/r50", "/r300", "/x0", "/x50", "/x300"])
def test_a_navigation_answers_at_once_even_when_the_previous_page_wins(reads, path):
    """Known-bad: number the navigations by when they were first seen, and the
    previous page's redirect, seen before ours, is never accepted in its
    place: `browser_navigate` waited the full 45 s for a document that was
    never coming. It answers with where it went, or with the interruption
    and the page that won, and in seconds."""
    for went, took, _got in reads[path]:
        assert (went.startswith("navigated to ")
                or ("is interrupted by another navigation to" in went
                    and "/landed" in went)), went
        assert took < 10, (took, went)


@pytest.mark.e2e
def test_a_selector_that_matches_nothing_still_says_so(reads):
    assert "no element matches" in reads["miss"]


@pytest.mark.e2e
@pytest.mark.parametrize("path", ["/head", "/r0", "/r50", "/r300", "/x0", "/x50", "/x300"])
def test_a_snapshot_right_after_navigate_answers_with_the_page(reads, path):
    """A snapshot is a read: the page moving on under it is read again, and it
    never surfaces "Execution context was destroyed"."""
    import json
    for got in reads[("snapshot", path)]:
        assert not got.startswith("raised"), got
        d = json.loads(got)
        assert path in d["url"] or "/landed" in d["url"], d["url"]


@pytest.mark.e2e
@pytest.mark.parametrize("path", ["/head", "/r0", "/r50", "/r300", "/x0", "/x50", "/x300"])
def test_read_html_right_after_navigate_answers_with_the_page(reads, path):
    """read_html is a read too. Its text is of either document, or empty when
    the read lands in the replacing document before its parser reached the
    paragraph; it is never the navigation error."""
    for got in reads[("read_html", path)]:
        assert not got.startswith("raised"), got
        assert ("FIRST-TEXT" in got or "LANDED-TEXT" in got
                or "TEXT" not in got), got
