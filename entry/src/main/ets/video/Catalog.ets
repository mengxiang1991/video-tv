import { http } from '@kit.NetworkKit';

export interface Source {
  name: string;
  url: string;
}

export interface Title {
  id: string;
  name: string;
  poster: string;
  note: string;
  year: string;
  hits: number;
  score: number;
  updatedAt: number;
  releasedOn: string;
  source: Source;
}

export interface Episode {
  name: string;
  url: string;
}

export interface Line {
  name: string;
  episodes: Episode[];
}

interface Vod {
  vod_id: string | number;
  vod_name: string;
  vod_pic?: string;
  vod_remarks?: string;
  vod_year?: string | number;
  vod_hits?: string | number;
  vod_score?: string | number;
  vod_douban_score?: string | number;
  vod_time?: string;
  vod_pubdate?: string;
  vod_play_from?: string;
  vod_play_url?: string;
}

interface ResponseBody {
  list?: Vod[];
}

export interface Catalog {
  browse(source: Source): Promise<Title[]>;
  search(source: Source, keyword: string): Promise<Title[]>;
  detail(title: Title): Promise<Line[]>;
}

export const EXTRA_DEFAULT_SOURCES: Source[] = [
  { name: 'U酷资源', url: 'https://api.ukuapi88.com/api.php/provide/vod/' },
  { name: '无尽资源', url: 'https://api.wujinapi.com/api.php/provide/vod/' },
  { name: '豪华资源', url: 'https://hhzyapi.com/api.php/provide/vod/' }
];

export const DEFAULT_SOURCES: Source[] = [
  { name: '光速资源', url: 'https://api.guangsuapi.com/api.php/provide/vod/' },
  { name: '360资源', url: 'https://360zy.com/api.php/provide/vod/' },
  { name: '极速资源', url: 'https://jszyapi.com/api.php/provide/vod/' },
  ...EXTRA_DEFAULT_SOURCES
];

export function isHttp(value: string): boolean {
  return /^https?:\/\/[^\s/?#]+(?:[/?#][^\s]*)?$/i.test(value);
}

export function parseLines(value: string, names: string): Line[] {
  const labels = names.split('$$$');
  const lines: Line[] = [];
  value.split('$$$').forEach((group: string, index: number) => {
    const episodes: Episode[] = [];
    group.split('#').forEach((item: string) => {
      const separator = item.indexOf('$');
      const url = item.slice(separator + 1).trim();
      if (isHttp(url)) {
        const name = separator < 0 ? '' : item.slice(0, separator).trim();
        episodes.push({ name: name || '第 ' + (episodes.length + 1) + ' 集', url: url });
      }
    });
    if (episodes.length > 0) {
      lines.push({ name: labels[index] || '线路 ' + (index + 1), episodes: episodes });
    }
  });
  return lines;
}

async function request(url: string, query: string): Promise<Vod[]> {
  const base = url.split('#')[0];
  const divider = base.endsWith('?') || base.endsWith('&') ? '' : (base.includes('?') ? '&' : '?');
  const client = http.createHttp();
  try {
    const response = await client.request(base + divider + query, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 8000,
      readTimeout: 12000
    });
    if (response.responseCode !== 200 || typeof response.result !== 'string') {
      throw new Error('影视源请求失败');
    }
    const body = JSON.parse(response.result.replace(/^\uFEFF/, '')) as ResponseBody;
    if (!Array.isArray(body.list)) {
      throw new Error('影视源未返回 CMS JSON 列表');
    }
    return body.list;
  } finally {
    client.destroy();
  }
}

export class CmsCatalog implements Catalog {
  async browse(source: Source): Promise<Title[]> {
    return this.toTitles(await request(source.url, 'ac=videolist&pg=1'), source);
  }

  async search(source: Source, keyword: string): Promise<Title[]> {
    const list = await request(source.url, 'ac=videolist&wd=' + encodeURIComponent(keyword));
    return this.toTitles(list, source);
  }

  private toTitles(list: Vod[], source: Source): Title[] {
    return list.filter((vod: Vod) => vod.vod_id !== undefined && typeof vod.vod_name === 'string')
      .map((vod: Vod): Title => ({
        id: String(vod.vod_id), name: vod.vod_name, poster: vod.vod_pic || '',
        note: vod.vod_remarks || '', year: String(vod.vod_year ?? '').trim(),
        hits: Math.max(0, Number(vod.vod_hits) || 0),
        score: this.score(vod),
        updatedAt: Date.parse((vod.vod_time || '').trim().replace(' ', 'T')) || 0,
        releasedOn: this.releaseDate(vod.vod_pubdate),
        source: source
      }));
  }

  private score(vod: Vod): number {
    const values = [Number(vod.vod_douban_score), Number(vod.vod_score)];
    return values.find((value: number) => value > 0 && value <= 10) ?? 0;
  }

  private releaseDate(value?: string): string {
    if (typeof value !== 'string') {
      return '';
    }
    const date = /^\s*(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})(?!\d)/.exec(value);
    if (!date) {
      return '';
    }
    const iso = date[1] + '-' + date[2].padStart(2, '0') + '-' + date[3].padStart(2, '0');
    const timestamp = Date.parse(iso);
    return Number.isFinite(timestamp) && new Date(timestamp).toISOString().startsWith(iso) ? iso : '';
  }

  async detail(title: Title): Promise<Line[]> {
    const id = encodeURIComponent(title.id);
    try {
      const list = await request(title.source.url, 'ac=videolist&ids=' + id);
      const vod = list.find((entry: Vod) => String(entry.vod_id) === title.id);
      const lines = parseLines(vod?.vod_play_url || '', vod?.vod_play_from || '');
      if (lines.length > 0) {
        return lines;
      }
    } catch (_) {
      // Some CMS endpoints expose play URLs only under ac=detail.
    }
    const list = await request(title.source.url, 'ac=detail&ids=' + id);
    const vod = list.find((entry: Vod) => String(entry.vod_id) === title.id);
    return parseLines(vod?.vod_play_url || '', vod?.vod_play_from || '');
  }
}
