import { writeFileSync, mkdirSync, readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const rootDir = resolve(__dirname, '..');
const outDir = resolve(rootDir, 'spec', 'fixtures', 'x');
mkdirSync(outDir, { recursive: true });

export function calculateToken(id) {
  // Token algorithm referenced from Vercel react-tweet & yt-dlp twitter extractor
  return ((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, '');
}

const tweets = [
  {
    name: 'photo',
    url: 'https://x.com/Lucy_love_AI/status/2110916144072913327',
  },
  {
    name: 'multi_photo',
    url: 'https://x.com/uu_remote/status/2111037737172336975',
  },
  {
    name: 'video',
    url: 'https://x.com/eric_sayompoo/status/2111025862892269612',
  },
  {
    name: 'gif',
    url: 'https://x.com/JenPanepinto/status/2110932947121668283',
  },
  {
    name: 'quote',
    url: 'https://x.com/gkxspace/status/2111043031700844656',
  },
  {
    name: 'deleted',
    url: 'https://x.com/Twitter/status/12345678',
    isDeletedStub: true,
  },
];

const userAgent =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

async function fetchTweetData(tweet) {
  const match = /\/status\/(\d+)/.exec(tweet.url);
  if (!match) throw new Error(`Invalid tweet URL: ${tweet.url}`);
  const id = match[1];
  const token = calculateToken(id);
  const endpoint = `https://cdn.syndication.twimg.com/tweet-result?id=${id}&lang=en&token=${token}`;

  console.log(`Fetching [${tweet.name}] ${endpoint} ...`);
  const res = await fetch(endpoint, {
    headers: {
      'User-Agent': userAgent,
      Accept: 'application/json, text/plain, */*',
    },
  });

  if (res.status === 404 || tweet.isDeletedStub) {
    // When a tweet is deleted or not found, syndication returns 404 or a tombstone
    return {
      __typename: 'TweetTombstone',
      tombstone: {
        text: {
          text: 'This Post was deleted by the Post author.',
        },
      },
    };
  }

  if (!res.ok) {
    throw new Error(`Failed to fetch tweet ${id}: HTTP ${res.status}`);
  }

  return await res.json();
}

async function main() {
  const sourcesPath = resolve(rootDir, 'spec', 'fixtures', 'sources.json');
  const sources = JSON.parse(readFileSync(sourcesPath, 'utf8'));

  if (!sources.x) {
    sources.x = {};
  }

  for (const tweet of tweets) {
    try {
      const data = await fetchTweetData(tweet);
      const filePath = resolve(outDir, `${tweet.name}.json`);
      writeFileSync(filePath, JSON.stringify(data, null, 2) + '\n', 'utf8');
      console.log(`Saved fixture: ${filePath}`);

      sources.x[tweet.name] = tweet.url;
    } catch (err) {
      console.error(`Error processing ${tweet.name}:`, err.message);
      process.exit(1);
    }
  }

  writeFileSync(sourcesPath, JSON.stringify(sources, null, 2) + '\n', 'utf8');
  console.log(`Updated sources: ${sourcesPath}`);
  console.log('All X fixtures successfully fetched.');
}

main();
