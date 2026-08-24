"""Small, reusable and allowlisted web evidence retriever for children's lyrics.

The retriever never decides that a page is correct. It only returns bounded text evidence
for the reconciliation model to compare with the cached Tencent ASR result.
"""

from __future__ import annotations

from dataclasses import dataclass
from difflib import SequenceMatcher
from html import unescape
from html.parser import HTMLParser
import re
from typing import Callable, Protocol
from urllib.parse import parse_qs, quote_plus, unquote, urljoin, urlparse

import httpx


ALLOWED_LYRICS_HOSTS = (
    "supersimple.com",
    "pinkfong.com",
    "pinkfongplus.com",
    "pinkfonghomeschool.cn",
    "babybus.com",
    "babybuskids.com",
    "youtube.com",
    "youtu.be",
)


@dataclass(frozen=True)
class RetrievedLyricsEvidence:
    candidate_id: str
    source: str
    url: str
    text: str


class LyricsRetriever(Protocol):
    def search(self, song_title: str) -> list[RetrievedLyricsEvidence]: ...


class NoopLyricsRetriever:
    def search(self, song_title: str) -> list[RetrievedLyricsEvidence]:
        del song_title
        return []


class _SearchResultParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[tuple[str, str]] = []
        self._href: str | None = None
        self._parts: list[str] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag != "a":
            return
        values = dict(attrs)
        classes = str(values.get("class") or "").split()
        if "result__a" in classes and values.get("href"):
            self._href = str(values["href"])
            self._parts = []

    def handle_data(self, data: str) -> None:
        if self._href is not None:
            self._parts.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self._href is not None:
            title = " ".join("".join(self._parts).split())
            self.links.append((self._href, title))
            self._href = None
            self._parts = []


class _VisibleTextParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self._ignored_depth = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in {"script", "style", "svg", "noscript"}:
            self._ignored_depth += 1
        if tag in {"p", "div", "li", "br", "h1", "h2", "h3"}:
            self.parts.append("\n")
        if tag == "meta" and self._ignored_depth == 0:
            values = dict(attrs)
            if values.get("name") in {"description", "twitter:description"}:
                self.parts.append(str(values.get("content") or ""))
            if values.get("property") in {"og:description", "og:title"}:
                self.parts.append(str(values.get("content") or ""))

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style", "svg", "noscript"} and self._ignored_depth:
            self._ignored_depth -= 1
        if tag in {"p", "div", "li", "h1", "h2", "h3"}:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self._ignored_depth == 0:
            self.parts.append(data)

    def text(self, maximum_characters: int) -> str:
        lines = []
        previous = None
        for raw in "".join(self.parts).splitlines():
            line = " ".join(raw.split())
            if not line or line == previous:
                continue
            lines.append(line)
            previous = line
        return "\n".join(lines)[:maximum_characters]


