#!/usr/bin/env python3
"""
Scrape shaders from godotshaders.com and save to JSON.

Fetches pages through a real headless Chromium (via Playwright) since the
site's WAF serves a JS challenge to any non-browser client, from any IP.
Run manually with `python scripts/scrape_shaders.py` (see README/CONTRIBUTING
for one-time setup), or via the weekly GitHub Actions workflow.
"""

import json
import re
import time
import os
import html
import unicodedata
from datetime import datetime, timezone
from urllib.parse import urljoin, urlparse
from typing import Optional, Dict, Any, List
from concurrent.futures import ThreadPoolExecutor, as_completed

# curl_cffi is only used as a last-resort fallback (see _fetch_via_jina below).
from curl_cffi import requests
from bs4 import BeautifulSoup, NavigableString

BASE_URL = "https://godotshaders.com"
SHADERS_URL = "https://godotshaders.com/shader/"

# godotshaders.com serves every non-browser HTTP client (plain requests, curl,
# even curl_cffi with a spoofed Chrome TLS fingerprint) a "Checking your
# browser..." JS challenge page (HTTP 454) instead of the real content -- this
# happens from ANY IP, including ordinary residential connections, so it is
# NOT an IP block. It's a JS challenge: the page only unlocks once a real
# browser executes its JavaScript. A real (headless) browser sails through it,
# see fetch_page() below. Jina's reader (r.jina.ai) is kept only as a fallback
# for environments where a Chromium binary isn't available (see
# _fetch_via_jina) -- it costs Jina API tokens (10M one-time free grant, then
# paid), while the Playwright path is free and works from any normal machine.
JINA_READER_PREFIX = "https://r.jina.ai/"
JINA_API_KEY = os.environ.get("JINA_API_KEY", "").strip()

# Output file path relative to script's parent directory (for github/data/)
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_FILE = os.path.join(SCRIPT_DIR, "..", "data", "shaders.json")
PAGES_TO_FETCH = 100  # High number, scraper auto-stops when page is empty
# Delay between requests, to be polite to the real site (we now hit it
# directly through a real browser instead of a third-party reader).
REQUEST_DELAY = 2.0
DETAIL_REQUEST_DELAY = 0.5  # Delay between detail page requests - increased
MAX_RETRIES = 3
RETRY_DELAY = 5.0  # Increased retry delay
FETCH_DETAILS = False  # Set to True to fetch full shader details (slower)
MAX_WORKERS = 5  # Concurrent detail fetches

# License filters - used to get accurate license info from website filters
# These slugs are from the website's CSS classes (e.g., shader_license-gnu_gpl3)
LICENSE_FILTERS = {
    "MIT": "https://godotshaders.com/shader/?shader_license=mit",
    "GNU GPL v.3": "https://godotshaders.com/shader/?shader_license=gnu_gpl3",
    "Shadertoy port": "https://godotshaders.com/shader/?shader_license=shadertoy_port",
    # CC0 is default - anything not in other categories
}

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
    # NOTE: Do NOT set Accept-Encoding manually - requests handles gzip/deflate automatically
    # Setting it manually causes raw compressed bytes to be returned instead of decompressed content
    "Connection": "keep-alive",
    "Upgrade-Insecure-Requests": "1",
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Sec-Fetch-User": "?1",
    "Cache-Control": "max-age=0",
}

# Create a session that impersonates a recent Chrome (TLS fingerprint + headers).
# This is what lets us past the WAF that returns 454 to plain `requests`.
session = requests.Session(impersonate="chrome")
session.headers.update(HEADERS)


