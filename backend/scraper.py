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

        for a in soup.find_all('a', href=True):
            href = a.get('href')
            if not href:
                continue
            if '/chapter/' not in href:
                continue
            abs_url = urljoin(novel_url, href)
            if abs_url in seen:
                continue
            seen.add(abs_url)
            title = a.get_text(' ', strip=True)
            if not title:
                # Some chapter links have empty text (icons). Skip.
                continue
            links.append({"title": title, "url": abs_url})

        # Sort by chapter number when possible.
        def chapter_key(item):
            t = item.get('title', '')
            m = re.search(r"(?:Chapter|C)\s*(\d+)", t, flags=re.IGNORECASE)
            if m:
                try:
                    return int(m.group(1))
                except Exception:
                    return 10**9
            # fallback: keep stable ordering
            return 10**9

        links.sort(key=chapter_key)
        return links

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
