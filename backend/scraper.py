import aiohttp
from bs4 import BeautifulSoup
import re
from urllib.parse import urljoin


class NovelCoolScraper:
    def __init__(self):
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
        }

    async def scrape_chapter(self, url: str):
        async with aiohttp.ClientSession() as session:
            async with session.get(url, headers=self.headers) as response:
                if response.status != 200:
                    raise Exception(f"Failed to fetch page: {response.status}")
                html = await response.text()

        # NovelCool pages can be large; lxml parser is more reliable here.
        soup = BeautifulSoup(html, 'lxml')

        # Extract Title
        title = "Unknown Chapter"
        title_tag = soup.find('h1')
        if title_tag:
            title = title_tag.get_text(strip=True)
        else:
            page_title = soup.find('title')
            if page_title:
                t = page_title.get_text(strip=True)
                # e.g. "Shadow Slave Chapter 15 - Novel Cool - Best online light novel reading website"
                title = t.split(' - Novel Cool', 1)[0].strip() or t

        # Extract Content
        # In the HTML variant commonly returned to scripted clients, the actual
        # chapter content lives under: div.site-content > div.overflow-hidden
        content_div = soup.select_one('div.site-content div.overflow-hidden')

        if not content_div:
            # Fallback: pick the div with the most <p> tags.
            best = None
            best_count = 0
            for div in soup.find_all('div'):
                ps = div.find_all('p')
                if len(ps) > best_count:
                    best_count = len(ps)
                    best = div
            content_div = best

        if not content_div:
            raise Exception("Could not find chapter content container")

        paragraphs = []
        for p in content_div.find_all('p'):
            classes = p.get('class') or []
            txt = p.get_text(' ', strip=True)
            if not txt:
                continue
            if 'chapter-end-mark' in classes or txt.lower().strip() == 'chapter end':
                break
            paragraphs.append(txt)

        if not paragraphs:
            raw_text = content_div.get_text(separator='\n', strip=True)
            paragraphs = [line for line in raw_text.split('\n') if line.strip()]

        content = "\n".join(paragraphs)

        # Extract Next/Prev Links
        next_link = None
        prev_link = None

        for a in soup.find_all('a', href=True):
            t = a.get_text(" ", strip=True)
            href = a.get('href')
            if not href:
                continue
            if '/chapter/' not in href:
                continue
            if not next_link and 'Next' in t:
                next_link = href
            if not prev_link and 'Prev' in t:
                prev_link = href
            if next_link and prev_link:
                break

        if next_link:
            next_link = urljoin(url, next_link)
        if prev_link:
            prev_link = urljoin(url, prev_link)

        return {
            "title": title,
            "content": paragraphs, # Return list of paragraphs for easier chunking
            "next_url": next_link,
            "prev_url": prev_link
        }

    async def scrape_novel_index(self, novel_url: str):
        """Scrape a NovelCool novel page and return a list of chapter links."""
        async with aiohttp.ClientSession() as session:
            async with session.get(novel_url, headers=self.headers) as response:
                if response.status != 200:
                    raise Exception(f"Failed to fetch page: {response.status}")
                html = await response.text()

        soup = BeautifulSoup(html, 'lxml')
        links = []
        seen = set()

        def parse_chapter_number(title: str, url: str) -> int | None:
            t = (title or '').strip()
            # Best-effort chapter number parsing from visible text.
            m = re.search(r"(?:\bChapter\b|\bCh\.?\b|\bC\b)\s*(\d+)", t, flags=re.IGNORECASE)
            if m:
                try:
                    n = int(m.group(1))
                    return n if n > 0 else None
                except Exception:
                    pass

            # Fallback: parse from URL, e.g.
            # /chapter/<Novel>-Chapter-15/<id>/ or .../Chapter_15/... etc.
            u = (url or '')
            m = re.search(r"(?:chapter|ch)[^0-9]{0,12}(\d+)", u, flags=re.IGNORECASE)
            if m:
                try:
                    n = int(m.group(1))
                    return n if n > 0 else None
                except Exception:
                    pass
            return None

        for a in soup.find_all('a', href=True):
            href = a.get('href')
            if not href:
                continue
            if '/chapter/' not in href:
                continue
            abs_url = urljoin(novel_url, href)
            if abs_url in seen:
                continue
            title = a.get_text(' ', strip=True)
            if not title:
                # Some chapter links have empty text (icons). Skip but do NOT
                # mark as seen — the real link with text may appear later.
                continue
            seen.add(abs_url)
            n = parse_chapter_number(title, abs_url)
            links.append({"n": n, "title": title, "url": abs_url})

        # Sort by chapter number when possible, but preserve stable ordering
        # for unknowns (avoid pushing an unparsed Chapter 1 to the end).
        def chapter_key(item):
            n = item.get('n')
            if isinstance(n, int):
                return (0, n)
            return (1, 0)

        links.sort(key=chapter_key)
        return links

    async def scrape_novel_details(self, novel_url: str):
        """Scrape a NovelCool novel page and return lightweight metadata.

        Currently returns:
        - title: best-effort title
        - cover_url: absolute URL to the cover image, when detectable
        """
        async with aiohttp.ClientSession() as session:
            async with session.get(novel_url, headers=self.headers) as response:
                if response.status != 200:
                    raise Exception(f"Failed to fetch page: {response.status}")
                html = await response.text()

        soup = BeautifulSoup(html, 'lxml')

        title = None
        t = soup.find('title')
        if t:
            raw = t.get_text(strip=True)
            if raw:
                title = raw.split(' - Novel Cool', 1)[0].strip() or raw

        cover_url = None
        img = soup.select_one('img.bookinfo-pic-img')
        if not img:
            img = soup.select_one('img[itemprop="image"]')
        if img:
            src = img.get('src')
            if src:
                cover_url = urljoin(novel_url, src)

        return {
            "title": title,
            "cover_url": cover_url,
        }

if __name__ == "__main__":
    import asyncio
    scraper = NovelCoolScraper()
    # Test with user provided URL
    url = "https://www.novelcool.com/chapter/Shadow-Slave-Chapter-15/7332162/"
    try:
        result = asyncio.run(scraper.scrape_chapter(url))
        print(f"Title: {result['title']}")
        print(f"Paragraphs: {len(result['content'])}")
        print(f"Next: {result['next_url']}")
    except Exception as e:
        print(f"Error: {e}")