def clean_text(text: str) -> str:
    """
    Clean text by decoding HTML entities and normalizing characters.
    Handles: &amp;#8220; -> ", &amp;#8221; -> ", &amp;quot; -> ", etc.
    """
    if not text:
        return ""
    
    # First pass: decode HTML entities (handles &#8220; &#8221; &quot; &amp; etc.)
    text = html.unescape(text)
    
    # Second pass: sometimes entities are double-encoded
    text = html.unescape(text)
    
    # Normalize Unicode characters (NFKC normalizes fancy quotes to regular)
    # But we want to preserve some special chars, so use NFC
    text = unicodedata.normalize("NFC", text)
    
    # Replace common problematic characters
    replacements = {
        "\u2018": "'",   # Left single quote
        "\u2019": "'",   # Right single quote  
        "\u201c": '"',   # Left double quote
        "\u201d": '"',   # Right double quote
        "\u2013": "-",   # En dash
        "\u2014": "-",   # Em dash
        "\u2026": "...", # Ellipsis
        "\u00a0": " ",   # Non-breaking space
        "\r\n": "\n",    # Windows line endings
        "\r": "\n",      # Old Mac line endings
    }
    
    for old, new in replacements.items():
        text = text.replace(old, new)
    
    # Remove zero-width and invisible characters
    text = re.sub(r'[\u200b-\u200d\ufeff]', '', text)
    
    # Clean up excessive whitespace (but preserve newlines for descriptions)
    text = re.sub(r'[ \t]+', ' ', text)  # Multiple spaces/tabs to single space
    text = re.sub(r'\n{3,}', '\n\n', text)  # Max 2 newlines
    
    return text.strip()


def clean_shader_code(code: str) -> str:
    """Clean shader code specifically - preserves formatting."""
    if not code:
        return ""
    
    # Decode HTML entities
    code = html.unescape(code)
    code = html.unescape(code)  # Double pass for double-encoded
    
    # Normalize line endings
    code = code.replace("\r\n", "\n").replace("\r", "\n")
    
    # Remove trailing whitespace from each line
    lines = [line.rstrip() for line in code.split("\n")]
    code = "\n".join(lines)
    
    # Remove leading/trailing empty lines
    code = code.strip("\n")
    
    return code


def validate_url(url: str) -> bool:
    """Validate that a URL is properly formed."""
    try:
        result = urlparse(url)
        return all([result.scheme in ('http', 'https'), result.netloc])
    except Exception:
        return False


def safe_get_text(element, default: str = "") -> str:
    """Safely extract and clean text from a BeautifulSoup element."""
    if element is None:
        return default
    try:
        text = element.get_text(strip=True)
        return clean_text(text)
    except Exception:
        return default


_browser_state: Dict[str, Any] = {}


def _get_browser_page():
    """Lazily launch one headless Chromium instance and reuse its single page
    for every fetch (the script fetches pages sequentially, so one tab is
    enough and avoids the overhead of relaunching a browser per request)."""
    if "page" in _browser_state:
        return _browser_state["page"]
    try:
        from playwright.sync_api import sync_playwright
    except ImportError as e:
        raise RuntimeError(
            "playwright is not installed. Run: pip install -r requirements.txt "
            "&& python -m playwright install chromium"
        ) from e
    pw = sync_playwright().start()
    try:
        browser = pw.chromium.launch(headless=True)
    except Exception as e:
        pw.stop()
        raise RuntimeError(
            "Chromium isn't installed for Playwright. Run: "
            "python -m playwright install chromium"
        ) from e
    context = browser.new_context(user_agent=HEADERS["User-Agent"], locale="en-US")
    page = context.new_page()
    _browser_state.update(playwright=pw, browser=browser, context=context, page=page)
    return page


def close_browser() -> None:
    """Release the Playwright browser. Call once at the end of a run."""
    browser = _browser_state.pop("browser", None)
    pw = _browser_state.pop("playwright", None)
    _browser_state.pop("context", None)
    _browser_state.pop("page", None)
    if browser is not None:
        try:
            browser.close()
        except Exception:
            pass
    if pw is not None:
        try:
            pw.stop()
        except Exception:
            pass


