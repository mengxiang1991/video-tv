import { http } from '@kit.NetworkKit';
import { Source } from './Catalog';

const LIST_URL = 'https://gist.githubusercontent.com/xuyishan8058/fcd88d1a9e84c024cd5bc91531803ed3/raw/libretv-sources.json';

interface ListedSource {
  name?: string;
  url?: string;
  isAdult?: boolean;
}

interface SourceList {
  sources?: ListedSource[];
}

export function sourceKey(url: string): string {
  return url.trim().replace(/\/+$/, '');
}

function entries(value: string): ListedSource[] {
  try {
    const parsed = JSON.parse(value) as SourceList;
    return Array.isArray(parsed?.sources) ? parsed.sources : [];
  } catch (_) {
    // The Gist occasionally omits commas between standalone source objects.
    const section = /"sources"\s*:\s*\[([\s\S]*?)\]\s*,?\s*"liveSources"/.exec(value);
    const rows: ListedSource[] = [];
    if (section) {
      for (const line of section[1].split('\n')) {
        const row = line.trim().replace(/,$/, '');
        if (/^\{.*\}$/.test(row)) {
          try {
            rows.push(JSON.parse(row) as ListedSource);
          } catch (_) {
            continue;
          }
        }
      }
    }
    return rows;
  }
}

export async function discoverGitHubSources(): Promise<Source[]> {
  const client = http.createHttp();
  try {
    const response = await client.request(LIST_URL, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 8000,
      readTimeout: 12000
    });
    if (response.responseCode !== 200 || typeof response.result !== 'string' || response.result.length > 250000) {
      throw new Error('GitHub 源清单读取失败');
    }
    const rows = entries(response.result.replace(/^\uFEFF/, ''));
    if (!rows.length) {
      throw new Error('GitHub 源清单无法解析');
    }
    const seen = new Set<string>();
    const sources: Source[] = [];
    for (const row of rows) {
      if (!row || row.isAdult !== false || typeof row.url !== 'string' || typeof row.name !== 'string') {
        continue;
      }
      const url = row.url.trim();
      const name = row.name.trim();
      const key = sourceKey(url);
      if (name && /^https:\/\/(?:[a-z0-9-]+\.)+[a-z]{2,}\/[\w./-]*\/provide\/vod(?:[/?][^\s#]*)?$/i.test(url) &&
        !seen.has(key)) {
        seen.add(key);
        sources.push({ name: name, url: url });
      }
    }
    return sources;
  } finally {
    client.destroy();
  }
}
