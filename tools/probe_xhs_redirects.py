"""Cookie-free redirect matrix. Never inspect or persist cookie headers or bodies."""
import concurrent.futures
import http.client
import json
from urllib.parse import urljoin, urlsplit

UAS = {
    "desktop": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
    "mobile": "Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36",
}

def probe(case):
    agent, language = case
    current = "https://www.xiaohongshu.com/explore"
    hops = []
    for _ in range(5):
        uri = urlsplit(current)
        connection = http.client.HTTPSConnection(uri.hostname, timeout=20)
        try:
            request_path = (uri.path or "/") + ("?" + uri.query if uri.query else "")
            connection.request("GET", request_path, headers={
                "User-Agent": UAS[agent], "Accept-Language": language,
                "Accept": "text/html,application/xhtml+xml",
            })
            response = connection.getresponse()
            location = response.getheader("Location")
            target = urlsplit(urljoin(current, location)) if location else None
            path = target.path if target else ""
            category = ("login" if "login" in path else
                        "explore" if path == "/explore" else
                        "root" if path in ("", "/") else "other")
            hops.append({"status": response.status,
                         "locationDomain": target.hostname if target else None,
                         "locationPathCategory": category if target else None})
            if response.status not in (301, 302, 303, 307, 308) or target is None:
                break
            if target.scheme != "https" or target.hostname not in {
                "www.xiaohongshu.com", "xiaohongshu.com", "www.rednote.com", "rednote.com"
            }:
                break
            current = target.geturl()
        except Exception as error:
            hops.append({"errorType": type(error).__name__})
            break
        finally:
            connection.close()
    return {"agent": agent, "language": language, "hops": hops}

if __name__ == "__main__":
    cases = [(agent, language) for agent in UAS for language in ("zh-CN", "en", "fr")]
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for result in pool.map(probe, cases):
            print(json.dumps(result, ensure_ascii=True))