def _fetch_via_jina(url: str) -> Optional[str]:
    """Last-resort fallback when no Chromium binary is available: fetch through
    Jina's reader (r.jina.ai). Costs Jina API tokens (free grant is one-time,
    10M tokens, then paid) -- only used if the Playwright path above fails."""
    if not JINA_API_KEY:
        return None
    proxied = JINA_READER_PREFIX + url
    req_headers = {"X-Return-Format": "html", "Authorization": f"Bearer {JINA_API_KEY}"}
    try:
        response = session.get(proxied, headers=req_headers, timeout=90)
        response.raise_for_status()
        return response.text
    except Exception as e:
        print(f"    Jina fallback also failed for {url}: {e}")
        return None


def fetch_page(url: str, retries: int = MAX_RETRIES) -> Optional[str]:
    """Fetch a page's rendered HTML using a real headless browser.

    godotshaders.com's WAF serves a JS challenge to non-browser clients from
    any IP; a real (headless) Chromium instance runs the challenge's
    JavaScript like a normal visitor would and gets the real page back.
    """
    for attempt in range(retries):
        try:
            page = _get_browser_page()
            page.goto(url, wait_until="domcontentloaded", timeout=45000)
            # The WAF briefly shows a "Checking your browser..." interstitial
            # before its JS unlocks the real page; give that a moment, then
            # fall through even if the selector never shows up (a genuinely
            # empty results page has no cards either).
            try:
                page.wait_for_selector(
                    "article.gds-shader-card, .entry-content, .gds-empty-state",
                    timeout=15000,
                )
            except Exception:
                pass
            content = page.content()
            if "Checking your browser" in content and "gds-shader-card" not in content:
                raise RuntimeError("still on the WAF challenge page")
            return content
        except Exception as e:
            if attempt < retries - 1:
                print(f"    Retry {attempt + 1}/{retries} for {url}: {e}")
                time.sleep(RETRY_DELAY * (attempt + 1))
            else:
                print(f"    Playwright failed after {retries} attempts for {url}: {e}")
                fallback = _fetch_via_jina(url)
                if fallback:
                    print(f"    Recovered {url} via Jina fallback")
                return fallback
    return None

def parse_shader_card(article) -> Optional[Dict[str, Any]]:
    """Parse a single shader card (article element)."""
    shader = {}
    
    # Get main link
    link = article.select_one("a.gds-shader-card__link")
    if not link:
        return None
    
    url = link.get("href", "")
    if not url or "/shader/" not in url:
        return None
    
    # Validate and normalize URL
    if not url.startswith("http"):
        url = urljoin(BASE_URL, url)
    
    if not validate_url(url):
        return None
    
    shader["url"] = url
    
    # Title - clean HTML entities
    title_elem = article.select_one(".gds-shader-card__title")
    if title_elem:
        shader["title"] = safe_get_text(title_elem)
    else:
        return None
    
    if not shader["title"]:
        return None
    
    # Author
    author_elem = article.select_one(".gds-shader-card__author")
    shader["author"] = safe_get_text(author_elem, "Unknown")
    
    # Cover image (from background-image style, video poster, or img element)
    cover = article.select_one(".gds-shader-card__cover")
    if cover:
        style = cover.get("style", "")
        match = re.search(r'url\(["\']?([^)"\']+)["\']?\)', style)
        if match:
            img_url = match.group(1)
            if img_url and not img_url.startswith("http"):
                img_url = urljoin(BASE_URL, img_url)
            if validate_url(img_url):
                shader["image_url"] = img_url

        if "image_url" not in shader:
            video = cover.find("video")
            if video:
                poster = video.get("poster", "")
                if poster:
                    if not poster.startswith("http"):
                        poster = urljoin(BASE_URL, poster)
                    if validate_url(poster):
                        shader["image_url"] = poster

        if "image_url" not in shader:
            img = cover.find("img")
            if img:
                src = img.get("src", "")
                if src and not src.startswith("data:"):
                    if not src.startswith("http"):
                        src = urljoin(BASE_URL, src)
                    if validate_url(src):
                        shader["image_url"] = src
    
    # Category/Type (SPATIAL, CANVAS ITEM, etc.)
    type_elem = article.select_one(".gds-shader-card__type")
    if type_elem:
        category = safe_get_text(type_elem).upper()
        # Normalize category names
        category_map = {
            "CANVAS ITEM": "CANVAS_ITEM",
            "CANVASITEM": "CANVAS_ITEM",
            "SPATIAL": "SPATIAL",
            "SKY": "SKY",
            "PARTICLES": "PARTICLES",
            "FOG": "FOG",
        }
        shader["category"] = category_map.get(category, category)
    else:
        shader["category"] = ""
    
    # Likes (from stats)
    like_stat = article.select_one(".gds-shader-card__like .gds-shader-card__stat-num")
    if like_stat:
        likes_text = safe_get_text(like_stat, "0")
        # Parse likes (handle "1.2k" format)
        try:
            if 'k' in likes_text.lower():
                shader["likes"] = int(float(likes_text.lower().replace('k', '')) * 1000)
            else:
                shader["likes"] = int(likes_text)
        except ValueError:
            shader["likes"] = 0
    else:
        shader["likes"] = 0
    
    # Extract video URL from cover element (separate from image_url)
    if cover:
        video_elem = cover.find("video")
        if video_elem:
            video_src = video_elem.get("src", "")
            if not video_src:
                source_elem = video_elem.find("source")
                if source_elem:
                    video_src = source_elem.get("src", "")
            if video_src and not video_src.startswith("data:"):
                if not video_src.startswith("http"):
                    video_src = urljoin(BASE_URL, video_src)
                if validate_url(video_src):
                    shader["video_url"] = video_src

    # Default values for fields that require detail page
    shader["license"] = "CC0"
    shader["description"] = ""
    shader["tags"] = []
    shader["shader_code"] = ""
    if "video_url" not in shader:
        shader["video_url"] = ""

    return shader


