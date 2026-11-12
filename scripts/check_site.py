#!/usr/bin/env python3
"""Check local website resources and section links without network requests."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent / "website"


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self.ids = [], set()

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if "id" in attributes:
            self.ids.add(attributes["id"])
        for key in ("href", "src"):
            if key in attributes:
                self.links.append(attributes[key])


count = 0
for path in ROOT.glob("*.html"):
    page = Page()
    page.feed(path.read_text())
    for link in page.links:
        parts = urlsplit(link)
        if parts.scheme or parts.netloc or parts.path.startswith("/"):
            continue
        if parts.path:
            target = (path.parent / unquote(parts.path)).resolve()
            assert target.is_relative_to(ROOT.resolve()), f"Outside site: {link}"
            assert target.exists(), f"Missing resource: {path.name}: {link}"
        elif parts.fragment:
            assert unquote(parts.fragment) in page.ids, f"Missing section: {link}"
        count += 1
print(f"Website: {count} local resources and section links checked.")
