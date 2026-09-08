#!/usr/bin/env python3
"""Fetch a bounded, public Tumblr archive and build RSS for PoemFeedParser.

Downloaded poem text stays under ignored test-output. The manifest contains
metadata only. This does not replace or emulate the app's HTML/verse parser.
"""

import argparse
from collections import Counter
from datetime import date, datetime, timedelta, timezone
from email.utils import format_datetime
import hashlib
import html
import json
from pathlib import Path
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from zoneinfo import ZoneInfo


BLOG = "https://apoemaday.tumblr.com"
PAGE_SIZE = 50
MAX_BYTES = 2_000_000
LEADING_HEADING = re.compile(r"\s*<h1\b[^>]*>(.*?)</h1\s*>", re.I | re.S)


def fetch(url, target, refresh):
    if target.exists() and not refresh:
        return target.read_bytes()
    request = urllib.request.Request(url, headers={"User-Agent": "PoemDesktop-Local-Layout-Audit/1.0"})
    with urllib.request.urlopen(request, timeout=45) as response:
        data = response.read(8_000_001)
    if len(data) > 8_000_000:
        raise RuntimeError(f"Unexpectedly large public archive response: {url}")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    return data


def decode_api(data):
    text = data.decode("utf-8")
    prefix = "var tumblr_api_read = "
    if not text.startswith(prefix):
        raise RuntimeError("Public Tumblr API did not return its expected JSON wrapper")
    return json.loads(text[len(prefix):].strip().removesuffix(";"))


def rss_fields(post):
    kind = post.get("type", "unknown")
    title = post.get("regular-title", "")
    body = post.get("regular-body", "")
    title_source = "regular-title" if title else "missing"
    if kind == "regular" and not title:
        heading = LEADING_HEADING.match(body)
        if heading:
            title = heading.group(1)
            body = body[heading.end():]
            title_source = "leading-h1 (Tumblr RSS convention)"
    elif kind != "regular":
        # Include these in the RSS and report them explicitly. They must never
        # disappear from the accounting merely because the app rejects them.
        title = post.get("link-text", "") or post.get("audio-title", "")
        body = next((post.get(key) for key in [
            "photo-caption", "video-caption", "audio-caption", "link-description",
            "quote-text", "conversation-text", "answer"
        ] if post.get(key)), "")
        title_source = "nontext-title" if title else "missing"
    return title, body, title_source


def item_for(post):
    title, body, _ = rss_fields(post)
    item = ET.Element("item")
    values = {
        "title": title,
        "description": body,
        "link": post["url"],
        "guid": post["url"],
        "pubDate": format_datetime(datetime.fromtimestamp(post["unix-timestamp"], timezone.utc)),
    }
    for name, value in values.items():
        ET.SubElement(item, name).text = value
    return item


def rss_document(posts):
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "A Poem A Day — local historical layout audit"
    ET.SubElement(channel, "link").text = BLOG
    ET.SubElement(channel, "description").text = "Public Tumblr archive normalized to its RSS fields."
    channel.extend(item_for(post) for post in posts)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def write_batches(posts, destination):
    destination.mkdir(parents=True, exist_ok=True)
    for old in destination.glob("batch-*.xml"):
        old.unlink()
    batches, pending = [], []

    def write(batch):
        data = rss_document(batch)
        filename = f"batch-{len(batches) + 1:03}.xml"
        (destination / filename).write_bytes(data)
        batches.append({"path": f"rss/{filename}", "itemCount": len(batch), "bytes": len(data)})

    for post in posts:
        candidate = pending + [post]
        if len(rss_document(candidate)) > MAX_BYTES:
            if not pending:
                raise RuntimeError(f"Single archive item exceeds feed limit: {post['id']}")
            write(pending)
            pending = [post]
            if len(rss_document(pending)) > MAX_BYTES:
                raise RuntimeError(f"Single archive item exceeds feed limit: {post['id']}")
        else:
            pending = candidate
        if len(pending) >= 50:
            write(pending)
            pending = []
    if pending:
        write(pending)
    return batches