def fetch_shader_details(shader: Dict[str, Any]) -> Dict[str, Any]:
    """Fetch detailed information from the shader's page."""
    url = shader.get("url")
    if not url:
        return shader
    
    html_content = fetch_page(url)
    if not html_content:
        return shader
    
    try:
        soup = BeautifulSoup(html_content, "html.parser")
        
        # Description - usually in the main content area before shader code
        # Look for paragraphs in the main content
        content_area = soup.select_one(".entry-content, .gds-shader-content, article")
        if content_area:
            # Get paragraphs that appear before the shader code section
            description_parts = []
            for elem in content_area.children:
                if isinstance(elem, NavigableString):
                    continue
                # Stop at shader code section
                if elem.name in ['pre', 'code'] or (elem.get('class') and any('code' in c.lower() for c in elem.get('class', []))):
                    break
                if elem.name == 'h5' and 'shader code' in elem.get_text().lower():
                    break
                if elem.name == 'p':
                    text = safe_get_text(elem)
                    if text and len(text) > 10:  # Skip very short fragments
                        description_parts.append(text)
            
            if description_parts:
                shader["description"] = "\n\n".join(description_parts[:5])  # Max 5 paragraphs
        
        # Tags
        tags = []
        tag_links = soup.select('a[href*="/shader-tag/"]')
        for tag_link in tag_links:
            tag_text = safe_get_text(tag_link)
            if tag_text and tag_text not in tags:
                tags.append(tag_text)
        shader["tags"] = tags
        
        # License - look for license info by checking images and text
        license_text = "CC0"  # Default
        
        # Check for license indicator images (most reliable)
        license_images = soup.select('img[src*="license"], img[src*="shadertoy"], img[src*="gpl"]')
        for img in license_images:
            src = img.get('src', '').lower()
            if 'mit' in src:
                license_text = "MIT"
                break
            elif 'shadertoy' in src:
                license_text = "Shadertoy port"
                break
            elif 'gpl' in src:
                license_text = "GNU GPL v.3"
                break
            elif 'cc0' in src:
                license_text = "CC0"
                break
        
        # If no image found, check official license section text only
        # (NOT the whole page - to avoid matching license comments in shader code)
        if license_text == "CC0":  # Still default, check text
            # Look for the official license notice section
            license_notice = soup.select_one('.entry-content p:last-of-type, .shader-license, .license-info')
            if license_notice:
                notice_text = license_notice.get_text().lower()
            else:
                # Fallback: search for the standard license text pattern
                notice_text = ""
                for p in soup.select('p'):
                    p_text = p.get_text().lower()
                    if "under" in p_text and "license" in p_text:
                        notice_text = p_text
                        break
            
            # Check for specific license mentions in official notice
            if "gnu gpl" in notice_text or "gnu general public license" in notice_text:
                license_text = "GNU GPL v.3"
            elif "shadertoy" in notice_text and ("cc by-nc-sa" in notice_text or "attribution-noncommercial" in notice_text):
                license_text = "Shadertoy port"
            elif "mit license" in notice_text or "under mit" in notice_text:
                license_text = "MIT"
            # CC0 remains default if nothing else matches (official licenses: CC0, MIT, Shadertoy, GPL)
        
        shader["license"] = license_text
        
        # Shader code - from code block
        code_block = soup.select_one("pre code, .wp-block-code code, pre.wp-block-code")
        if code_block:
            shader["shader_code"] = clean_shader_code(code_block.get_text())
        else:
            # Try alternative selectors
            for selector in ["pre", ".shader-code", "code"]:
                elem = soup.select_one(selector)
                if elem:
                    text = elem.get_text()
                    if "shader_type" in text:  # Verify it's shader code
                        shader["shader_code"] = clean_shader_code(text)
                        break
        
        # Video URL from detail page (overrides or fills missing video_url)
        if not shader.get("video_url"):
            video_elem = soup.find("video")
            if video_elem:
                video_src = video_elem.get("src", "")
                if not video_src:
                    source_elem = video_elem.find("source")
                    if source_elem:
                        video_src = source_elem.get("src", "")
                if video_src and not video_src.startswith("data:"):
                    if not video_src.startswith("http"):
                        video_src = urljoin(BASE_URL, video_src)
                    if validate_url(video_src):
                        shader["video_url"] = video_src

        # Publication date
        date_elem = soup.select_one("time[datetime], .entry-date, .post-date, .gds-shader-date")
        if date_elem:
            datetime_attr = date_elem.get("datetime")
            if datetime_attr:
                shader["published_date"] = datetime_attr
            else:
                shader["published_date"] = safe_get_text(date_elem)
        
        # Author link/profile
        author_link = soup.select_one('a[href*="/author/"]')
        if author_link:
            shader["author_url"] = author_link.get("href", "")
            # Update author name if we have a better source
            author_name = safe_get_text(author_link)
            if author_name:
                shader["author"] = author_name
        
    except Exception as e:
        print(f"    Error parsing details for {url}: {e}")
    
    return shader