class AllowlistedWebLyricsRetriever:
    """Fetch at most a few official/allowlisted pages discovered by a web query."""

    search_endpoint = "https://html.duckduckgo.com/html/"
    super_simple_endpoint = "https://supersimple.com/wp-json/wp/v2/song"
    maximum_response_bytes = 512_000
    maximum_evidence_characters = 12_000

    def __init__(
        self,
        *,
        timeout_seconds: float = 8,
        max_results: int = 3,
        client_factory: Callable[..., httpx.Client] = httpx.Client,
    ) -> None:
        self.timeout_seconds = timeout_seconds
        self.max_results = max(0, min(max_results, 3))
        self.client_factory = client_factory

    def search(self, song_title: str) -> list[RetrievedLyricsEvidence]:
        if self.max_results == 0:
            return []
        query = (
            f'"{song_title.strip()}" lyrics '
            "(site:supersimple.com OR site:pinkfong.com OR "
            "site:pinkfonghomeschool.cn OR site:babybus.com OR site:youtube.com)"
        )
        headers = {
            "User-Agent": "BabyPlayerLyricsEvidence/1.0",
            "Accept": "text/html,application/xhtml+xml",
        }
        try:
            with self.client_factory(timeout=self.timeout_seconds) as client:
                official_results = self._search_super_simple(client, song_title, headers)
                if len(official_results) >= self.max_results:
                    return official_results[: self.max_results]
                search_response = client.get(
                    f"{self.search_endpoint}?q={quote_plus(query)}", headers=headers
                )
                search_response.raise_for_status()
                search_html = self._bounded_text(search_response)
                parser = _SearchResultParser()
                parser.feed(search_html)
                results = list(official_results)
                seen_urls = {result.url for result in results}
                for raw_url, title in parser.links:
                    url = self._result_url(raw_url)
                    if not url or url in seen_urls or not self._allowed_url(url):
                        continue
                    seen_urls.add(url)
                    page_text = self._fetch_page(client, url, headers)
                    if len(page_text.split()) < 8:
                        continue
                    results.append(RetrievedLyricsEvidence(
                        candidate_id=f"web_{len(results) + 1}",
                        source=f"{urlparse(url).hostname}: {title}"[:128],
                        url=url,
                        text=page_text,
                    ))
                    if len(results) >= self.max_results:
                        break
                return results
        except (httpx.HTTPError, UnicodeError, ValueError):
            return locals().get("official_results", [])

    def _search_super_simple(
        self, client: httpx.Client, song_title: str, headers: dict
    ) -> list[RetrievedLyricsEvidence]:
        """Use Super Simple's public WordPress song API before generic search HTML."""
        try:
            response = client.get(
                self.super_simple_endpoint,
                params={"search": song_title.strip(), "per_page": "10"},
                headers={**headers, "Accept": "application/json"},
            )
            response.raise_for_status()
            payload = response.json()
            if not isinstance(payload, list):
                return []
        except (httpx.HTTPError, TypeError, ValueError):
            return []
        ranked = []
        for item in payload:
            if not isinstance(item, dict):
                continue
            acf = item.get("acf") or {}
            lyrics = str(acf.get("lyrics") or "").strip() if isinstance(acf, dict) else ""
            url = str(item.get("link") or "")
            title_value = item.get("title") or {}
            title = unescape(str(title_value.get("rendered") or "")) if isinstance(
                title_value, dict
            ) else ""
            title_score = self._title_score(song_title, title)
            if (
                len(lyrics.split()) < 8
                or not self._allowed_url(url)
                or title_score < 0.60
            ):
                continue
            ranked.append((title_score, RetrievedLyricsEvidence(
                candidate_id="pending",
                source=f"supersimple.com: {title}"[:128],
                url=url,
                text=unescape(lyrics)[: self.maximum_evidence_characters],
            )))
        ranked.sort(key=lambda value: (-value[0], value[1].url))
        return [
            RetrievedLyricsEvidence(
                candidate_id=f"web_{index + 1}",
                source=evidence.source,
                url=evidence.url,
                text=evidence.text,
            )
            for index, (_, evidence) in enumerate(ranked[: self.max_results])
        ]

    @staticmethod
    def _title_score(query: str, candidate: str) -> float:
        normalize = lambda value: " ".join(re.findall(r"[a-z0-9]+", value.lower()))
        left = normalize(query)
        right = normalize(candidate)
        if not left or not right:
            return 0.0
        if left == right:
            return 1.0
        return SequenceMatcher(None, left, right).ratio()

    def _fetch_page(self, client: httpx.Client, url: str, headers: dict) -> str:
        response = client.get(url, headers=headers, follow_redirects=False)
        if response.is_redirect:
            location = response.headers.get("location")
            redirected = urljoin(url, location) if location else ""
            if not self._allowed_url(redirected):
                return ""
            response = client.get(redirected, headers=headers, follow_redirects=False)
        response.raise_for_status()
        content_type = response.headers.get("content-type", "").lower()
        if "html" not in content_type and "text/plain" not in content_type:
            return ""
        parser = _VisibleTextParser()
        parser.feed(self._bounded_text(response))
        return parser.text(self.maximum_evidence_characters)

    def _bounded_text(self, response: httpx.Response) -> str:
        content = response.content
        if len(content) > self.maximum_response_bytes:
            content = content[: self.maximum_response_bytes]
        return content.decode(response.encoding or "utf-8", errors="replace")

    @staticmethod
    def _result_url(raw_url: str) -> str:
        absolute = urljoin("https://duckduckgo.com", raw_url)
        parsed = urlparse(absolute)
        if parsed.hostname and parsed.hostname.endswith("duckduckgo.com"):
            redirected = parse_qs(parsed.query).get("uddg", [""])[0]
            return unquote(redirected)
        return absolute

    @staticmethod
    def _allowed_url(url: str) -> bool:
        parsed = urlparse(url)
        if parsed.scheme != "https" or not parsed.hostname:
            return False
        host = parsed.hostname.lower().rstrip(".")
        return any(host == allowed or host.endswith(f".{allowed}") for allowed in ALLOWED_LYRICS_HOSTS)


__all__ = [
    "AllowlistedWebLyricsRetriever",
    "LyricsRetriever",
    "NoopLyricsRetriever",
    "RetrievedLyricsEvidence",
]