def verify_against_live_rss(posts, data):
    by_id = {post["id"]: post for post in posts}
    comparisons = []
    for item in ET.fromstring(data).findall("channel/item"):
        link = item.findtext("link", "")
        match = re.search(r"/post/(\d+)", link)
        if not match or match.group(1) not in by_id:
            continue
        post = by_id[match.group(1)]
        title, body, _ = rss_fields(post)
        comparisons.append({
            "id": post["id"],
            "titleMatchesDecoded": html.unescape(title) == html.unescape(item.findtext("title", "")),
            "bodyMatchesExactly": body == item.findtext("description", ""),
        })
    return {
        "comparedItems": len(comparisons),
        "allMatch": bool(comparisons) and all(
            item["titleMatchesDecoded"] and item["bodyMatchesExactly"] for item in comparisons
        ),
        "comparisons": comparisons,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--start", type=date.fromisoformat, default=date(2025, 9, 7))
    parser.add_argument("--end", type=date.fromisoformat, default=date(2026, 9, 7))
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "test-output/year-audit")
    parser.add_argument("--max-pages", type=int, default=40)
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()
    if args.start > args.end or args.max_pages < 1:
        parser.error("Invalid interval or page limit")
    output = args.output.resolve()
    raw = output / "raw"
    raw.mkdir(parents=True, exist_ok=True)
    posts, ids, pages, duplicates, total_values = [], set(), [], [], set()
    passed_cutoff, exhausted, descending = False, False, True
    previous_timestamp = None
    site_timezone = None
    oldest_fetched = None
    for index in range(args.max_pages):
        start = index * PAGE_SIZE
        url = f"{BLOG}/api/read/json?num={PAGE_SIZE}&start={start}"
        page_path = raw / f"api-{start:05}.js"
        reused_cache = page_path.exists() and not args.refresh
        data = fetch(url, page_path, args.refresh)
        document = decode_api(data)
        if document.get("posts-start") != start:
            raise RuntimeError(f"Tumblr returned the wrong pagination offset for {url}")
        total_values.add(document["posts-total"])
        site_timezone = document["tumblelog"].get("timezone", "UTC")
        zone = ZoneInfo(site_timezone)
        retrieved = document["posts"]
        pages.append({"url": url, "offset": start, "count": len(retrieved),
                      "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                      "reusedLocalCache": reused_cache,
                      "localSourceSavedAt": datetime.fromtimestamp(page_path.stat().st_mtime, timezone.utc).isoformat()})
        for post in retrieved:
            stamp = post["unix-timestamp"]
            published = datetime.fromtimestamp(stamp, timezone.utc)
            day = published.astimezone(zone).date()
            oldest_fetched = day.isoformat()
            if previous_timestamp is not None and stamp > previous_timestamp:
                descending = False
            previous_timestamp = stamp
            if post["id"] in ids:
                duplicates.append(post["id"])
                continue
            ids.add(post["id"])
            if day < args.start:
                passed_cutoff = True
            if args.start <= day <= args.end:
                posts.append(post)
        print(f"Fetched public archive offset {start}: {len(retrieved)} posts, oldest {oldest_fetched}", flush=True)
        exhausted = not retrieved or start + len(retrieved) >= document["posts-total"]
        if passed_cutoff or exhausted:
            break
    posts.sort(key=lambda post: (post["unix-timestamp"], post["id"]), reverse=True)
    # Original field values and markup are retained separately from the adapted
    # RSS, so a layout failure can always be inspected against its actual source.
    (raw / "selected-posts.json").write_text(json.dumps(posts, ensure_ascii=False, indent=2) + "\n")
    batches = write_batches(posts, output / "rss")
    live_data = fetch(f"{BLOG}/rss", raw / "live-rss.xml", args.refresh)
    live_verification = verify_against_live_rss(posts, live_data)
    metadata = []
    for post in posts:
        title, body, title_source = rss_fields(post)
        published = datetime.fromtimestamp(post["unix-timestamp"], timezone.utc)
        metadata.append({
            "id": post["id"], "title": html.unescape(re.sub(r"<[^>]+>", "", title)),
            "date": published.astimezone(ZoneInfo(site_timezone)).date().isoformat(),
            "publishedAt": published.isoformat(), "type": post["type"], "url": post["url"],
            "canonicalURL": post.get("url-with-slug", post["url"]),
            "rssTitleSource": title_source, "hasBodyHTML": bool(body.strip()),
            "bodyHTMLBytes": len(body.encode("utf-8")),
            "sourceBodySHA256": hashlib.sha256(post.get("regular-body", "").encode("utf-8")).hexdigest(),
        })
    by_day = Counter(item["date"] for item in metadata)
    days = [(args.start + timedelta(days=number)).isoformat()
            for number in range((args.end - args.start).days + 1)]
    nontext = [item for item in metadata if item["type"] != "regular"]
    untitled = [item for item in metadata if not item["title"].strip()]
    empty = [item for item in metadata if not item["hasBodyHTML"]]
    complete = (passed_cutoff or exhausted) and descending and not duplicates and len(total_values) == 1
    manifest = {
        "retrievedAt": datetime.now(timezone.utc).isoformat(),
        "source": BLOG,
        "interval": {"startDate": args.start.isoformat(), "endDate": args.end.isoformat(),
                     "timezone": site_timezone, "inclusive": True},
        "coverageComplete": complete,
        "passedOldestCutoff": passed_cutoff,
        "reachedArchiveEnd": exhausted,
        "descendingChronologicalOrder": descending,
        "fetchedPages": len(pages),
        "fetchedPosts": sum(page["count"] for page in pages),
        "blogTotalPostsValues": sorted(total_values),
        "oldestFetchedPostDate": oldest_fetched,
        "totalPosts": len(posts),
        "regularPostCount": sum(item["type"] == "regular" for item in metadata),
        "expectedParsedCount": sum(bool(item["title"].strip()) and item["hasBodyHTML"] for item in metadata),
        "earliestPostDate": min(by_day) if by_day else None,
        "latestPostDate": max(by_day) if by_day else None,
        "missingCalendarDates": [day for day in days if day not in by_day],
        "multiplePostDates": {day: count for day, count in by_day.items() if count > 1},
        "duplicatePostIDs": duplicates,
        "nonTextPosts": nontext,
        "untitledPosts": untitled,
        "emptyBodyPosts": empty,
        "liveRSSVerification": live_verification,
        "rssBatches": batches,
        "pages": pages,
        "posts": metadata,
        "notes": [
            "Coverage is all public posts returned by the blog's archive in the inclusive interval; deleted/private posts are not observable.",
            "Missing calendar dates mean no public post was returned for that date; these are listed explicitly and not synthesized.",
            "For modern text posts, a leading h1 supplies the RSS title and is removed from the description, matching Tumblr's live RSS behavior.",
            "Original API responses and unmodified selected post objects are preserved in raw/; RSS is consumed by the app's actual PoemFeedParser.",
            "No archive text or downloaded poem fixtures should be committed to source control.",
            "Existing raw responses are reused unless --refresh is supplied; page metadata records cache reuse and local source timestamps.",
        ],
    }
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: manifest[key] for key in [
        "coverageComplete", "totalPosts", "regularPostCount", "expectedParsedCount",
        "earliestPostDate", "latestPostDate", "fetchedPages", "oldestFetchedPostDate"
    ]}, indent=2))
    print(f"Manifest: {output / 'manifest.json'}")
    if not complete or not live_verification["allMatch"]:
        print("Archive coverage or RSS normalization verification failed; inspect manifest.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