def fetch_missing_media(shaders: List[Dict[str, Any]]) -> None:
    """Fetch og:image (and, opportunistically, video_url) for shaders missing an image.

    Only shaders MISSING AN IMAGE trigger a detail-page fetch. Previously we also
    chased missing video_url, but most shaders have no video, so that meant a
    per-shader fetch for almost the entire library — thousands of requests, which
    is fatal through the rate-limited Jina reader (the July run only reached
    390/2200 before failures cascaded). GIF previews already get video_url from
    the GIF logic, and listing-level <video> is captured in parse_shader_card, so
    skipping the standalone video hunt costs only a handful of rare detail videos.
    """
    to_fetch = [s for s in shaders if not s.get("image_url")]
    if not to_fetch:
        return

    print(f"\nFetching media for {len(to_fetch)} shaders with a missing image...", flush=True)

    for shader in to_fetch:
        url = shader.get("url")
        if not url:
            continue

        html_content = fetch_page(url)
        if not html_content:
            time.sleep(REQUEST_DELAY)
            continue

        soup = BeautifulSoup(html_content, "html.parser")

        # --- Image URL (only if missing) ---
        if not shader.get("image_url"):
            img_url = ""

            og_image = soup.find("meta", property="og:image")
            if og_image:
                img_url = og_image.get("content", "")

            if not img_url:
                tw_image = soup.find("meta", attrs={"name": "twitter:image"})
                if tw_image:
                    img_url = tw_image.get("content", "")

            if not img_url:
                video = soup.find("video")
                if video:
                    img_url = video.get("poster", "")  # poster is an image, not video

            if img_url and validate_url(img_url):
                shader["image_url"] = img_url
                print(f"  Found thumbnail for: {shader['title']}", flush=True)
            else:
                print(f"  No thumbnail found for: {shader['title']}", flush=True)

        # --- Video URL (only if missing) ---
        if not shader.get("video_url"):
            video = soup.find("video")
            if video:
                video_src = video.get("src", "")
                if not video_src:
                    source = video.find("source")
                    if source:
                        video_src = source.get("src", "")
                if video_src and not video_src.startswith("data:"):
                    if not video_src.startswith("http"):
                        video_src = urljoin(BASE_URL, video_src)
                    if validate_url(video_src):
                        shader["video_url"] = video_src
                        print(f"  Found video for: {shader['title']}", flush=True)

        time.sleep(REQUEST_DELAY)


