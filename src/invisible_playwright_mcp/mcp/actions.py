"""The browser operations, as plain functions over a session.

This module is the only implementation. The MCP tools in `server.py` are a thin
wrapper over it, and anything else that drives the browser - the built-in chat,
a test, a script - calls the same functions rather than reimplementing them.

That constraint is the point of the file. A second path to the page would give
two behaviours to keep in step, and they would drift: the tool would grow a
timeout the chat never got, the chat would grow a retry the tool never got, and
the difference would surface as a bug report nobody could reproduce.

Nothing here knows what MCP is, or what a session id is. It takes a session and
acts on it.
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import stat
import tempfile

from . import clean, process
from ..quiet import swallow

# ⛔ NO CAP ON ANY ANSWER, since 0.72.0. `DEFAULT_MAX_CHARS` (6000) cut the
# text a read returned, `json_capped` the value of an evaluation and the list of
# browsers, `capped_elements` the snapshot's elements, each with a marker
# telling the model to raise `max_chars`. A cut answer is an answer the model
# acts on as if it were the page, and asking it to raise a number is a second
# call to get what the first should have given: the owner's decision is that
# answers come back whole. A caller who wants less narrows the selector.


# --- pages -----------------------------------------------------------------

# ⛔ `new_page`, `list_pages`, `select_page` and `close_page` STOOD HERE. They
# were one line each over the same method on the session, and their only
# callers were the four tab tools, which are gone. `navigate` opens the first
# page itself, through `session.new_page()`, so nothing in this module needs
# them any more.


# --- reading ---------------------------------------------------------------

#: How long `browser_navigate` gives a page to answer: the longest any tool here
#: waits inside one call, and so also the bound `Work.typing` answers within.
NAVIGATION_TIMEOUT_MS = 45_000


async def navigate(session, url: str, wait_until: str = "domcontentloaded") -> str:
    """Go to a url, and say what came back.

    ⛔ IT USED TO ANSWER `navigated to {url}` WHATEVER HAPPENED, and both halves
    of that were capable of being untrue. A page that answered 404, 403 or 500
    got the same sentence as one that answered 200, so a model reading the reply
    had no way to tell a missing page from a real one and would go on to read an
    error document as content. And after a redirect the url in the sentence was
    the one ASKED FOR, not the one landed on, which is the same defect as the
    silent cut `read_text` used to do: a caller cannot see what it is not told.

    Both halves are now read off the Response. The status is the server's own
    verdict, and the url is `response.url`, which is where the redirect chain
    actually ended.

    ⛔ AND THIS IS WHY `pyproject.toml` FLOORS `invisible-playwright` AT 0.13.2,
    not at 0.13.0. Below that version `goto` answered `None` on every navigation
    ([B200] in the engine's docs), so this function would report "no HTTP
    response" for every page in the world - which is worse than the sentence it
    replaces, because it is a confident and wrong statement rather than a vague
    one. The floor is load-bearing, not hygiene.
    """
    if not session.pages():
        await session.new_page()
    page = session.page()
    response = await page.goto(url, wait_until=wait_until, timeout=NAVIGATION_TIMEOUT_MS)
    if response is None:
        # A same-document navigation (an anchor, or the same url again) creates
        # no document and so has no response. Playwright answers None here and
        # so do we: naming the reason keeps it from reading as a failure.
        return f"navigated to {page.url} (no HTTP response: same-document navigation)"
    return f"navigated to {response.url} (HTTP {response.status})"


async def read_text(session, selector: str = "body") -> str:
    """The visible text of an element, whole.

    ⛔ THE SELECTOR IS RESOLVED BY THE ENGINE, AS EVERY OTHER TOOL RESOLVES IT.
    It was `document.querySelector`, which knows neither a shadow root nor
    Playwright's own syntax, so the `:nth-match(...)` handles the snapshot builds
    for exactly this purpose failed here while the same string clicked: one of
    ten failed reads in the saved runs of invisible_dots (2026-10-10) was a
    selector the click tools would have taken. `DIAGNOSE_JS` was moved off
    `querySelectorAll` for the same reason on 2026-09-30.

    ⛔ FOUND AND READ IN ONE CALL. It was `count()` and then
    `first.evaluate(...)`: two calls with a navigation able to fall between them,
    and right after `browser_navigate` on a page that replaces itself (a
    redirect, a JavaScript challenge) the read failed with "Failed to find
    execution context" - 9 in 10 in the invisible_dots VMs on a page that
    redirects 50 ms after load (2026-10-12). `all_inner_texts()` is one call of
    values that finds and reads together, and from invisible-playwright 0.35.0
    a page that moved on under it is read again on the page that took its
    place. It answers NOW: nothing matching is still "(no element matches ...)"
    at once, not a wait to the timeout, because the caller deciding whether to
    look again is the agent, which has just been told what is there.
    """
    texts = await session.page().locator(selector).first.all_inner_texts()
    if not texts:
        return f"(no element matches {selector!r})"
    return texts[0]


#: Where an element sits, as a string that names it and nothing else: its
#: position among its parent's children at every level up to the document,
#: with `s` where the climb crosses out of a shadow root to its host. The
#: snapshot computes it for an element, and `_resolve_nth` for each element
#: Playwright finds, so the two can be compared without writing to the page.
_PATH_JS = """
    function pathOf(el) {
        const steps = [];
        let node = el;
        while (node && node !== document) {
            const parent = node.parentNode;
            if (!parent) break;
            steps.push(Array.prototype.indexOf.call(parent.children || parent.childNodes, node));
            if (parent instanceof ShadowRoot) { steps.push('s'); node = parent.host; }
            else node = parent;
        }
        return steps.join('/');
    }
"""


async def _resolve_nth(page, elements: list) -> None:
    """Number each element whose selector the snapshot found ambiguous, with
    the position taken from Playwright's own engine: ``:nth-match(sel, n)`` in
    the document, ``sel >> nth=k`` inside a shadow root.

    The snapshot cannot know the order in which the engine lists the matches,
    and must not guess it: a wrong guess clicks another element and reports
    success. So it hands over the element's path and the selector, and here the
    engine lists the paths of what it finds, in its order. One call per
    distinct ambiguous selector. An element the engine does not find loses its
    selector: a missing selector sends the caller to the coordinates, a wrong
    one does not.
    """
    async def order_of(selector):
        try:
            return await page.locator(selector).evaluate_all(PATHS_OF_JS)
        except Exception:  # noqa: BLE001 - the selector stays out, not the snapshot
            return []

    # Asked together: each answer is a round trip to the engine. Measured on a
    # page of 600 elements with 150 ambiguous selectors: one after another they
    # added 630 ms to a 70 ms snapshot, together 300 ms. They only read, so
    # their order does not matter. One question for all of them would mean
    # relying on how the engine orders a selector LIST, which is the guess
    # about its internals this function exists to stop making.
    selectors = ambiguous_selectors(elements)
    found = await asyncio.gather(*(order_of(s) for s in selectors))
    number_matches(elements, dict(zip(selectors, found)))


#: Run by the engine on what it finds for a selector: their paths, in its order.
PATHS_OF_JS = "els => {" + _PATH_JS + " return els.map(pathOf); }"


def ambiguous_selectors(elements: list) -> list:
    """The selectors the snapshot could not number, once each, in order."""
    return list(dict.fromkeys(e["selector"] for e in elements if "_nth_path" in e))


def number_matches(elements: list, orders: dict) -> None:
    """Number each ambiguous element from ``orders`` (selector -> the paths the
    engine found, in its order). Pure, so the sync tests and the tool share it."""
    for e in elements:
        if "_nth_path" not in e:
            continue
        selector = e["selector"]
        order = orders.get(selector) or []
        path, kind = e.pop("_nth_path"), e.pop("_nth_kind", "chain")
        if path not in order:
            del e["selector"]
        elif kind == "match":
            e["selector"] = ":nth-match(%s, %d)" % (selector, order.index(path) + 1)
        else:
            e["selector"] = "%s >> nth=%d" % (selector, order.index(path))


#: ⛔ THE SELECTOR COMES FROM `clean.py` AND IS NOT WRITTEN HERE. It was a
#: hand-typed list of seven roles beside a declaration of nineteen, in another
#: module, in a language where nothing could compare them - so they drifted,
#: and the measured cost is in the comment beside `CONTROL_ROLES`.
#:
#: Joined by CONCATENATION, never by substituting a placeholder into this
#: block: a placeholder searched for inside code is found inside the caller's
#: code too. This file holds 12 literal `%` characters, so a format string over
#: it would not survive either - two independent reasons for the same shape.
SNAPSHOT_JS = """() => {
    // Read only. Numbering the elements would mean writing an attribute into
    // the page, which is a detection surface in a product that exists not to
    // have one. If a stable index is ever wanted, it gets decided in the open.
    const SEL = """ + json.dumps(clean.SNAPSHOT_CSS) + """;
""" + clean.STYLE_HIDES_JS + clean.LABELLED_CONTROL_JS + clean.SECRET_FIELD_JS + """

    // offsetParent used to stand in for "visible" and was wrong both ways: it is
    // null on every position:fixed element - the cookie banner, the sticky bar,
    // the button inside a modal - and it says nothing about visibility:hidden or
    // about an element parked at left:-9999px.
    // How many elements could not be measured at all. It is REPORTED, and that
    // is the whole point of counting it.
    //
    // The first version of this guard just returned false, which turned a loud
    // failure into a silent one: a page that replaces
    // Element.prototype.getBoundingClientRect - the exact threat the comment
    // below names - made shown() answer false for EVERY element, and the tool
    // returned an empty list with no error, byte-identical to a page that
    // genuinely has no controls. That is worse than the crash it replaced,
    // because the crash at least named its cause.
    //
    // With the count, the two cases separate on sight: one odd element leaves
    // 199 results and `unmeasurable: 1`, while a shadowed prototype leaves zero
    // results and `unmeasurable: 412`.
    let unmeasurable = 0;

    function shown(el) {
        // getBoundingClientRect can fail to give a rectangle on a real page:
        // measured on one, the snapshot died with "can't access property
        // width, r is undefined" and the caller got NOTHING for the whole
        // document. A page can shadow or replace this method, and some do.
        // One odd element must not cost the other two hundred.
        let r = null;
        try { r = el.getBoundingClientRect(); } catch (err) { unmeasurable++; return false; }
        if (!r || typeof r.width !== 'number') { unmeasurable++; return false; }
        if (r.width <= 0 || r.height <= 0) return false;
        const s = getComputedStyle(el);
        if (s.visibility === 'hidden' || s.display === 'none') return false;
        // Transparent is hidden, unless it is a control a shown label names:
        // see clean.LABELLED_CONTROL_JS.
        if (transparent(s) && !labelledControl(el)) return false;
        if (el.disabled === true) return false;
        // Parked off-canvas to the left or above: the ordinary way to hide
        // something without hiding it. Below the fold is NOT excluded, because
        // the page may simply be long and that content is still real.
        if (r.right <= 0 || r.bottom <= 0) return false;
        // Clipped to nothing. This is how a "skip to content" link hides until
        // it is focused, and it is the same kind of invisible as
        // visibility:hidden two lines up - the rule this function already
        // applies, just written a different way in CSS.
        //
        // Measured: two of three failed clicks on real pages were skip links
        // reported as visible. Playwright spends its whole timeout on one, 208
        // attempts over 15 seconds, and hands back an opaque failure. Reporting
        // an element nobody can click is not information, it is a trap.
        //
        // ⛔ NOT for form controls, and that exception is the whole difficulty.
        // A file input and a custom checkbox are hidden by exactly this markup
        // on an enormous share of the web - the visible affordance is a styled
        // <label> over the top - and they stay fully operable: Playwright can
        // check() and set_input_files() them, and a click on the label reaches
        // them. Excluding those would cost an agent the ability to tick a
        // consent box or upload a file, which is a worse loss than the skip
        // link this rule exists to remove. A skip link is an <a>.
        const control = /^(input|select|textarea|button)$/.test(el.tagName.toLowerCase());
        if (!control) {
            if (s.clipPath && /inset\\(\\s*(?:50|100)%/.test(s.clipPath)) return false;
            if (s.clip && /rect\\(\\s*0(?:px)?[,\\s]/.test(s.clip)) return false;
            if (r.width <= 1 && r.height <= 1 && s.overflow === 'hidden') return false;
        }
        return true;
    }

    // There is no cap on how many elements come back. A cap is a guess about
    // what the caller needs, made without knowing what it is looking for, and a
    // form's submit button is exactly the sort of thing that sits past it. What
    // is controlled instead is the weight of each element: measured on real
    // pages, href alone was 46% of the payload, so what gets dropped is what
    // carries no information rather than what happens to come last.
    // What a <select> is SET TO, which is the one thing its text cannot say:
    // innerText on a menu is every option concatenated, so a country picker
    // reads the same before and after it is chosen.
    function chosen(el) {
        return [...el.selectedOptions].map(o => o.text).join(', ');
    }

    function useful(h) {
        if (!h) return undefined;
        if (h === '#' || h.startsWith('javascript:')) return undefined;
        return h;
    }

    // A handle that reaches ONE element, and the reason it exists is measured.
    // Across 958 elements on real pages, 88.3% carried id, name or href and
    // every one of those reached the right node - but only 47.6% reached it
    // ALONE. For the other 41% the obvious selector matches several nodes, and
    // Playwright acts on the first, so a model looking at the third of five
    // identical links clicks the first and is told it succeeded. Nothing fails
    // and nothing is logged: it just quietly does the wrong thing.
    //
    // `:nth-match(sel, n)` is Playwright's own syntax and it resolves through
    // this engine, verified rather than assumed. The matches are counted over
    // the whole document, not over this list, because an element filtered out
    // here for being invisible still occupies a position.
    //
    // WHAT `sel` finds searched from `host` (the document, or a shadow host),
    // piercing open shadow roots as Playwright's CSS engine does. Only the SET:
    // whether a selector is unique, and whether this element is among its
    // matches, do not depend on the order of a search. WHICH position it holds,
    // the `n` of `:nth-match` or the `k` of `>> nth=`, is asked of the engine in
    // `_resolve_nth`. ⛔ Until 0.70.13 both were this file's own guesses: the
    // document case counted with document.querySelectorAll, which stops at
    // every shadow boundary, so `[aria-label='X']` was "unique" while the
    // engine found a second one inside a component; and the shadow case
    // transcribed the engine's order by hand.
    function piercedSet(host, sel) {
        const found = new Set();
        function query(root) {
            for (const e of root.querySelectorAll(sel)) found.add(e);
            if (root.shadowRoot) query(root.shadowRoot);
            for (const e of root.querySelectorAll('*')) if (e.shadowRoot) query(e.shadowRoot);
        }
        try { query(host); } catch (err) { return new Set(); }
        return found;
    }""" + _PATH_JS + """
    function cssq(s) { return (window.CSS && CSS.escape) ? CSS.escape(s) : s.replace(/[^\\w-]/g, '\\\\$&'); }
    // Single quotes inside the selector, because this string is about to be
    // serialized as JSON and every double quote in it would come back as two
    // characters. CSS accepts either.
    function attr(s) { return String(s).replace(/\\\\/g, '\\\\\\\\').replace(/'/g, "\\\\'"); }
    function handle(el, href) {
        let base = null, fromHref = false;
        if (el.id) base = '#' + cssq(el.id);
        else if (el.name) base = el.tagName.toLowerCase() + "[name='" + attr(el.name) + "']";
        else if (href) { base = "a[href='" + attr(href) + "']"; fromHref = true; }
        // The two below are APPENDED to the order rather than woven into it, so
        // no selector that already worked changes and the risk of regressing
        // the 88% is zero. They exist because 9.5% of elements had no handle at
        // all and fell back on coordinates, which go stale the moment the page
        // scrolls: of those, 58% carried a data-testid - an attribute whose
        // whole purpose is to be a stable unique handle - and a further quarter
        // an aria-label that was unique on the page.
        else {
            const dt = el.getAttribute('data-testid') || el.getAttribute('data-test')
                    || el.getAttribute('data-qa') || el.getAttribute('data-cy');
            if (dt) {
                const which = el.getAttribute('data-testid') ? 'data-testid'
                            : el.getAttribute('data-test') ? 'data-test'
                            : el.getAttribute('data-qa') ? 'data-qa' : 'data-cy';
                base = '[' + which + "='" + attr(dt) + "']";
            } else {
                const al = el.getAttribute('aria-label');
                if (al) base = "[aria-label='" + attr(al) + "']";
            }
        }
        if (!base) return null;
        // ⛔ INSIDE A SHADOW ROOT the document cannot see the element, so a
        // selector searched from the document by querySelectorAll cannot be
        // checked for uniqueness there, and the page's own tools would say it
        // matches nothing. Measured 2026-09-30 on a real form whose
        // every field is an <input> inside an open shadow root of a custom
        // element (<x-textfield id="firstName">): the snapshot listed none of
        // them. The handle is the HOST's handle, then `>>`, then this
        // element's handle searched from the host - Playwright's own chaining,
        // which pierces open roots - so `#firstName >> #input`.
        const root = el.getRootNode ? el.getRootNode() : document;
        if (root && root !== document && root.host) {
            const outer = handle(root.host, undefined);
            if (!outer) return null;
            const inner = piercedSet(root.host, base);
            if (!inner.has(el)) return null;
            const chained = outer.sel + ' >> ' + base;
            if (inner.size === 1) return {sel: chained, fromHref: fromHref};
            // Ambiguous: the position is the engine's to say (`_resolve_nth`).
            return {sel: chained, fromHref: fromHref, nthPath: pathOf(el), nthKind: 'chain'};
        }
        const all = piercedSet(document, base);
        if (!all.has(el)) return null;
        if (all.size === 1) return {sel: base, fromHref: fromHref};
        return {sel: base, fromHref: fromHref, nthPath: pathOf(el), nthKind: 'match'};
    }

    // No deduplication. It looked free - the same link in the header and in
    // the footer - and it is not: two buttons with the same text and no id are
    // two different places on the screen, and on a results page they are "add
    // to cart" repeated once per product. Measured on the same DOM, in the same
    // instant: it removed 8.1% of the elements to save 13% of the weight. An
    // element the model cannot see is an element it cannot click, which is the
    // character cap wearing a different name.
    const seen = new Set();
    const out = [];
    // The body is wrapped because one element must never cost the page. A real
    // page killed the whole snapshot from inside getBoundingClientRect, and the
    // caller received nothing at all - which is worse than any partial answer,
    // and indistinguishable from a page with no controls on it.
    // Every control in the document AND in every open shadow root under it.
    // `document.querySelectorAll` stops at each shadow boundary, so a page
    // built from web components - the form above - reported two
    // radios and a link and none of its fields. A closed root is left alone:
    // `shadowRoot` is null for it here, as it is for the page's own scripts.
    function everyControl() {
        const found = [];
        function visit(root) {
            for (const e of root.querySelectorAll(SEL)) found.push(e);
            for (const e of root.querySelectorAll('*')) if (e.shadowRoot) visit(e.shadowRoot);
        }
        visit(document);
        return found;
    }
    for (const el of everyControl()) {
      try {
        if (seen.has(el)) continue;
        seen.add(el);
        if (!shown(el)) continue;
        const r = el.getBoundingClientRect();
        const isSel = el.tagName === 'SELECT';
        const isBox = el.type === 'checkbox' || el.type === 'radio';
        // A secret field reports THAT it is filled, never what with: the
        // snapshot is returned to the model, so its value would be printed
        // into the conversation the moment anything typed a password. Which
        // fields are secret is decided once, in clean.SECRET_FIELD_JS.
        const secret = secretField(el);
        const value = secret ? (el.value ? """ + json.dumps(clean.MASKED_PASSWORD) + """ : '') : el.value;
        const text = (isSel ? chosen(el) : (el.innerText || value || '')).trim().replace(/\\s+/g, ' ').slice(0, 60);
        const href = el.tagName === 'A' ? useful(el.getAttribute('href')) : undefined;

        const e = { tag: el.tagName.toLowerCase() };
        if (el.getAttribute('role')) e.role = el.getAttribute('role');
        if (el.type) e.type = el.type;
        if (el.name) e.name = el.name;
        if (el.id) e.id = el.id;
        // The selector to pass to browser_click / browser_type verbatim. Always
        // present when the element can be reached by one at all, so a caller
        // never has to build one, never has to escape anything, and never has
        // to know when the obvious one would have been ambiguous. One rule
        // instead of a conditional one, which is the kind a caller gets wrong.
        const h = handle(el, href);
        if (h) e.selector = h.sel;
        if (h && h.nthPath) { e._nth_path = h.nthPath; e._nth_kind = h.nthKind; }
        // The href is dropped when the selector already carries it, which is
        // the whole reason this stayed affordable. Measured over 969 elements
        // on real pages: emitting the selector cost +47.2% of the payload, and
        // +15.1% once the duplicated href came out - for the same information,
        // since `a[href='/cart']` says where the link goes as plainly as the
        // separate field did. A link addressed by its id keeps its href, having
        // nothing duplicated.
        if (href && !(h && h.fromHref)) e.href = href;
        if (el.placeholder) e.placeholder = el.placeholder;
        if (el.getAttribute('aria-label')) e.label = el.getAttribute('aria-label');
        if (text) e.text = text;
        // THE CURRENT STATE, and it is here because of what its absence caused.
        // A model asked to tick a box and pick an option could see neither, so
        // it read them the only way left to it - by injecting script - and then
        // wrote them back the same way. A gap in what the caller can SEE is
        // answered with evaluate() just as surely as a gap in what it can DO,
        // and a value set from script is not a trusted event.
        if (isBox) e.checked = el.checked;
        if (isSel) e.value = el.value;
        // Centre coordinates in the viewport, so browser_click_at can reach
        // what no selector describes.
        e.at = [Math.round(r.left + r.width / 2), Math.round(r.top + r.height / 2)];
        // Only when it is OUTSIDE: inside is the common case, and saying so
        // every time costs bytes without informing anyone.
        if (!(r.top < innerHeight && r.left < innerWidth)) e.off_screen = true;
        out.push(e);
      } catch (err) { unmeasurable++; }
    }
    const answer = { title: document.title, url: location.href, interactive_elements: out };
    // Emitted only when it happened, and emitted HERE rather than added by the
    // Python side: with no cap the snapshot returns this object verbatim, so a
    // counter added later would never reach the caller on the default path.
    if (unmeasurable) answer.unmeasurable = unmeasurable;
    return answer;
}"""


async def snapshot(session) -> str:
    """Title, url, and the interactive elements that are actually visible.

    Not the accessibility tree, and the reason is measured rather than
    aesthetic: on a real sign-up page a single country `<select>` contributes
    about two hundred `<option>` nodes, which fill the character cap before the
    form the caller was looking for appears at all. Filtering to elements a
    caller can act on - and to `offsetParent !== null`, so hidden ones do not
    count - keeps the answer about the page rather than about its longest
    dropdown.
    """
    page = session.page()
    # ⛔ `evaluate_read`, NOT `evaluate`: the snapshot is a read without
    # effects, and a page that navigates under it is read again on the page
    # that replaced it. `evaluate` sends the code once and raises Playwright's
    # navigation error, which is right for the model's code (`evaluate` below)
    # and wrong for a read right after `browser_navigate` on a page that
    # replaces itself (invisible-playwright 0.35.2, [B285]).
    d = await page.evaluate_read(SNAPSHOT_JS)
    await _resolve_nth(page, d.get("interactive_elements", []))
    return json.dumps(d)


async def read_html(session, mode: str = "form") -> str:
    """The page's markup, reduced to what is worth reading.

    Two steps, and they are split because only one of them can be done in each
    place. The browser decides what is actually painted - computed style and
    layout exist only there - and it does that on a CLONE, so the live page is
    never written to. The string that comes back is then cleaned in Python,
    where the structural work is testable without a browser.

    Measured over a corpus of real pages: 9.6 MB of markup became 293 KB, 97%
    smaller, with every one of the 1,453 interactive elements still present, and
    a median of 48 ms per page.

    mode="form"  the interactive surface plus the text that explains it
    mode="text"  the prose, with the markup gone
    mode="full"  noise removed and attributes slimmed, structure kept
    """
    # A read without effects, read again on the page that replaced the one it
    # went to: see `snapshot`.
    html = await session.page().evaluate_read(clean.VISIBLE_HTML_JS)
    return clean.clean_page(html, mode)


async def screenshot_png(session) -> bytes:
    """Raw PNG bytes of the active tab.

    Bytes rather than an MCP Image, because this is also what a live view in a
    browser tab needs, and that caller has no use for an MCP type.
    """
    return await session.page().screenshot()


# --- acting ----------------------------------------------------------------

DIAGNOSE_JS = """(el) => {
    // Why an action could not land on `el`, the first element the ENGINE
    // resolved the selector to. Runs only after one has failed, so it can
    // afford to look properly.
    //
    // ⛔ IT IS HANDED THE ELEMENT, NOT THE SELECTOR. It used to search for the
    // selector itself with document.querySelectorAll, which knows neither a
    // shadow root nor Playwright's own syntax (`>>`, `:nth-match`, `nth=`) -
    // so on 2026-09-30 it answered `{"matches": 0}` for `#firstName input`,
    // a field the engine could reach, and called the snapshot's own
    // `:nth-match` handles "not valid CSS". An explanation that contradicts
    // the engine it explains sends the caller the wrong way.
    const r = el.getBoundingClientRect();
    const out = {width: Math.round(r.width), height: Math.round(r.height)};
    const s = getComputedStyle(el);
    if (s.display === 'none') out.display_none = true;
    if (s.visibility === 'hidden') out.visibility_hidden = true;
    if (el.disabled === true) out.disabled = true;
    if (s.pointerEvents === 'none') out.pointer_events_none = true;
    if (r.bottom < 0 || r.top > innerHeight) out.off_screen = true;
    // The one that matters most: something else is on top. Report WHAT, because
    // the caller's next move is to deal with that thing.
    const cx = Math.round(r.left + r.width / 2), cy = Math.round(r.top + r.height / 2);
    // Asked of the element's own root: the document answers with the shadow
    // HOST for anything inside a shadow root, and the host does not
    // `contains()` its shadow content, so every such field read as covered.
    const root = el.getRootNode ? el.getRootNode() : document;
    const within = (a, b) => {
        for (let n = a; n; n = n.parentNode || n.host) if (n === b) return true;
        return false;
    };
    if (cx >= 0 && cy >= 0 && cx < innerWidth && cy < innerHeight) {
        const hit = (root.elementFromPoint ? root : document).elementFromPoint(cx, cy);
        if (hit && !within(hit, el) && !within(el, hit)) {
            out.covered_by = {
                tag: hit.tagName.toLowerCase(),
                id: hit.id || undefined,
                cls: (hit.className && hit.className.toString().slice(0, 60)) || undefined,
                text: (hit.innerText || '').trim().replace(/\\s+/g, ' ').slice(0, 60) || undefined,
                position: getComputedStyle(hit).position
            };
        }
    }
    return out;
}"""


#: What to do about each thing the diagnosis can find. The sentences live here
#: rather than inside the tools because the answer depends on what the PAGE
#: says, never on which tool was asking.
#:
#: ⛔ AND `matches: 0` IS THE ONE THAT WAS MISSING A MOVE. Measured on a real
#: run: the model wrote `.inbox-dataentry a, .inbox a, [class*="mail-item"] a`,
#: waited the full fifteen seconds for nothing, then spent four more
#: `browser_evaluate` calls hunting through the DOM by hand before it thought of
#: taking a fresh snapshot - which worked first time.
#:
#: It could not have read those class names anywhere. `browser_snapshot` builds
#: its `selector` from id, name, href, data-testid or aria-label and never from
#: class, and `browser_read_html` drops the class attribute outright. So a
#: class-based selector is ALWAYS one the caller wrote, and the product knew
#: that and did not say it at the only moment it mattered.
NEXT_MOVE = {
    "bad_selector": "that is not valid CSS, so nothing was searched for. "
                    "browser_snapshot hands out a `selector` for each element; "
                    "pass that string verbatim.",
    "matches": "nothing on the page matches that selector. If you wrote it "
               "yourself, take a fresh browser_snapshot and use the `selector` "
               "it gives verbatim - they are built from id, name, href, "
               "data-testid or aria-label, never from class, so a class-based "
               "selector will not come from this page's snapshot. If it came "
               "from a snapshot, the page has changed since: snapshot again.",
    "covered_by": "something else is on top of it. Deal with that thing first - "
                  "a banner to dismiss, a dialog to close - which is a "
                  "different action from trying this one again.",
    "display_none": "it is in the page but not displayed. Whatever reveals it "
                    "has not happened yet.",
    "visibility_hidden": "it is laid out but invisible, so it cannot be used.",
    "disabled": "it is disabled. Something has to enable it first.",
    "pointer_events_none": "it does not take pointer events at all, which is "
                           "usually deliberate: the page is refusing it for now.",
    "off_screen": "it is outside the window and could not be brought in.",
}


def next_move(why: dict) -> str:
    """The one sentence a caller can act on, for what the page reported.

    ⛔ ONE PLACE, BECAUSE THREE TOOLS TAKE A SELECTOR AND ONLY ONE OF THEM COULD
    EXPLAIN A FAILURE. `click` asked the page why and said so; `type` and
    `select_option` handed back Playwright's bare timeout, which names the
    selector and nothing else. The same failure got a useful answer or a useless
    one depending on which tool the caller happened to use.
    """
    if why.get("bad_selector"):
        return NEXT_MOVE["bad_selector"]
    if not why.get("matches"):
        return NEXT_MOVE["matches"]
    for name in ("covered_by", "display_none", "visibility_hidden", "disabled",
                 "pointer_events_none", "off_screen"):
        if why.get(name):
            return NEXT_MOVE[name]
    return ("the page reports nothing wrong with it, so whatever stopped the "
            "action was momentary. Look at the page before trying again.")


#: What the engine says when a selector cannot be parsed, as opposed to when the
#: page could not be asked. Only these become `bad_selector`: anything else -
#: a navigation, a closed page - is not the caller's selector's fault.
_UNPARSABLE = re.compile(
    r"not a valid selector|unexpected token|unknown engine|selector.*(?:parse|syntax)"
    r"|syntaxerror|malformed|invalid selector", re.I)


async def _diagnose(page, selector: str):
    """What the page says about `selector`, resolved by the ENGINE.

    The engine is what the action used, so it is what the explanation asks:
    shadow roots, `>>` chains and `:nth-match` mean the same thing to both.
    None when the page could not be asked at all.
    """
    try:
        found = await page.query_selector_all(selector)
    except Exception as exc:
        if _UNPARSABLE.search(str(exc)):
            return {"bad_selector": True}
        return None
    try:
        if not found:
            return {"matches": 0}
        why = {"matches": len(found)}
        with swallow("the element can go between being found and being read"):
            why.update(await found[0].evaluate(DIAGNOSE_JS) or {})
        return why
    finally:
        for element in found or ():
            with swallow("a handle the page already dropped needs no release"):
                await element.dispose()


def _explain(exc, what: str, why: dict) -> RuntimeError:
    return RuntimeError(
        "%s\n\nwhy the %s did not land: %s\nwhat to do: %s"
        % (exc, what, json.dumps(why), next_move(why)))


#: How long an action aimed at a selector waits for its element to be there and
#: usable, for every tool that takes one. One number, because a click that
#: waited longer than a type on the same element would be a difference nobody
#: chose.
ACTION_TIMEOUT_MS = 15_000


async def _on_selector(session, selector: str, what: str, act):
    """Run an action aimed at a selector, and when it fails say why and what
    follows from it.

    Playwright reports a failure as "not actionable in 15s after N attempts",
    which tells a caller that something is wrong and nothing about what.
    Measured across eighteen real sites, four clicks failed and every one of
    them failed that way: a logo, a footer link, a shipping button. Fifteen
    seconds spent to learn nothing.

    ⛔ AND A SELECTOR THAT MATCHES NOTHING GETS THE WHOLE TIMEOUT, ON PURPOSE.
    Giving up on it after a few seconds was tried and measured as a
    regression: a button a page adds five seconds after load was clicked at
    5.4 s with the full wait and refused at 3.1 s with a three-second one. No
    shorter wait is right either, because what the page will do next is not
    something it shows: a timer that is about to add the element leaves no
    mutation, no request and no navigation behind it, so a document that has
    been still for any length of time is indistinguishable from one that is
    finished. The early answers that ARE certain come without asking for
    them: a selector the engine cannot parse is refused in under a second,
    and so is an action the engine itself rejects.
    """
    try:
        return await act()
    except Exception as exc:
        try:
            why = await _diagnose(session.page(), selector)
        except Exception:
            why = None
        if not why:
            raise
        raise _explain(exc, what, why) from exc


async def click(session, selector: str) -> str:
    """Click an element, and say what stopped it when nothing happens."""
    return await _on_selector(
        session, selector, "click",
        lambda: session.page().click(selector, timeout=ACTION_TIMEOUT_MS)) or f"clicked {selector}"


async def click_at(session, x: float, y: float, hold_seconds: float = 0.0) -> bytes:
    """Click (or press-and-hold) a raw viewport coordinate instead of a
    selector - for targets a selector cannot reliably reach: a slider track, a
    canvas-drawn captcha, or a precise point inside a wider element. Moves the
    pointer there first (no teleport), then down, then - if hold_seconds is 0 -
    immediately up (a plain click); otherwise waits before releasing.

    Returns a screenshot taken right after release, so the result of the click
    is visible without a second round-trip.
    """
    page = session.page()
    await page.mouse.move(x, y, steps=12)
    await page.mouse.down()
    if hold_seconds > 0:
        await page.wait_for_timeout(int(hold_seconds * 1000))
    await page.mouse.up()
    # Give a post-click transition (checkmark, redirect, reflow) a moment to
    # start before the screenshot, so it reflects the outcome, not the click.
    await page.wait_for_timeout(400)
    return await page.screenshot()


#: What the page is asked about a field, before typing and after: what it holds,
#: whether it still has the focus, and whether it is a secret. One read, so the
#: three answers describe the same moment. `value` is None for anything that is
#: neither a text control nor editable content, which then cannot be read back.
#:
#: The focus is asked of the element's own root, because a document answers
#: with the shadow HOST for anything inside a shadow root.
FIELD_STATE_JS = """(el) => {""" + clean.SECRET_FIELD_JS + """
    const root = el.getRootNode ? el.getRootNode() : document;
    const text = el.tagName === 'INPUT' || el.tagName === 'TEXTAREA';
    return {value: text ? el.value : (el.isContentEditable ? el.innerText : null),
            focused: root.activeElement === el,
            secret: secretField(el)};
}"""


async def _field_state(page, selector: str) -> dict:
    """The field's state, waiting for it as long as an action waits: the first
    read is what finds the field, so a selector that matches nothing gets the
    action timeout and not the engine's longer default."""
    return await page.locator(selector).first.evaluate(FIELD_STATE_JS,
                                                       timeout=ACTION_TIMEOUT_MS)


def _shown(value: str, secret: bool) -> str:
    """What the field holds, as the answer quotes it: whole.

    ⛔ IT STOPPED AT 120 CHARACTERS UNTIL 0.72.1, with "..." in place of the
    rest. These sentences exist to say how the field differs from what was
    typed, and a page that reformats a long value - or keeps only part of it -
    makes that difference anywhere in it: past the 120th character the model
    read "..." where the change was. No constraint asked for the cap (D87: a
    cap only where one does)."""
    if secret:
        return "%d characters, not shown because the field holds a secret" % len(value)
    return repr(value)


def what_the_field_kept(selector: str, text: str, before: dict, after: dict) -> str:
    """The sentence `browser_type` answers, from what the field holds now.

    ⛔ "TYPED INTO" IS A CLAIM ABOUT THE FIELD, NOT ABOUT THE CALL, and every
    other outcome is SAID rather than retried. Typing again is not idempotent:
    a field that turns `a@b.io,` into a chip took the text the first time, and
    a second pass makes a second chip. Nor is every short value a failure: a
    one-time code split across six boxes keeps one digit here because the page
    moved the focus on, which is the page working. So each shape is named for
    what it is, and the caller decides what follows.
    """
    value = after.get("value")
    secret = bool(before.get("secret") or after.get("secret"))
    if value is None:
        return "typed into %s; it is not a field whose text can be read back" % selector
    if value == text:
        moved = "" if after.get("focused") else "; then the page moved the focus on"
        return "typed into %s%s" % (selector, moved)
    if not after.get("focused") and text.startswith(value):
        if not value:
            return ("typed toward %s, but the page moved the focus away before any "
                    "of it stayed there; the keys went where the focus went. Read "
                    "the page to see where." % selector)
        return ("typed into %s until the page moved the focus to another field after "
                "%d of %d characters, as a code split across boxes does: %s holds "
                "%s and the rest went where the focus went. Read the page to check."
                % (selector, len(value), len(text), selector, _shown(value, secret)))
    if value and text.startswith(value):
        return ("%s kept only the first %d of %d characters and refused the rest, "
                "as a maxlength does; the rest went nowhere. Shorten the text if "
                "the field cannot take more." % (selector, len(value), len(text)))
    caution = ("Read the page before typing again: a field that turns text into "
               "items would take it twice.")
    if not value:
        return ("%s is empty after typing: the page took the text out of the field. "
                "A tag or chip field does that when a comma or Enter turns it into an "
                "item, and a page that rewrites the field from its own state does it "
                "while it answers the focus. %s" % (selector, caution))
    if text.endswith(value):
        return ("%s holds only the last %d of %d characters: the page emptied the "
                "field while it was being typed, as a page that rewrites a field "
                "from its own state does when it answers the focus or another "
                "field's change. %s" % (selector, len(value), len(text), caution))
    return "typed into %s; the page shows it as %s" % (selector, _shown(value, secret))


async def type_text(session, selector: str, text: str) -> str:
    """Type into a field the way a person does, and say what the field kept.

    The engine's `fill`: focus, the typist's pause (longer while the page is
    still answering the focus), then every character through the keyboard at
    the session's rhythm, replacing what the field held; and a read of the
    field afterwards.

    ⛔ THE PAUSE IS THE ENGINE'S, NOT THIS SERVER'S. It stood here, between a
    `page.focus` and the `fill`, drawn by importing private names of the
    wrapper and copying the spread of its hesitations, because the engine's
    `fill` pressed the first key in the same breath as the focus. The engine
    now waits by itself, for every caller, so a second pause here would be
    one hesitation too many.

    ⛔ EVERY CHARACTER IS A KEY, HOWEVER LONG THE TEXT. Text past eighty
    characters used to go in through `insert_text`, described as a paste, and
    a page saw something no person produces: a composition with no key behind
    it, the whole text committed at once, after a clear that was an untrusted
    bare `input`. A real paste is Control, V, a `paste` event carrying the
    data and an `insertFromPaste` input, and the engine cannot produce one
    without writing to the clipboard - which in a headed browser on Windows is
    the person's own clipboard. Until it can, long text is typed; the call that
    would outlast a client's patience goes on in the background
    (`Work.typing`), so typing it still finishes.
    """
    page = session.page()
    before = await _on_selector(session, selector, "typing",
                                lambda: _field_state(page, selector))
    await _on_selector(session, selector, "typing",
                       lambda: page.fill(selector, text, timeout=ACTION_TIMEOUT_MS))
    return what_the_field_kept(selector, text, before, await _field_state(page, selector))


async def select_option(session, selector: str, value: str) -> str:
    """Choose an option in a `<select>`, by its value OR by its visible label.

    ⛔ IT EXISTS BECAUSE ITS ABSENCE PUSHED MODELS INTO A DETECTABLE WORKAROUND.
    Measured on a four-field form: with no way to set a select, the model clicked
    it, pressed ArrowDown twice hoping to land on the right row, could not tell
    whether it had, and finally set `select.value` through `browser_evaluate`.
    That last step is script injection into the page - it skips the humanised
    path entirely and produces a change the site never saw a real interaction
    for. A missing tool is not a neutral gap: the model routes around it, and the
    route it finds is worse than the tool would have been.

    BOTH value and label, because a model reads the page and what a page shows
    is the LABEL. Asking it for the `value` attribute means asking it to read
    markup it may never have fetched, and a tool that needs the caller to know a
    hidden attribute is a tool that gets used wrong.

    ⛔ ONE ATTEMPT, BECAUSE THE DRIVER ALREADY MATCHES BOTH. `value=` reaches it
    as `valueOrLabel`, which selects an option whose value OR whose label is
    the string. This used to try the value and then, on failure, the label -
    and the second attempt could only fail where the first had, after waiting
    its own full timeout. Measured: a selector matching nothing failed after
    30.2 s, two timeouts, where a click on the same selector took 15.1 s.
    `tests/test_a_failed_selector_says_what_to_do.py` holds the driver to that
    mapping, and `tests/mcp_server/test_shadow_roots.py` to a label chosen on a
    real page.
    """
    page = session.page()

    async def choose():
        try:
            return await page.select_option(selector, value=value, timeout=ACTION_TIMEOUT_MS)
        except Exception as exc:
            # ⛔ THE SELECT WAS FOUND AND HAS NO SUCH OPTION, which the driver
            # says as `error:optionsnotfound` and the diagnosis below cannot
            # see: it looks at the element, finds it fine, and called the
            # failure "momentary" - advice to try again what can never work.
            # It is the same fact as an empty answer, so it takes the same road.
            if "optionsnotfound" in str(exc):
                return []
            raise

    chosen = await _on_selector(session, selector, "select", choose)
    if not chosen:
        # Playwright can also answer with an empty list rather than raising
        # when nothing matched, so a caller reading only the exception would
        # believe it had worked and go on to submit a form that never changed.
        raise RuntimeError(
            f"no option in {selector} has the value or the label {value!r}")
    # Which of the two it matched, read off what was chosen rather than
    # guessed: an option whose value is the string was matched by its value.
    how = "value" if value in chosen else "label"
    return f"selected {selector} by {how}: {chosen}"


# ── files, picked the way a person picks them ──────────────────────────────
#
# ⛔ WITHOUT THIS, AN UPLOAD WAS IMPOSSIBLE, AND IMPOSSIBLE IS NOT NEUTRAL. A
# file input takes nothing from the keyboard and nothing from browser_evaluate,
# so a credit application's "Supporting Documents" page (measured 2026-10-01)
# was the end of the road: the model could click "Add Document", watch a chooser
# open that no tool could answer, and stop. The way past it a model finds next
# is script - a DataTransfer built in the page and assigned to `input.files`,
# which is exactly the untrusted change this package exists to avoid.
#
# The file chooser is what a person uses, so the chooser is what this answers:
# the real pointer clicks what opens it and the files go in through the
# engine's own file-input path, with the input and change events a picked file
# produces, after the time a person takes to pick them.
#
# ⛔ AND A HIDDEN INPUT IS OPENED THROUGH WHAT A PERSON CLICKS, NEVER FED. The
# usual shape is a styled button or label in front of an `<input type=file>`
# nobody can see, and the first version gave such an input the files directly:
# the page then heard `input` and `change` on a control no pointer had touched,
# with no click anywhere before it, which no person can produce. So the label
# that opens it is clicked instead, and when there is none the caller is told
# to name the button that does.
#
# ⛔ AND IT READS ONLY FROM DIRECTORIES SOMEBODY NAMED. This hands a local file
# to a remote page, and the model choosing the path is driven by pages it has
# read. With no list there are no uploads at all, rather than a default that
# would have to guess which part of a disk is safe to send away.

#: The directories files may be uploaded from, separated by os.pathsep.
UPLOAD_DIRS_ENV = "INVISIBLE_MCP_UPLOAD_DIRS"
#: Per file. A form upload past this is not a document, and a typo naming a
#: disk image should not take the browser down with it.
UPLOAD_MAX_BYTES = 50 * 1024 * 1024
UPLOAD_MAX_FILES = 20
#: All the files of one call together. Each is copied into a snapshot inside
#: the one shared browser process and kept for an hour, so twenty files at the
#: per-file limit would be a gigabyte copied and held for one call.
UPLOAD_MAX_TOTAL_BYTES = 100 * 1024 * 1024

#: A hand aims at a box, so an input of 1px or less sends it to the label
#: (`_opener`); what the style hides is clean.STYLE_HIDES_JS, as everywhere.
_HAND_CAN_AIM_JS = clean.STYLE_HIDES_JS + """
  function handCanAim(el) {
    const r = el.getBoundingClientRect();
    return r.width > 1 && r.height > 1 && !styleHides(getComputedStyle(el));
  }
"""

_FILE_INPUT_JS = """el => {""" + _HAND_CAN_AIM_JS + """
  return {
    file: el.tagName === "INPUT" && (el.type || "").toLowerCase() === "file",
    multiple: !!el.multiple,
    shown: handCanAim(el),
  };
}"""
_FILE_NAMES_JS = "el => el.files ? Array.from(el.files, f => f.name) : null"


def upload_dirs(env=None) -> list[str]:
    """The directories named in INVISIBLE_MCP_UPLOAD_DIRS. A relative entry is
    refused rather than resolved against wherever the server started.

    ⛔ AND SO IS ONE THAT RESOLVES SOMEWHERE ELSE. Resolving the entry would let
    whoever can replace it with a symlink choose the root: a staging directory
    turned into a link to its parent widens every upload to the parent's whole
    tree, silently. An entry whose real path is not itself (a link anywhere in
    it, or a directory that does not exist) turns uploads off with the reason.
    """
    raw = (os.environ if env is None else env).get(UPLOAD_DIRS_ENV, "")
    dirs = []
    for entry in (e.strip() for e in raw.split(os.pathsep)):
        if not entry:
            continue
        if not os.path.isabs(entry):
            raise RuntimeError(
                f"{UPLOAD_DIRS_ENV} names {entry!r}, which is not an absolute path")
        named = os.path.normpath(entry)
        real = os.path.realpath(named)
        # Compared as this system compares paths: `c:/tmp` and `C:/tmp` are
        # one directory on Windows, and only a link makes them two.
        if os.path.normcase(real) != os.path.normcase(named) or not os.path.isdir(real):
            raise RuntimeError(
                f"{UPLOAD_DIRS_ENV} names {entry!r}, which is not a directory at "
                f"that exact path (it resolves to {real!r}); uploads are off")
        dirs.append(real)
    return dirs


def uploadable(paths, env=None) -> list[str]:
    """The files `paths` names, resolved, or the reason they may not be sent.

    Each must be absolute, a regular file once symlinks are followed, readable,
    under UPLOAD_MAX_BYTES, inside one of the named directories, and below it
    through no hidden component (`.ssh`, `.env`, `.git`): those hold keys more
    often than documents.

    This is the early answer, before any page is touched. What is uploaded is
    decided again by `snapshot_files`, on the open file rather than on its name.
    """
    if isinstance(paths, str) or not isinstance(paths, (list, tuple)) or not paths:
        raise ValueError("paths is a list of one or more absolute file paths")
    if len(paths) > UPLOAD_MAX_FILES:
        raise ValueError(f"at most {UPLOAD_MAX_FILES} files in one upload")
    dirs = upload_dirs(env)
    if not dirs:
        raise RuntimeError(
            f"uploads are off: {UPLOAD_DIRS_ENV} names no directory files may be "
            "uploaded from")
    out, total = [], 0
    for path in paths:
        if not isinstance(path, str) or not os.path.isabs(path):
            raise ValueError(f"{path!r} is not an absolute path")
        _no_stream(path)
        real = os.path.realpath(path)
        _no_stream(real)
        home = _home(real, dirs)
        if home is None:
            raise PermissionError(
                f"{path} is not inside a directory uploads may come from "
                f"({os.pathsep.join(dirs)})")
        _no_hidden(path, real, home)
        try:
            st = os.stat(real)
        except OSError as exc:
            raise FileNotFoundError(f"{path}: {exc.strerror or exc}") from None
        if not stat.S_ISREG(st.st_mode):
            raise ValueError(f"{path} is not a regular file")
        if st.st_size > UPLOAD_MAX_BYTES:
            raise ValueError(f"{path} is {st.st_size} bytes, over the "
                             f"{UPLOAD_MAX_BYTES}-byte limit for one file")
        if not os.access(real, os.R_OK):
            raise PermissionError(f"{path} is not readable")
        if real in out:
            raise ValueError(f"{path} is named twice")
        total += st.st_size
        if total > UPLOAD_MAX_TOTAL_BYTES:
            raise ValueError(f"these files come to more than {UPLOAD_MAX_TOTAL_BYTES} "
                             "bytes together; upload them in more than one call")
        out.append(real)
    return out


def _home(real: str, dirs: list[str]):
    """The named directory `real` lies in, or None.

    Compared as this system compares paths, without case on Windows, where
    `commonpath` keeps the case of what it is given: `c:/up/a.pdf` under
    `C:/up` read as outside it. And a path on another drive than a directory
    is simply not in it, which `commonpath` says by raising.
    """
    key = os.path.normcase(real)
    for d in dirs:
        with swallow("a path on another drive is not inside this directory"):
            if os.path.commonpath([key, os.path.normcase(d)]) == os.path.normcase(d):
                return d
    return None


def _no_stream(path: str) -> None:
    """Refuse an NTFS alternate data stream, `a.pdf:Zone.Identifier`.

    On Windows a colon after the drive names a stream inside the file, and a
    stream is opened, sized and copied like the file itself - so the guard
    above would send the mark of the web a download carries, or anything else
    hidden in a stream, under the file's own name. Elsewhere a colon is an
    ordinary character in a name.
    """
    if os.name == "nt" and ":" in os.path.splitdrive(path)[1]:
        raise ValueError(f"{path} names an alternate data stream, not a file; not sent")


def _no_hidden(path: str, real: str, home: str) -> None:
    rel = os.path.relpath(real, home)
    hidden = [c for c in rel.split(os.sep) if c.startswith(".")] if rel != "." else []
    if hidden:
        raise PermissionError(f"{path} lies under a hidden name ({hidden[0]}); not sent")


def _opened_path(fd: int, real: str, st) -> str:
    """Where the OPEN file actually is. On Linux the kernel says so; elsewhere
    the name must still lead to the very file that was opened."""
    proc = f"/proc/self/fd/{fd}"
    if os.path.islink(proc):
        where = os.readlink(proc)
        # A file unlinked after it was opened is still the file that was
        # opened; the kernel marks its old name rather than giving it a new one.
        if where.endswith(" (deleted)") and os.fstat(fd).st_nlink == 0:
            where = where[: -len(" (deleted)")]
        return where
    now = os.stat(real)
    if (now.st_dev, now.st_ino) != (st.st_dev, st.st_ino):
        raise PermissionError(f"{real} changed while it was being read; not sent")
    return real


#: ⛔ A SNAPSHOT LIVES AS LONG AS THE BROWSER IT WAS GIVEN TO. Firefox reads a
#: picked file's bytes when the page sends it, not when it is picked, so the
#: copy must outlast the call; it is handed to the session, which removes it
#: when the browser closes (`StealthSession.keep_until_closed`). One left by a
#: process that ended without closing its browsers is removed by the next
#: upload, once that process is gone: its id is in the directory's name.
#: Copies used to be kept for an hour after their call and removed only by a
#: later upload, so a server that closed left them in %TEMP% for good.


def snapshot_files(files: list[str], env=None) -> list[str]:
    """Private copies of `files`, checked on the open file, not on its name.

    ⛔ THE NAME IS NOT THE FILE. `uploadable` resolves and stats a path, and a
    chooser is answered seconds later; in a directory other processes write to
    (a staging directory several sessions share), the name can be pointed at
    something else in between, and the engine would read whatever it names by
    then. So each file is opened without following a final link, the OPEN file
    is checked - regular, within the limit, really inside an allowed directory
    and under no hidden name - and its bytes are copied into a fresh owner-only
    directory. That copy is what the engine is given, and nothing else can
    write to it.
    """
    dirs = upload_dirs(env)
    _expire_snapshots()
    root = tempfile.mkdtemp(prefix="%s%d-" % (_SNAPSHOT_PREFIX, os.getpid()))
    try:
        out, total = [], 0
        for i, real in enumerate(files):
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
            try:
                fd = os.open(real, flags)
            except OSError as exc:
                raise PermissionError(f"{real} could not be opened as a plain file "
                                      f"({exc.strerror or exc}); not sent") from None
            try:
                st = os.fstat(fd)
                if not stat.S_ISREG(st.st_mode):
                    raise ValueError(f"{real} is not a regular file")
                actual = os.path.realpath(_opened_path(fd, real, st))
                home = _home(actual, dirs)
                if home is None:
                    raise PermissionError(
                        f"{real} is no longer inside a directory uploads may come from; not sent")
                _no_hidden(real, actual, home)
                os.makedirs(os.path.join(root, str(i)), mode=0o700)
                # The name checked and shown is the one the caller gave, never
                # one read back from the descriptor: that can carry the
                # kernel's " (deleted)" mark, and a portal checks extensions.
                dest = os.path.join(root, str(i), os.path.basename(real))
                size = 0
                with os.fdopen(os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                       | getattr(os, "O_BINARY", 0), 0o600), "wb") as copy:
                    while chunk := os.read(fd, 1 << 20):
                        size += len(chunk)
                        total += len(chunk)
                        if size > UPLOAD_MAX_BYTES:
                            raise ValueError(f"{real} is over the {UPLOAD_MAX_BYTES}-byte "
                                             "limit for one file")
                        if total > UPLOAD_MAX_TOTAL_BYTES:
                            raise ValueError(f"these files came to more than "
                                             f"{UPLOAD_MAX_TOTAL_BYTES} bytes together")
                        copy.write(chunk)
                out.append(dest)
            finally:
                os.close(fd)
        return out
    except BaseException:
        shutil.rmtree(root, ignore_errors=True)
        raise


_SNAPSHOT_PREFIX = "invisible-upload-"


def _expire_snapshots() -> None:
    """Snapshots left by processes that are no longer running."""
    base = tempfile.gettempdir()
    with swallow("a snapshot directory that cannot be listed is left alone"):
        for name in os.listdir(base):
            path = os.path.join(base, name)
            if not name.startswith(_SNAPSHOT_PREFIX) or os.path.islink(path):
                continue
            owner = name[len(_SNAPSHOT_PREFIX):].split("-", 1)[0]
            if owner.isdigit() and process.alive(int(owner)):
                continue
            with swallow("another process may expire it first"):
                shutil.rmtree(path)


#: Which label opens a hidden file input: the first of its labels a person can
#: see, as `for` (pointing at it by id) or `wrap` (the input inside it), with
#: the position among the labels that share the same `for`. None when no label
#: is shown, which leaves the caller to name the button that opens it.
_OPENER_JS = """el => {""" + _HAND_CAN_AIM_JS + """
  for (const l of (el.labels || [])) {
    if (!handCanAim(l)) continue;
    if (l.contains(el)) return {how: "wrap"};
    if (l.htmlFor && l.htmlFor === el.id) {
      const root = l.getRootNode();
      const same = Array.from(root.querySelectorAll("label")).filter(x => x.htmlFor === el.id);
      return {how: "for", id: el.id, nth: same.indexOf(l) + 1, of: same.length};
    }
  }
  return null;
}"""


async def _opener(page, selector: str, target: dict) -> str:
    """The selector a person would click to open this input's chooser.

    The input itself when it is shown; for a hidden one, the label in front of
    it. A hidden input with no shown label is refused with what to pass
    instead: whatever opens it is a button the page wired by script, and only
    the caller can see which one it is.
    """
    if not target["file"] or target["shown"]:
        return selector
    found = await page.eval_on_selector(selector, _OPENER_JS)
    if not found:
        raise RuntimeError(
            f"{selector} is a hidden file input, and no label on the page opens "
            "it. A page cannot get files into a hidden input without somebody "
            "clicking what opens it, so give the selector of the button or link "
            "that does (browser_snapshot lists it).")
    if found["how"] == "wrap":
        return f"{selector} >> xpath=ancestor::label[1]"
    css = "label[for=%s]" % json.dumps(found["id"])
    return css if found["of"] == 1 else ":nth-match(%s, %d)" % (css, found["nth"])


async def _open_chooser(session, opener: str):
    """Click what opens the chooser, with the real pointer, and return it.

    The wait for the chooser starts with the click and is not bounded by it:
    the click has its own action timeout, and a chooser that has not opened an
    action timeout after the click has landed is one the click does not open.
    """
    page = session.page()
    waiter = asyncio.ensure_future(page.wait_for_event("filechooser", timeout=0))
    try:
        await _on_selector(session, opener, "click",
                           lambda: page.click(opener, timeout=ACTION_TIMEOUT_MS))
        return await asyncio.wait_for(waiter, ACTION_TIMEOUT_MS / 1000)
    except asyncio.TimeoutError:
        raise RuntimeError(
            f"clicking {opener} opened no file chooser. Give the selector of the "
            "<input type=file>, or of the button or label that opens it "
            "(browser_snapshot lists both).") from None
    finally:
        waiter.cancel()


async def upload_files(session, selector: str, paths) -> str:
    """Attach local files to a file input, through its file chooser.

    The files are checked before any page is touched, the thing that opens the
    chooser is clicked with the real pointer, the chooser is answered through
    the wrapper's standard `FileChooser.set_files` - which hands the files over
    after the time a person takes to find and confirm one, drawn from the
    session's own hand - and the input is read back.
    """
    named = uploadable(paths)
    page = session.page()
    target = await _on_selector(session, selector, "upload",
                                lambda: page.eval_on_selector(selector, _FILE_INPUT_JS))
    if len(named) > 1 and target["file"] and not target["multiple"]:
        raise RuntimeError(f"{selector} takes one file; upload them one at a time")
    opener = await _opener(page, selector, target)
    files = snapshot_files(named)
    session.keep_until_closed(os.path.dirname(os.path.dirname(files[0])))
    chooser = await _open_chooser(session, opener)
    if len(files) > 1 and not chooser.is_multiple():
        raise RuntimeError(
            f"the chooser {opener} opened takes one file; nothing was attached. "
            "Upload them one at a time")
    await chooser.set_files(files, timeout=ACTION_TIMEOUT_MS)
    held = await _held(chooser.element.evaluate(_FILE_NAMES_JS))

    names = ", ".join(os.path.basename(f) for f in named)
    how = "picked in the file chooser" if opener == selector else (
        "picked in the file chooser its label %s opened" % opener)
    said = f"attached {len(files)} file{'s' if len(files) != 1 else ''} to {selector} ({how}): {names}"
    want = [os.path.basename(f) for f in files]
    if held is None or held == want:
        return said
    if not held:
        return said + ("; the input is empty again, which is what a page that "
                       "uploads on change and then resets the input does - check "
                       "the page for the files")
    return said + f"; the input now holds: {', '.join(held)}"


async def _held(read):
    """What the input holds after the upload, or None when it cannot be read
    (a page that replaced the input once it had the files)."""
    with swallow("an input the page replaced after taking the files"):
        return await read
    return None


async def press_key(session, key: str) -> str:
    await session.page().keyboard.press(key)
    return f"pressed {key}"


# ── evaluate, and the one thing it must not be used for ─────────────────────
#
# ⛔ THIS PACKAGE EXISTS SO THAT INTERACTION LOOKS REAL, AND A VALUE SET FROM
# SCRIPT IS THE OPPOSITE OF THAT. `el.value = 'beta'` changes the field without
# a keystroke, without focus, without a trusted event; `el.click()` fires a
# handler with `isTrusted === false`, which is one property read away from being
# the clearest bot signal a page can collect. Every other tool here goes through
# the humanised path - approach, hover, press, release - and this one would go
# around it.
#
# It is not a hypothetical. Measured 2026-09-02, first run with a real model:
# asked to pick an option from a dropdown, with no tool that could, it clicked
# the select, pressed ArrowDown twice, and then ran `s.value='beta'` through
# here. The model was not being careless - it was routing around a gap, which is
# what a capable model does. The gap is the defect; this refusal is what makes
# the gap visible instead of silently detectable.
#
# So the fix is in two halves and both are needed. The gaps are closed
# (`browser_select_option` exists, and the snapshot reports `checked` and the
# selected `value`, which is what sent it here to READ in the first place), and
# the shortcut is refused with the name of the tool to use instead. Closing the
# gaps alone leaves the shortcut for the next gap; refusing alone leaves the
# model stuck with a task it can see how to finish.
#
# ⛔ AND THIS IS A PATTERN CHECK, NOT A SANDBOX. JavaScript has unlimited ways
# to say the same thing and this catches the ones a model actually writes. It is
# a guardrail on the obvious road, not a wall around the field, and it must not
# be described as one anywhere.
_BY_SCRIPT = (
    (re.compile(r"""\.(?:value|checked|selected)\s*\+?=(?!=)"""),
     "browser_type for a text field, browser_select_option for a dropdown, "
     "browser_click for a checkbox or a radio"),
    (re.compile(r"""\[\s*['"](?:value|checked|selected)['"]\s*\]\s*\+?=(?!=)"""),
     "browser_type for a text field, browser_select_option for a dropdown, "
     "browser_click for a checkbox or a radio"),
    (re.compile(r"""\.click\s*\("""),
     "browser_click, or browser_click_at when no selector describes the target"),
    (re.compile(r"""\.dispatchEvent\s*\("""),
     "browser_click, browser_type or browser_press_key - whichever interaction you are synthesising, there is a tool that produces it for real"),
    (re.compile(r"""\.(?:submit|requestSubmit)\s*\("""),
     "browser_click on the form's submit button"),
    # The five below were measured passing on 2026-09-04: they are the ordinary
    # modern spellings of the same acts, not exotic ones. `requestSubmit` above
    # is the same story - it is what `submit()` has become, and only the older
    # name was refused.
    (re.compile(r"""\.setAttribute\s*\(\s*['"](?:value|checked|selected|disabled)['"]"""),
     "browser_type for a text field, browser_select_option for a dropdown, "
     "browser_click for a checkbox or a radio"),
    (re.compile(r"""Object\s*\.\s*assign\s*\("""),
     "browser_type, browser_select_option or browser_click - whichever of those "
     "properties you are setting, a tool sets it for real"),
    (re.compile(r"""Reflect\s*\.\s*set\s*\("""),
     "browser_type, browser_select_option or browser_click"),
    (re.compile(r"""\.execCommand\s*\("""),
     "browser_type, which types into the focused field through the keyboard"),
)


def _refuse_script_interaction(expression: str) -> None:
    for pattern, instead in _BY_SCRIPT:
        if pattern.search(expression):
            raise ValueError(
                "refused: this changes the page from script, which produces an "
                "untrusted event and is exactly what this browser exists to "
                "avoid. Use " + instead + ". Reading is fine - it is assigning "
                "and calling that is refused. If no tool fits, say so in your "
                "answer rather than working around it.")


async def evaluate(session, expression: str) -> str:
    """Read from the page. Acting on it goes through the named tools.

    The refusal is deliberately narrow: it looks at what is being ASSIGNED or
    CALLED, so `el.value` reads and `el.value === 'x'` comparisons pass, and
    only `el.value = 'x'` does not.
    """
    _refuse_script_interaction(expression)
    return json.dumps(await session.page().evaluate(expression))
