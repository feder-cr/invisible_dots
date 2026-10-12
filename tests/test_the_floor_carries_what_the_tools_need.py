"""The declared floor is not below a version this package's behaviour needs.

⛔ A FLOOR IS THE ONLY THING THAT MAKES A FIX IN A DEPENDENCY REACH ANYBODY.
`invisible-playwright` is declared with `>=`, so a person who already has an
older wheel installed updates this package and keeps whatever that wheel does.
For a defect in the driver that is not a detail: up to 0.22.0 a click was not
delivered once - the hit target was read again AFTER the event and what it
found was turned into a retry, so any control that stops being hittable by its
own effect got pressed again. Measured on that version: a button that hides
itself took 1068 clicks across 30 calls, and every call then reported failure.

The floor was raised to 0.22.1 for that. This test exists so the next person to
touch the dependency line cannot lower it back without noticing, and so the
reason is carried by something that runs rather than by a comment nobody reads.

⛔ AND IT READS THE DECLARATION, NOT WHAT IS INSTALLED. A test that asked the
interpreter which version is importable would pass on this machine, where the
wrapper is installed from a checkout, and say nothing at all about what a user
who runs `pip install invisible-playwright-mcp` will get - which is the only thing a floor
decides.
"""
from __future__ import annotations

import re
import tomllib
from pathlib import Path

#: Every floor this package's own behaviour depends on, with what breaks below
#: it. A version here is not a preference: it is the first release in which the
#: named behaviour is true.
WHAT_THE_TOOLS_NEED = {
    "invisible-playwright": [
        ("0.13.0", "browser_watch and the live pane are built on page.screencast"),
        ("0.13.2", "browser_navigate reports the HTTP status and the landed url"),
        ("0.22.1", "a click is delivered once, whatever the click does to the page"),
        ("0.25.8", "a file chooser opened for a hidden file input takes the files"),
        ("0.35.0", "browser_read_text right after browser_navigate reads the page "
                   "that replaced itself instead of failing on its vanished world"),
        ("0.35.2", "browser_snapshot and browser_read_html read through "
                   "page.evaluate_read, and browser_evaluate runs the model's "
                   "code once when its page navigates while it waits"),
    ],
}


def _declared() -> dict:
    raw = Path(__file__).resolve().parents[1] / "pyproject.toml"
    with raw.open("rb") as f:
        data = tomllib.load(f)
    out = {}
    for line in data["project"]["dependencies"]:
        m = re.match(r"^([A-Za-z0-9_.-]+)\s*>=\s*([0-9][0-9A-Za-z.]*)", line.strip())
        if m:
            out[m.group(1).lower()] = m.group(2)
    return out


def _as_numbers(version: str):
    return tuple(int(p) for p in re.findall(r"\d+", version))


def test_every_floor_is_high_enough_for_what_this_package_does():
    """⛔ THE KNOWN-BAD: put `invisible-playwright>=0.16.2` back. The comment
    beside it would still explain three of the four reasons, and the fourth -
    the one that makes a click happen once - would silently stop reaching
    anybody who already had an older wheel."""
    declared = _declared()
    troppo_basso = []
    for name, needs in WHAT_THE_TOOLS_NEED.items():
        floor = declared.get(name)
        assert floor, "%s is not declared with a floor at all" % name
        for wanted, why in needs:
            if _as_numbers(floor) < _as_numbers(wanted):
                troppo_basso.append("%s>=%s is below %s, which is where %s"
                                    % (name, floor, wanted, why))
    assert not troppo_basso, "\n  ".join([""] + troppo_basso)


def test_the_reasons_are_not_a_list_nobody_updates():
    """The other direction, so this file cannot rot into a decoration: every
    reason recorded here has to name a version that the floor actually reached,
    or the list is describing a past that the declaration has moved on from and
    the test above is comparing against nothing."""
    declared = _declared()
    for name, needs in WHAT_THE_TOOLS_NEED.items():
        floor = _as_numbers(declared[name])
        raggiunte = [w for w, _ in needs if _as_numbers(w) <= floor]
        assert len(raggiunte) == len(needs), (
            "%s declares >=%s, so these reasons name versions it never reached: %r"
            % (name, declared[name],
               [w for w, _ in needs if _as_numbers(w) > floor]))
        assert needs[-1][0] == max((w for w, _ in needs), key=_as_numbers), (
            "the highest version is not last, so the list no longer reads as a "
            "history and the next person will append below the floor")