def build_license_mapping() -> Dict[str, str]:
    """Build URL to license mapping by scraping filtered pages.
    
    This is 100% accurate because it uses the website's own license filters.
    """
    url_to_license = {}
    
    print("Building license mapping from website filters...", flush=True)
    
    for license_name, filter_url in LICENSE_FILTERS.items():
        print(f"  Fetching {license_name} shaders...", flush=True)
        page = 1
        license_count = 0
        seen_this_license = set()  # Track seen URLs to detect pagination loops
        
        lic_failures = 0
        while page <= PAGES_TO_FETCH:
            if page == 1:
                url = filter_url
            else:
                # Pagination format: /shader/page/N/?shader_license=xxx
                # Extract query string from filter_url
                if '?' in filter_url:
                    base, query = filter_url.split('?', 1)
                    url = f"{base}page/{page}/?{query}"
                else:
                    url = f"{filter_url}page/{page}/"

            html_content = fetch_page(url)
            if not html_content:
                # Transient failure — skip this page, don't abandon the license.
                lic_failures += 1
                if lic_failures >= 5:
                    break
                page += 1
                time.sleep(REQUEST_DELAY)
                continue
            lic_failures = 0

            soup = BeautifulSoup(html_content, "html.parser")
            articles = soup.select("article.gds-shader-card")
            
            if not articles:
                break
            
            # Track new URLs on this page
            new_on_page = 0
            for article in articles:
                link = article.select_one("a.gds-shader-card__link")
                if link:
                    shader_url = link.get("href", "")
                    if shader_url and "/shader/" in shader_url:
                        if shader_url not in seen_this_license:
                            seen_this_license.add(shader_url)
                            url_to_license[shader_url] = license_name
                            license_count += 1
                            new_on_page += 1
            
            # If no new URLs were found, we've hit pagination loop - stop
            if new_on_page == 0:
                break
            
            page += 1
            time.sleep(REQUEST_DELAY)
        
        print(f"    Found {license_count} {license_name} shaders", flush=True)
    
    print(f"  Total non-CC0 shaders mapped: {len(url_to_license)}", flush=True)
    return url_to_license


