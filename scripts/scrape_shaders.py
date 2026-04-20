#!/usr/bin/env python3
"""
Scrape shaders from godotshaders.com and save to JSON.
This runs via GitHub Actions once daily.
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

import requests
from bs4 import BeautifulSoup, NavigableString

BASE_URL = "https://godotshaders.com"
SHADERS_URL = "https://godotshaders.com/shader/"
# Output file path relative to script's parent directory (for github/data/)
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_FILE = os.path.join(SCRIPT_DIR, "..", "data", "shaders.json")
PAGES_TO_FETCH = 100  # High number, scraper auto-stops when page is empty
REQUEST_DELAY = 1.0  # Be nice to the server - increased to avoid WAF
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

# Create a session for connection reuse
session = requests.Session()
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


def fetch_page(url: str, retries: int = MAX_RETRIES) -> Optional[str]:
    """Fetch a page with proper headers and retry logic."""
    for attempt in range(retries):
        try:
            response = session.get(url, timeout=30)
            response.raise_for_status()
            
            # Try to detect encoding issues
            response.encoding = response.apparent_encoding or 'utf-8'
            
            return response.text
        except requests.exceptions.RequestException as e:
            if attempt < retries - 1:
                print(f"    Retry {attempt + 1}/{retries} for {url}: {e}")
                time.sleep(RETRY_DELAY * (attempt + 1))
            else:
                print(f"    Failed after {retries} attempts: {url}")
                return None
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
    
    # Cover image (from background-image style)
    cover = article.select_one(".gds-shader-card__cover")
    if cover:
        style = cover.get("style", "")
        match = re.search(r'url\(["\']?([^)"\']+)["\']?\)', style)
        if match:
            img_url = match.group(1)
            # Handle relative URLs
            if img_url and not img_url.startswith("http"):
                img_url = urljoin(BASE_URL, img_url)
            if validate_url(img_url):
                shader["image_url"] = img_url
    
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
    
    # Default values for fields that require detail page
    shader["license"] = "CC0"
    shader["description"] = ""
    shader["tags"] = []
    shader["shader_code"] = ""
    
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
                break
                
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
    
    for page in range(1, PAGES_TO_FETCH + 1):
        if page == 1:
            url = SHADERS_URL
        else:
            url = f"{SHADERS_URL}page/{page}/"
        
        print(f"Fetching page {page}/{PAGES_TO_FETCH}: {url}", flush=True)
        
        try:
            html_content = fetch_page(url)
            if not html_content:
                # Failed to fetch - likely 404 (no more pages)
                print(f"  Failed to fetch page {page}, stopping pagination")
                break
                
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
    
    shaders = scrape_all_shaders()
    
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
    
    print("\nStatistics:")
    print(f"  Shaders with code: {with_code}")
    print(f"  Shaders with description: {with_description}")
    print(f"  Shaders with tags: {with_tags}")
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