def scrape_all_shaders() -> List[Dict[str, Any]]:
    """Scrape all shader pages."""
    all_shaders = []
    seen_urls = set()
    errors = []
    
    # Build license mapping first (100% accurate from website filters)
    license_mapping = build_license_mapping()
    
    print(f"\nFetching shader list from {PAGES_TO_FETCH} pages...", flush=True)

    # A failed fetch (Jina timeout / transient rate-limit) must NOT be mistaken
    # for "no more pages" — otherwise one flaky page truncates the whole scrape
    # (that's how the July run stopped at 390/2200). Skip failed pages and only
    # give up after several consecutive failures.
    consecutive_failures = 0
    MAX_CONSECUTIVE_FAILURES = 5

    for page in range(1, PAGES_TO_FETCH + 1):
        if page == 1:
            url = SHADERS_URL
        else:
            url = f"{SHADERS_URL}page/{page}/"

        print(f"Fetching page {page}/{PAGES_TO_FETCH}: {url}", flush=True)

        try:
            html_content = fetch_page(url)
            if not html_content:
                consecutive_failures += 1
                print(f"  Failed to fetch page {page} "
                      f"({consecutive_failures}/{MAX_CONSECUTIVE_FAILURES} consecutive)")
                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                    print("  Too many consecutive failures, stopping pagination")
                    break
                time.sleep(REQUEST_DELAY)
                continue
            consecutive_failures = 0

            soup = BeautifulSoup(html_content, "html.parser")
            
            # Find shader cards (article elements)
            articles = soup.select("article.gds-shader-card")
            page_count = 0
            
            for article in articles:
                try:
                    shader = parse_shader_card(article)
                    if shader and shader.get("title") and shader.get("url"):
                        # Avoid duplicates
                        if shader["url"] not in seen_urls:
                            seen_urls.add(shader["url"])
                            all_shaders.append(shader)
                            page_count += 1
                except Exception as e:
                    errors.append(f"Error parsing shader card on page {page}: {e}")
            
            print(f"  Found {page_count} shaders, total: {len(all_shaders)}", flush=True)
            
            # Check if we've reached the last page
            if len(articles) == 0:
                print(f"  No more shaders, stopping at page {page}")
                break
                
        except Exception as e:
            errors.append(f"Error on page {page}: {e}")
            print(f"  Error on page {page}: {e}")
        
        # Be nice to the server
        time.sleep(REQUEST_DELAY)
    
    # Fetch detailed information for each shader
    if FETCH_DETAILS and all_shaders:
        print(f"\nFetching details for {len(all_shaders)} shaders...", flush=True)
        
        def fetch_with_delay(shader_data):
            """Wrapper to add delay and error handling."""
            try:
                result = fetch_shader_details(shader_data)
                time.sleep(DETAIL_REQUEST_DELAY)
                return result
            except Exception as e:
                print(f"  Error fetching details for {shader_data.get('title', 'unknown')}: {e}")
                return shader_data
        
        # Process in batches to show progress
        batch_size = 50
        for i in range(0, len(all_shaders), batch_size):
            batch = all_shaders[i:i + batch_size]
            print(f"  Processing shaders {i + 1}-{min(i + batch_size, len(all_shaders))}...", flush=True)
            
            # Sequential processing to be nice to the server
            for j, shader in enumerate(batch):
                try:
                    all_shaders[i + j] = fetch_shader_details(shader)
                    if (i + j + 1) % 10 == 0:
                        print(f"    Completed {i + j + 1}/{len(all_shaders)}", flush=True)
                except Exception as e:
                    errors.append(f"Error fetching details for {shader.get('title', 'unknown')}: {e}")
                time.sleep(DETAIL_REQUEST_DELAY)
    
    # Fetch thumbnails and video URLs for shaders missing media
    fetch_missing_media(all_shaders)

    # GIF image_urls are animated previews - treat them as video_url too
    gif_video_count = 0
    for shader in all_shaders:
        img = shader.get("image_url", "")
        if img.lower().endswith(".gif") and not shader.get("video_url"):
            shader["video_url"] = img
            gif_video_count += 1
    if gif_video_count:
        print(f"\nMarked {gif_video_count} GIF previews as video_url.", flush=True)

    # Apply accurate license from mapping (overrides any parsed value)
    # This runs regardless of FETCH_DETAILS setting
    print("\nApplying accurate license information from website filters...", flush=True)
    for shader in all_shaders:
        url = shader.get("url", "")
        if url in license_mapping:
            shader["license"] = license_mapping[url]
        else:
            shader["license"] = "CC0"  # Default for anything not in other categories
    
    if errors:
        print(f"\nEncountered {len(errors)} errors during scraping")
        for error in errors[:10]:  # Show first 10 errors
            print(f"  - {error}")
        if len(errors) > 10:
            print(f"  ... and {len(errors) - 10} more")
    
    return all_shaders

def validate_shader_data(shader: Dict[str, Any]) -> bool:
    """Validate that a shader has required fields."""
    required = ["url", "title"]
    for field in required:
        if not shader.get(field):
            return False
    
    if not validate_url(shader.get("url", "")):
        return False
    
    return True


def sanitize_for_json(obj: Any) -> Any:
    """Ensure all data is JSON-serializable and clean."""
    if isinstance(obj, dict):
        return {k: sanitize_for_json(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [sanitize_for_json(item) for item in obj]
    elif isinstance(obj, str):
        return clean_text(obj)
    elif isinstance(obj, (int, float, bool, type(None))):
        return obj
    else:
        return str(obj)


def main():
    print("=" * 60)
    print("Starting shader scrape...")
    print("=" * 60)
    now = datetime.now(timezone.utc)
    print(f"Date: {now.isoformat()}")
    print(f"Fetch details: {FETCH_DETAILS}")
    print()
    
    try:
        shaders = scrape_all_shaders()
    finally:
        close_browser()

    # Validate all shaders
    valid_shaders = []
    invalid_count = 0
    for shader in shaders:
        if validate_shader_data(shader):
            valid_shaders.append(shader)
        else:
            invalid_count += 1
    
    if invalid_count > 0:
        print(f"\nRemoved {invalid_count} invalid shaders")
    
    # Sanitize all data for JSON
    valid_shaders = sanitize_for_json(valid_shaders)
    
    print(f"\nTotal valid shaders: {len(valid_shaders)}")
    
    # Statistics
    categories = {}
    licenses = {}
    with_code = 0
    with_description = 0
    with_tags = 0
    with_image = 0
    with_video = 0

    for shader in valid_shaders:
        cat = shader.get("category", "UNKNOWN")
        categories[cat] = categories.get(cat, 0) + 1

        lic = shader.get("license", "UNKNOWN")
        licenses[lic] = licenses.get(lic, 0) + 1

        if shader.get("shader_code"):
            with_code += 1
        if shader.get("description"):
            with_description += 1
        if shader.get("tags"):
            with_tags += 1
        if shader.get("image_url"):
            with_image += 1
        if shader.get("video_url"):
            with_video += 1

    print("\nStatistics:")
    print(f"  Shaders with code: {with_code}")
    print(f"  Shaders with description: {with_description}")
    print(f"  Shaders with tags: {with_tags}")
    print(f"  Shaders with image: {with_image}")
    print(f"  Shaders with video: {with_video}")
    print(f"\nCategories:")
    for cat, count in sorted(categories.items(), key=lambda x: -x[1]):
        print(f"  {cat}: {count}")
    print(f"\nLicenses:")
    for lic, count in sorted(licenses.items(), key=lambda x: -x[1]):
        print(f"  {lic}: {count}")
    
    # Ensure output directory exists
    os.makedirs(os.path.dirname(OUTPUT_FILE), exist_ok=True)
    
    # Save to JSON with proper encoding
    data = {
        "timestamp": int(now.timestamp()),
        "date": now.isoformat(),
        "count": len(valid_shaders),
        "fetch_details": FETCH_DETAILS,
        "shaders": valid_shaders
    }
    
    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    
    print(f"\nSaved to {OUTPUT_FILE}")
    print("=" * 60)
    print("Done!")
    print("=" * 60)


if __name__ == "__main__":
    main()
