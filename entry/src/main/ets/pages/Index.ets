import { preferences } from '@kit.ArkData';
import { window } from '@kit.ArkUI';
import { bundleManager } from '@kit.AbilityKit';
import { AVCastPicker, AVCastPickerState, avSession } from '@kit.AVSessionKit';
import { discoverGitHubSources, sourceKey } from '../video/GitHubSources';
import { Catalog, CmsCatalog, DEFAULT_SOURCES, Episode, EXTRA_DEFAULT_SOURCES,
  isHttp, Line, Source, Title } from '../video/Catalog';

const GREEN = '#287661';
const INK = '#233D32';
const PAPER = '#F4F5F2';
const TINT = '#EAF2ED';
const MUTED = '#5C7065';
const SELECTED = '#DCEEE6';

interface RecordItem {
  title: string;
  episode: Episode;
  position: number;
  media?: Title;
  lineName?: string;
}

interface SkipRule {
  key: string;
  intro: number;
  outro: number;
}

interface LoadedTitle {
  title: Title;
  lines: Line[];
}

@Entry
@Component
struct Index {
  @State tab: number = 0;
  @State sources: Source[] = [];
  @State history: RecordItem[] = [];
  @State favorites: Title[] = [];
  @State discovered: Source[] = [];
  @State discovering: boolean = false;
  @State discoveryOpen: boolean = false;
  @State sourcesExpanded: boolean = false;
  @State discoveryMessage: string = '';
  @State libraryTab: number = 0;
  @State name: string = '';
  @State url: string = '';
  @State query: string = '';
  @State recentSearches: string[] = [];
  @State showRecentSearches: boolean = true;
  @State results: Title[] = [];
  @State title: string = '';
  @State lines: Line[] = [];
  @State line: number = 0;
  @State active: Episode | undefined = undefined;
  @State busy: boolean = false;
  @State ready: boolean = false;
  @State status: string = '';
  @State playbackError: string = '';
  @State playbackNotice: string = '';
  @State attempt: number = 0;
  @State aboutOpen: boolean = false;
  @State version: string = '';
  @State autoSwitch: boolean = true;
  @State autoNext: boolean = true;
  @State episodeIndex: number = -1;
  @State locked: boolean = false;
  @State fullscreen: boolean = false;
  @State unlockVisible: boolean = false;
  @State controlsVisible: boolean = false;
  @State castReady: boolean = false;
  @State castDevice: string = '';
  @State castPlaying: boolean = false;
  private castSession?: avSession.AVSession;
  private castController?: avSession.AVCastController;
  private castWork: Promise<void> = Promise.resolve();
  private castGeneration: number = 0;
  private pickerOpen: boolean = false;
  private controlsTimer: number = -1;
  @State playing: boolean = false;
  @State progress: number = 0;
  @State duration: number = 0;
  @State speed: number = 1;
  @State skipOpen: boolean = false;
  @State introInput: string = '';
  @State outroInput: string = '';
  @State skipMessage: string = '';
  @State titleChoices: Title[] = [];
  @State recommendations: Title[] = [];
  @State recommendationTab: number = 0;
  @State loadingRecommendations: boolean = false;
  private recommendationRequest: number = 0;
  private episodeQueue: Episode[] = [];
  @State settingsMessage: string = '';
  private catalog: Catalog = new CmsCatalog();
  private preferences?: preferences.Preferences;
  private controller: VideoController = new VideoController();
  private generation: number = 0;
  private resumeAt: number = 0;
  private currentTime: number = 0;
  private savedAt: number = 0;
  private selectedTitle?: Title;
  private tried: Set<string> = new Set<string>();
  private failedAttempt: number = -1;
  private skipRules: SkipRule[] = [];
  private skipRule?: SkipRule;
  private introHandled: boolean = false;
  private watchdog: number = -1;
  private foreground: boolean = true;
  private windowOrientation?: window.Orientation;
  private previousImmersive?: boolean;
  private orientationChange: Promise<void> = Promise.resolve();
  private writes: Promise<void> = Promise.resolve();

  async aboutToAppear(): Promise<void> {
    try {
      this.preferences = await preferences.getPreferences(this.getUIContext().getHostContext()!, 'video_tv');
      this.sources = JSON.parse(await this.preferences.get('sources', '[]') as string) as Source[];
      this.history = JSON.parse(await this.preferences.get('history', '[]') as string) as RecordItem[];
      this.favorites = JSON.parse(await this.preferences.get('favorites', '[]') as string) as Title[];
      this.recentSearches = JSON.parse(await this.preferences.get('recentSearches', '[]') as string) as string[];
      this.autoSwitch = (await this.preferences.get('autoSwitch', 'true')) !== 'false';
      this.autoNext = (await this.preferences.get('autoNext', 'true')) !== 'false';
      this.speed = Number(await this.preferences.get('speed', '1')) || 1;
      this.skipRules = JSON.parse(await this.preferences.get('skipRules', '[]') as string) as SkipRule[];
      if (!(await this.preferences.get('expandedDefaultsAdded', false))) {
        const initialDefaultsAdded = await this.preferences.get('defaultsAdded', false);
        const defaults = initialDefaultsAdded ? EXTRA_DEFAULT_SOURCES : DEFAULT_SOURCES;
        const existing = new Set(this.sources.map((source: Source) => source.url.replace(/\/+$/, '')));
        this.sources = [...this.sources, ...defaults.filter((source: Source) =>
          !existing.has(source.url.replace(/\/+$/, '')))];
        await this.preferences.put('sources', JSON.stringify(this.sources));
        await this.preferences.put('defaultsAdded', true);
        await this.preferences.put('expandedDefaultsAdded', true);
        await this.preferences.flush();
      }
    } catch (_) {
      this.settingsMessage = '本地存储读取失败';
    }
    this.ready = true;
    void this.loadRecommendations();
    try {
      const info = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.version = info.versionName;
    } catch (_) {
      this.version = '';
    }
  }

  onPageHide(): void {
    this.hideControls();
    this.foreground = false;
    this.stopWatchdog();
    this.checkpoint(true);
  }

  onPageShow(): void {
    this.foreground = true;
    if (this.active && !this.castDevice && !this.playbackError && (this.playing || !this.duration)) {
      this.armWatchdog(this.active, this.attempt);
    }
  }

  private save(key: string, value: string): void {
    const store = this.preferences;
    if (store) {
      this.writes = this.writes.then(async () => {
        await store.put(key, value);
        await store.flush();
      }).catch(() => { this.settingsMessage = '本地保存失败'; });
    }
  }

  private addSource(): void {
    const url = this.url.trim();
    if (!this.name.trim() || !isHttp(url)) {
      this.settingsMessage = '请输入名称和完整的 HTTP 或 HTTPS API 地址';
      return;
    }
    if (this.sources.some((source: Source) => source.url === url)) {
      this.settingsMessage = '该影视源已添加';
      return;
    }
    this.sources = [...this.sources, { name: this.name.trim(), url: url }];
    this.save('sources', JSON.stringify(this.sources));
    this.name = '';
    this.url = '';
    this.settingsMessage = '已添加影视源';
    void this.loadRecommendations();
  }

  private removeSource(source: Source): void {
    this.sources = this.sources.filter((item: Source) => item.url !== source.url);
    this.save('sources', JSON.stringify(this.sources));
    void this.loadRecommendations();
  }

  private async discoverSources(): Promise<void> {
    this.discovering = true;
    this.discovered = [];
    this.discoveryMessage = '正在读取 GitHub 上的 LibreTV 源清单…';
    try {
      const candidates = await discoverGitHubSources();
      const existing = new Set(this.sources.map((source: Source) => sourceKey(source.url)));
      this.discovered = candidates.filter((source: Source) => !existing.has(sourceKey(source.url)));
      this.discoveryMessage = this.discovered.length > 0 ?
        '找到 ' + this.discovered.length + ' 个候选源' :
        '没有可添加的新源';
    } catch (_) {
      this.discoveryMessage = '读取 GitHub 源清单失败，请检查网络后重试';
    } finally {
      this.discovering = false;
    }
  }

  private hasSource(source: Source): boolean {
    return this.sources.some((item: Source) => sourceKey(item.url) === sourceKey(source.url));
  }

  private importDiscovered(source: Source): void {
    if (this.hasSource(source)) {
      return;
    }
    this.sources = [...this.sources, source];
    this.save('sources', JSON.stringify(this.sources));
    this.discoveryMessage = '已添加「' + source.name + '」';
    this.settingsMessage = this.discoveryMessage;
    void this.loadRecommendations();
  }

  @Builder
  sourceDiscovery() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text(this.discoveryMessage).fontSize(13).fontColor(MUTED).layoutWeight(1)
        Button('刷新').height(40).fontSize(13).fontColor(GREEN).backgroundColor(SELECTED)
          .enabled(!this.discovering).onClick(() => { void this.discoverSources(); })
      }.width('100%')
      List({ space: 8 }) {
        ForEach(this.discovered, (source: Source) => {
          ListItem() {
            Row({ space: 8 }) {
              Column({ space: 3 }) {
                Text(source.name).fontColor(INK).fontSize(14).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(source.url).fontColor(MUTED).fontSize(12).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Button(this.hasSource(source) ? '已添加' : '添加').height(32).fontSize(13)
                .fontColor(GREEN).backgroundColor(SELECTED)
                .enabled(!this.discovering && !this.hasSource(source))
                .onClick(() => this.importDiscovered(source))
            }.width('100%').padding(10).backgroundColor(PAPER).borderRadius(10)
          }
        }, (source: Source) => source.url)
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%').padding({ left: 16, right: 16, bottom: 16 })
  }

  private async loadRecommendations(): Promise<void> {
    const request = ++this.recommendationRequest;
    this.loadingRecommendations = this.sources.length > 0;
    this.recommendations = [];
    const batches = await Promise.allSettled(this.sources.map((source: Source) => this.catalog.browse(source)));
    if (request !== this.recommendationRequest) {
      return;
    }
    const titles: Title[] = [];
    batches.forEach(batch => {
      if (batch.status === 'fulfilled') {
        titles.push(...batch.value);
      }
    });
    this.recommendations = titles;
    this.loadingRecommendations = false;
  }

  private rankedRecommendations(): Title[] {
    const tab = this.recommendationTab;
    const now = new Date();
    const today = this.dateKey(now);
    now.setDate(now.getDate() - 90);
    const cutoff = this.dateKey(now);
    const titles = this.recommendations.filter((item: Title) =>
      tab === 0 || (tab === 1 && item.hits > 0) || (tab === 2 && item.score > 0) ||
      (tab === 3 && item.releasedOn >= cutoff && item.releasedOn <= today));
    titles.sort((left: Title, right: Title) => {
      if (tab === 1) {
        return right.hits - left.hits;
      }
      if (tab === 2) {
        return right.score - left.score;
      }
      if (tab === 3) {
        return right.releasedOn.localeCompare(left.releasedOn);
      }
      return right.updatedAt - left.updatedAt;
    });
    const seen = new Set<string>();
    return titles.filter((item: Title) => {
      const key = item.name.trim() + '|' + item.year;
      if (seen.has(key)) {
        return false;
      }
      seen.add(key);
      return true;
    }).slice(0, 12);
  }

  private dateKey(date: Date): string {
    return date.getFullYear() + '-' + String(date.getMonth() + 1).padStart(2, '0') + '-' +
      String(date.getDate()).padStart(2, '0');
  }

  private recommendationHint(): string {
    if (this.loadingRecommendations) {
      return '正在加载推荐…';
    }
    if (!this.recommendations.length) {
      return '暂时没有推荐，可刷新重试';
    }
    if (!this.rankedRecommendations().length) {
      if (this.recommendationTab === 3) {
        return '当前片源暂无近 90 天内已上映的条目';
      }
      return this.recommendationTab === 1 ? '当前片源未提供热度' : '当前片源未提供评分';
    }
    return ['按片源更新时间排序', '按片源热度排序', '按片源评分排序',
      '按片源提供的上映日期排序，展示近 90 天条目'][this.recommendationTab];
  }

  private async search(): Promise<void> {
    const query = this.query.trim();
    if (!query || this.busy || !this.ready) {
      return;
    }
    if (this.sources.length === 0) {
      this.status = '请先在设置中添加影视源';
      return;
    }
    const token = ++this.generation;
    this.showRecentSearches = false;
    this.recentSearches = [query, ...this.recentSearches.filter((item: string) =>
      item.toLowerCase() !== query.toLowerCase())].slice(0, 20);
    this.save('recentSearches', JSON.stringify(this.recentSearches));
    this.results = [];
    this.status = '';
    this.busy = true;
    const groups = await Promise.allSettled(this.sources.map((source: Source) => this.catalog.search(source, query)));
    if (token !== this.generation) {
      return;
    }
    const matches: Title[] = [];
    let failed = 0;
    groups.forEach(group => {
      if (group.status === 'fulfilled') {
        matches.push(...group.value);
      } else {
        failed++;
      }
    });
    this.results = matches;
    this.busy = false;
    if (failed === groups.length) {
      this.status = '所有影视源均请求失败，请检查 API 地址和网络';
    } else if (!matches.length) {
      this.status = failed > 0 ? '未找到影片，部分影视源未响应' : '未找到匹配影片';
    } else if (failed > 0) {
      this.status = '部分影视源未响应';
    }
  }

  private async openTitle(item: Title, record?: RecordItem): Promise<void> {
    this.closeCast();
    this.checkpoint(true);
    this.stopWatchdog();
    this.active = undefined;
    this.episodeQueue = [];
    this.episodeIndex = -1;
    this.skipOpen = false;
    this.attempt++;
    const token = ++this.generation;
    this.selectedTitle = item;
    this.titleChoices = this.relatedTitles(item);
    this.skipRule = this.skipRules.find((rule: SkipRule) => rule.key === this.groupKey(item));
    this.title = item.name;
    this.lines = [];
    this.line = 0;
    this.status = '';
    this.busy = true;
    try {
      const lines = await this.loadLines(item);
      if (token !== this.generation) {
        return;
      }
      if (lines.length > 0) {
        this.lines = lines;
        this.restoreEpisode(record);
        return;
      }
      if (this.autoSwitch && /^\d{4}$/.test(item.year)) {
        this.status = '当前源无法加载分集，正在尝试其他来源…';
        const sources = this.sources.filter((source: Source) => sourceKey(source.url) !== sourceKey(item.source.url));
        const fallback = await Promise.any(sources.map(async (source: Source): Promise<LoadedTitle> => {
          const match = await this.findTitle(item, source);
          if (!match || token !== this.generation) {
            throw new Error('没有匹配的影片');
          }
          const alternate = await this.loadLines(match);
          if (alternate.length === 0 || token !== this.generation) {
            throw new Error('没有可播放分集');
          }
          return { title: match, lines: alternate };
        }));
        if (token === this.generation) {
          this.selectedTitle = fallback.title;
          if (!this.titleChoices.some((choice: Title) => this.titleKey(choice) === this.titleKey(fallback.title))) {
            this.titleChoices = [...this.titleChoices, fallback.title];
          }
          this.lines = fallback.lines;
          this.restoreEpisode(record);
          this.status = '已切换到「' + fallback.title.source.name + '」';
        }
      } else {
        this.status = '当前来源未能加载可播放分集';
      }
    } catch (_) {
      if (token === this.generation) {
        this.status = '未找到可加载分集的同名同年影片，请返回重试';
      }
    } finally {
      if (token === this.generation) {
        this.busy = false;
        if (record && !this.active) {
          this.play(record.episode, record.position);
        }
      }
    }
  }

  private restoreEpisode(record?: RecordItem): void {
    if (!record) {
      return;
    }
    const preferred = this.lines.findIndex((line: Line) => line.name === record.lineName);
    const order = this.lines.map((line: Line, index: number) => index);
    if (preferred >= 0) {
      order.splice(preferred, 1);
      order.unshift(preferred);
    }
    for (const line of order) {
      const episodes = this.lines[line].episodes;
      const index = episodes.findIndex((episode: Episode) => episode.url === record.episode.url ||
        this.episodeKey(episode.name) === this.episodeKey(record.episode.name));
      if (index >= 0) {
        this.line = line;
        this.episodeQueue = episodes;
        this.episodeIndex = index;
        this.play(episodes[index], record.position);
        return;
      }
    }
  }

  private episodeKey(name: string): string {
    return name.replace(/\s/g, '');
  }

  private groupKey(item: Title): string {
    return /^\d{4}$/.test(item.year) ? JSON.stringify([item.name.trim(), item.year]) : this.titleKey(item);
  }

  private relatedTitles(item: Title): Title[] {
    return [item, ...this.results.filter((other: Title) =>
      this.groupKey(other) === this.groupKey(item) && this.titleKey(other) !== this.titleKey(item))];
  }

  private groupedResults(): Title[] {
    const seen = new Set<string>();
    return this.results.filter((item: Title) => {
      const key = this.groupKey(item);
      if (seen.has(key)) {
        return false;
      }
      seen.add(key);
      return true;
    });
  }

  private matchesTitle(candidate: Title, item: Title, source: Source): boolean {
    return sourceKey(candidate.source.url) === sourceKey(source.url) &&
      candidate.name.trim() === item.name.trim() && candidate.year === item.year;
  }

  private async findTitle(item: Title, source: Source): Promise<Title | undefined> {
    return this.results.find((candidate: Title) => this.matchesTitle(candidate, item, source)) ??
      (await this.catalog.search(source, item.name)).find((candidate: Title) => this.matchesTitle(candidate, item, source));
  }

  private async loadLines(item: Title): Promise<Line[]> {
    try {
      return await this.catalog.detail(item);
    } catch (_) {
      return [];
    }
  }

  private titleKey(item: Title): string {
    return item.source.url + ':' + item.id;
  }

  private isFavorite(item: Title): boolean {
    return this.favorites.some((favorite: Title) => this.titleKey(favorite) === this.titleKey(item));
  }

  private toggleFavorite(item: Title): void {
    if (this.isFavorite(item)) {
      this.favorites = this.favorites.filter((favorite: Title) => this.titleKey(favorite) !== this.titleKey(item));
    } else {
      this.favorites = [item, ...this.favorites];
    }
    this.save('favorites', JSON.stringify(this.favorites));
  }

  @Builder
  libraryPage() {
    Column({ space: 12 }) {
      Row({ space: 4 }) {
        ForEach(['收藏', '播放记录'], (label: string, index: number) => {
          Button(label).layoutWeight(1).fontSize(14)
            .fontColor(this.libraryTab === index ? GREEN : MUTED)
            .backgroundColor(this.libraryTab === index ? SELECTED : Color.Transparent)
            .onClick(() => { this.libraryTab = index; })
        })
      }.width('100%').padding(5).borderRadius(14).backgroundColor(Color.White)
      if (this.libraryTab === 0) {
        this.favoritesPage()
      } else {
        this.historyPage()
      }
    }.width('100%')
  }

  @Builder
  favoritesPage() {
    Column({ space: 10 }) {
      if (!this.favorites.length) {
        this.label('在影片详情点「收藏」，之后可在这里找到')
      }
      ForEach(this.favorites, (item: Title) => {
        Row({ space: 10 }) {
          Row({ space: 12 }) {
            if (isHttp(item.poster)) {
              Image(item.poster).width(48).height(66).objectFit(ImageFit.Cover).borderRadius(8)
            }
            Column({ space: 5 }) {
              Text(item.name).fontColor(INK).fontSize(17).maxLines(2)
              Text(item.source.name).fontColor(MUTED).fontSize(13)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.layoutWeight(1).onClick(() => { void this.openTitle(item); })
          Button('取消收藏').height(34).fontSize(13).fontColor(GREEN).backgroundColor(TINT)
            .onClick(() => this.toggleFavorite(item))
        }.width('100%').padding(12).backgroundColor(Color.White).borderRadius(14)
      }, (item: Title) => this.titleKey(item))
    }.width('100%')
  }

  private play(episode: Episode, position?: number, fallback: boolean = false): void {
    this.closeCast();
    this.hideControls();
    if (!fallback) {
      this.tried.clear();
      this.playbackNotice = '';
    }
    this.checkpoint(true);
    const previous = this.history.find((item: RecordItem) => item.episode.url === episode.url);
    this.resumeAt = position ?? previous?.position ?? 0;
    this.currentTime = this.resumeAt;
    this.progress = this.resumeAt;
    this.duration = 0;
    this.playing = false;
    this.introHandled = false;
    this.savedAt = this.resumeAt;
    this.playbackError = '';
    this.tried.add(episode.url);
    this.attempt++;
    this.active = episode;
    this.openCast(episode);
    this.armWatchdog(episode, this.attempt);
  }

  private stopWatchdog(): void {
    if (this.watchdog >= 0) {
      clearTimeout(this.watchdog);
      this.watchdog = -1;
    }
  }

  private armWatchdog(episode: Episode, attempt: number): void {
    this.stopWatchdog();
    if (this.foreground) {
      this.watchdog = setTimeout(() => {
        this.watchdog = -1;
        void this.recover(episode, attempt, true);
      }, 20000);
    }
  }

  private playFromLine(index: number): void {
    const episodes = this.lines[this.line]?.episodes;
    if (episodes) {
      this.episodeQueue = episodes;
      this.playQueueItem(index);
    }
  }

  private playQueueItem(index: number): void {
    const episode = this.episodeQueue[index];
    if (episode) {
      this.episodeIndex = index;
      this.play(episode);
    }
  }

  private async recover(episode: Episode, attempt: number, stalled: boolean = false): Promise<void> {
    if (attempt !== this.attempt || attempt === this.failedAttempt || !this.active) {
      return;
    }
    this.failedAttempt = attempt;
    this.stopWatchdog();
    this.controller.pause();
    this.playing = false;
    if (!this.autoSwitch) {
      this.playbackError = stalled ? '播放长时间没有进度，请重试或换源' : '播放失败，请重试或换源';
      return;
    }
    const position = this.currentTime;
    const local = this.findAlternate(this.lines, episode);
    if (local) {
      this.playbackNotice = '已切换到备用线路';
      this.play(local, position, true);
      return;
    }
    const selected = this.selectedTitle;
    if (selected && /^\d{4}$/.test(selected.year)) {
      const sources = this.sources.filter((source: Source) => sourceKey(source.url) !== sourceKey(selected.source.url));
      if (sources.length > 0) {
        this.playbackNotice = '正在查找其他来源的同一集…';
      }
      const alternatives = await Promise.allSettled(sources.map(async (source: Source): Promise<LoadedTitle> => {
        const item = await this.findTitle(selected, source);
        if (!item || attempt !== this.attempt) {
          throw new Error('没有匹配的影片');
        }
        return { title: item, lines: await this.loadLines(item) };
      }));
      if (attempt !== this.attempt || !this.active) {
        return;
      }
      for (let i = 0; i < alternatives.length; i++) {
        const group = alternatives[i];
        if (group.status === 'fulfilled') {
          const next = this.findAlternate(group.value.lines, episode);
          if (next) {
            const alternate = group.value.title;
            if (!this.titleChoices.some((choice: Title) => this.titleKey(choice) === this.titleKey(alternate))) {
              this.titleChoices = [...this.titleChoices, alternate];
            }
            this.playbackNotice = '已切换到' + alternate.source.name;
            this.play(next, position, true);
            return;
          }
        }
      }
    }
    this.playbackNotice = '';
    this.playbackError = '播放失败，暂时没有可切换的同集线路';
  }

  private findAlternate(lines: Line[], episode: Episode): Episode | undefined {
    for (const line of lines) {
      const match = line.episodes.find((item: Episode) =>
        this.episodeKey(item.name) === this.episodeKey(episode.name) && !this.tried.has(item.url));
      if (match) {
        return match;
      }
    }
    return undefined;
  }

  private checkpoint(force: boolean): void {
    const episode = this.active;
    if (!episode || (!force && Math.abs(this.currentTime - this.savedAt) < 5)) {
      return;
    }
    this.savedAt = this.currentTime;
    const item: RecordItem = {
      title: this.title, episode: episode, position: this.currentTime,
      media: this.selectedTitle, lineName: this.lines[this.line]?.name
    };
    this.history = [item, ...this.history.filter((entry: RecordItem) => entry.episode.url !== episode.url)]
      .slice(0, 100);
    this.save('history', JSON.stringify(this.history));
  }

  private leaveTitle(): void {
    this.closeCast();
    this.hideControls();
    this.checkpoint(true);
    this.stopWatchdog();
    this.setFullscreen(false);
    this.active = undefined;
    this.locked = false;
    this.unlockVisible = false;
    this.skipOpen = false;
    this.episodeQueue = [];
    this.episodeIndex = -1;
    this.selectedTitle = undefined;
    this.attempt++;
    this.title = '';
    this.lines = [];
    this.status = '';
    this.busy = false;
    this.generation++;
  }

  aboutToDisappear(): void {
    this.closeCast();
  }

  private closeCast(): void {
    this.castGeneration++;
    this.castReady = false;
    this.castDevice = '';
    this.castPlaying = false;
    this.castController = undefined;
    this.pickerOpen = false;
    this.castWork = this.castWork.then(async () => {
      const session = this.castSession;
      this.castSession = undefined;
      if (session) {
        await session.destroy();
      }
    }).catch(() => {});
  }

  private openCast(episode: Episode): void {
    const context = this.getUIContext().getHostContext();
    const generation = this.castGeneration;
    if (!context) {
      return;
    }
    this.castWork = this.castWork.then(async () => {
      if (generation !== this.castGeneration) {
        return;
      }
      const session = await avSession.createAVSession(context, '片间拾影', 'video');
      this.castSession = session;
      await session.activate();
      await session.setExtras({ requireAbilityList: ['url-cast'] });
      await session.setAVMetadata({
        assetId: String(this.attempt),
        title: this.title + ' · ' + episode.name,
        filter: avSession.ProtocolType.TYPE_CAST_PLUS_STREAM | avSession.ProtocolType.TYPE_DLNA
      });
      session.on('play', () => {
        if (generation === this.castGeneration && !this.castDevice) {
          this.controller.start();
        }
      });
      session.on('pause', () => {
        if (generation === this.castGeneration && !this.castDevice) {
          this.controller.pause();
        }
      });
      session.on('outputDeviceChange', (state: avSession.ConnectionState, output: avSession.OutputDeviceInfo) => {
        if (generation !== this.castGeneration) {
          return;
        }
        const device = output?.devices?.[0];
        if (state === avSession.ConnectionState.STATE_CONNECTED &&
          device?.castCategory === avSession.AVCastCategory.CATEGORY_REMOTE) {
          if (!this.castDevice) {
            void this.beginCast(session, device, episode, generation);
          }
        } else if (this.castDevice && (state === avSession.ConnectionState.STATE_DISCONNECTED ||
          device?.castCategory !== avSession.AVCastCategory.CATEGORY_REMOTE)) {
          this.returnFromCast();
        }
      });
      if (generation === this.castGeneration) {
        this.castReady = true;
        this.updateCastSession();
      }
    }).catch(() => {
      if (generation === this.castGeneration) {
        this.castReady = false;
      }
    });
  }

  private updateCastSession(): void {
    if (this.castReady && !this.castDevice) {
      void this.castSession?.setAVPlaybackState({
        state: this.playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        position: { elapsedTime: Math.round(this.currentTime * 1000), updateTime: Date.now() }
      }).catch(() => {});
    }
  }

  private async beginCast(session: avSession.AVSession, device: avSession.DeviceInfo,
    episode: Episode, generation: number): Promise<void> {
    this.castDevice = device.deviceName || '电视';
    this.stopWatchdog();
    this.controller.pause();
    try {
      const controller = await session.getAVCastController();
      if (generation !== this.castGeneration || !this.castDevice) {
        return;
      }
      this.castController = controller;
      controller.on('playbackStateChange', 'all', (state: avSession.AVPlaybackState) => {
        if (this.castController !== controller) {
          return;
        }
        if (state.state !== undefined) {
          this.castPlaying = state.state === avSession.PlaybackState.PLAYBACK_STATE_PLAY;
        }
        if (state.position) {
          this.currentTime = state.position.elapsedTime / 1000;
          this.progress = this.currentTime;
          this.checkpoint(false);
        }
      });
      controller.on('endOfStream', () => {
        if (this.castController === controller) {
          void this.stopCast();
        }
      });
      const item: avSession.AVQueueItem = {
        itemId: this.attempt,
        description: {
          assetId: String(this.attempt),
          title: this.title + ' · ' + episode.name,
          mediaUri: episode.url,
          mediaType: 'VIDEO',
          startPosition: Math.round(this.currentTime * 1000),
          duration: Math.round(this.duration * 1000)
        }
      };
      await controller.prepare(item);
      if (this.castController === controller) {
        await controller.start(item);
      }
    } catch (_) {
      if (generation === this.castGeneration && this.castDevice) {
        await this.stopCast();
        this.playbackNotice = '投屏失败，请检查电视能否访问这个片源';
      }
    }
  }

  private returnFromCast(): void {
    this.castController = undefined;
    this.castDevice = '';
    this.castPlaying = false;
    this.checkpoint(true);
    if (this.active) {
      if (this.duration > 0) {
        this.controller.setCurrentTime(this.currentTime, SeekMode.Accurate);
      }
      this.controller.start();
    }
  }

  private async stopCast(): Promise<void> {
    const session = this.castSession;
    if (!session) {
      return;
    }
    try {
      await session.stopCasting();
      if (this.castSession === session && this.castDevice) {
        this.returnFromCast();
      }
    } catch (_) {
      if (this.castSession === session) {
        this.playbackNotice = '停止投屏失败，请从设备面板断开';
      }
    }
  }

  private sendCastCommand(command: avSession.AVCastControlCommand): void {
    void this.castController?.sendControlCommand(command).catch(() => {
      this.playbackNotice = '电视暂未响应投屏控制';
    });
  }

  onBackPress(): boolean {
    if (this.aboutOpen) {
      this.aboutOpen = false;
      return true;
    }
    if (this.fullscreen) {
      this.setFullscreen(false);
      return true;
    }
    if (this.locked) {
      this.locked = false;
      return true;
    }
    if (this.title) {
      this.leaveTitle();
      return true;
    }
    return false;
  }

  private setFullscreen(fullscreen: boolean): void {
    if (this.fullscreen === fullscreen) {
      return;
    }
    this.fullscreen = fullscreen;
    this.hideControls();
    this.unlockVisible = false;
    const context = this.getUIContext().getHostContext();
    if (!context) {
      return;
    }
    this.orientationChange = this.orientationChange.then(async () => {
      const appWindow = await window.getLastWindow(context);
      if (fullscreen) {
        this.windowOrientation = appWindow.getPreferredOrientation();
        this.previousImmersive = appWindow.getWindowProperties().isLayoutFullScreen;
        await appWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE);
        await appWindow.setWindowLayoutFullScreen(true);
        await appWindow.setWindowSystemBarEnable([]);
      } else {
        await appWindow.setWindowSystemBarEnable(['status', 'navigation']);
        await appWindow.setWindowLayoutFullScreen(this.previousImmersive ?? false);
        if (this.windowOrientation !== undefined) {
          await appWindow.setPreferredOrientation(this.windowOrientation);
          this.windowOrientation = undefined;
        }
        this.previousImmersive = undefined;
      }
    }).catch(() => {
      this.playbackNotice = '无法切换全屏窗口';
    });
  }

  private cancelControlsTimer(): void {
    if (this.controlsTimer >= 0) {
      clearTimeout(this.controlsTimer);
      this.controlsTimer = -1;
    }
  }

  private hideControls(): void {
    this.cancelControlsTimer();
    this.controlsVisible = false;
  }

  private scheduleControlsHide(): void {
    this.cancelControlsTimer();
    if (this.controlsVisible && this.playing && !this.pickerOpen && !this.castDevice) {
      this.controlsTimer = setTimeout(() => this.hideControls(), 4000);
    }
  }

  private saveSkipRule(): void {
    const title = this.selectedTitle;
    const intro = Number(this.introInput.trim());
    const outro = Number(this.outroInput.trim());
    if (!title || !/^\d{0,3}$/.test(this.introInput.trim()) || !/^\d{0,3}$/.test(this.outroInput.trim())) {
      this.skipMessage = '请输入 0 至 999 的整数秒数';
      return;
    }
    const key = this.groupKey(title);
    this.skipRules = this.skipRules.filter((rule: SkipRule) => rule.key !== key);
    this.skipRule = { key: key, intro: intro, outro: outro };
    if (intro || outro) {
      this.skipRules.push(this.skipRule);
    }
    this.save('skipRules', JSON.stringify(this.skipRules));
    this.introHandled = false;
    this.skipOpen = false;
  }

  private finishEpisode(attempt: number): void {
    if (attempt !== this.attempt || attempt === this.failedAttempt) {
      return;
    }
    this.failedAttempt = attempt;
    this.stopWatchdog();
    this.playing = false;
    this.currentTime = 0;
    this.checkpoint(true);
    if (this.autoNext && this.episodeQueue[this.episodeIndex + 1] && this.episodeIndex >= 0) {
      this.playQueueItem(this.episodeIndex + 1);
    } else if (this.duration > 0 && this.progress < this.duration - 1) {
      this.controller.setCurrentTime(this.duration, SeekMode.Accurate);
      this.controller.pause();
    }
  }

  private updatePlayback(episode: Episode, attempt: number, time: number): void {
    if (attempt !== this.attempt || attempt === this.failedAttempt) {
      return;
    }
    if (this.playing && time !== this.currentTime) {
      this.armWatchdog(episode, attempt);
    }
    this.currentTime = time;
    this.progress = time;
    const rule = this.skipRule;
    if (rule && this.duration > rule.intro + rule.outro && this.playing) {
      if (!this.introHandled) {
        this.introHandled = true;
        if (time < rule.intro) {
          this.controller.setCurrentTime(rule.intro, SeekMode.Accurate);
          return;
        }
      }
      if (rule.outro > 0 && time >= this.duration - rule.outro) {
        this.finishEpisode(attempt);
        return;
      }
    }
    this.checkpoint(false);
  }

  private timeLabel(value: number): string {
    return Math.floor(value / 60) + ':' + String(Math.floor(value % 60)).padStart(2, '0');
  }

  @Builder
  label(value: string) {
    Text(value).fontSize(14).fontColor(MUTED).width('100%')
  }

  @Builder
  searchPage() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.query, placeholder: '片名、剧名' })
          .layoutWeight(1).backgroundColor(TINT).onChange((value: string) => { this.query = value; })
          .onFocus(() => { this.showRecentSearches = true; })
          .onSubmit(() => { void this.search(); })
        Button('搜索').backgroundColor(GREEN).enabled(this.ready && !this.busy)
          .onClick(() => { void this.search(); })
      }
      if (this.showRecentSearches && !this.busy && this.recentSearches.length > 0) {
        Column({ space: 6 }) {
          Row() {
            Text('最近搜索').fontSize(16).fontColor(INK).layoutWeight(1)
            Button('清空').height(32).fontSize(13).fontColor(GREEN).backgroundColor(TINT)
              .onClick(() => {
                this.recentSearches = [];
                this.save('recentSearches', '[]');
              })
          }.width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.recentSearches, (item: string) => {
              Button(item).height(32).fontSize(13).fontColor(GREEN).backgroundColor(SELECTED)
                .constraintSize({ maxWidth: '100%' }).margin({ right: 6, bottom: 6 })
                .onClick(() => { this.query = item; void this.search(); })
            }, (item: string) => item)
          }.width('100%')
        }.width('100%').padding(12).borderRadius(14).backgroundColor(Color.White)
      }
      if (this.busy) {
        this.label('正在搜索影视源…')
      }
      if (this.status) {
        this.label(this.status)
      }
      if (!this.results.length && !this.busy && !this.status) {
        if (this.sources.length) {
          Row() {
            Text('影片推荐')
              .fontSize(19).fontWeight(FontWeight.Medium).fontColor(INK).layoutWeight(1)
            Button('刷新').height(40).fontColor(GREEN).backgroundColor(TINT)
              .enabled(!this.loadingRecommendations).onClick(() => { void this.loadRecommendations(); })
          }.width('100%')
          Row({ space: 8 }) {
            ForEach(['最近更新', '热门', '高分', '最新上映'], (name: string, index: number) => {
              Button(name).height(36).layoutWeight(1)
                .fontSize(13).padding({ left: 4, right: 4 })
                .backgroundColor(this.recommendationTab === index ? SELECTED : Color.Transparent)
                .fontColor(this.recommendationTab === index ? GREEN : MUTED)
                .onClick(() => { this.recommendationTab = index; })
            })
          }.width('100%').padding(5).backgroundColor(Color.White).borderRadius(14)
          this.label(this.recommendationHint())
        } else {
          this.label('在设置中添加影视源')
        }
      }
      ForEach(!this.busy && !this.status && !this.results.length ? this.rankedRecommendations() : this.groupedResults(), (item: Title) => {
        Row({ space: 12 }) {
          if (isHttp(item.poster)) {
            Image(item.poster).width(54).height(75).objectFit(ImageFit.Cover).borderRadius(8)
          }
          Column({ space: 5 }) {
            Text(item.name).fontSize(17).fontWeight(FontWeight.Medium).fontColor(INK)
            Text(item.source.name + (item.note ? ' · ' + item.note : '')).fontSize(13).fontColor(MUTED)
            if (this.results.length > 0 && this.relatedTitles(item).length > 1) {
              Text(this.relatedTitles(item).length + ' 个来源').fontSize(12).fontColor(GREEN)
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          if (!this.results.length && this.recommendationTab === 1) {
            Text('热度 ' + item.hits).fontSize(13).fontColor(GREEN)
          } else if (!this.results.length && this.recommendationTab === 2) {
            Text(item.score.toFixed(1) + ' 分').fontSize(14).fontColor(GREEN)
          } else if (!this.results.length && this.recommendationTab === 3) {
            Text(item.releasedOn).fontSize(13).fontColor(GREEN)
          }
          Text('›').fontSize(24).fontColor(GREEN)
        }.padding(12).width('100%').borderRadius(14).backgroundColor(Color.White)
          .onClick(() => { void this.openTitle(item); })
      }, (item: Title) => item.source.url + ':' + item.id)
    }.width('100%')
  }

  @Builder
  settingsPage() {
    Column({ space: 12 }) {
      Column({ space: 10 }) {
        Text('播放设置').fontSize(19).fontWeight(FontWeight.Medium).fontColor(INK).width('100%')
        Row({ space: 10 }) {
          Column({ space: 4 }) {
            Text('自动换源').fontSize(16).fontColor(INK)
            Text('详情加载或播放失败时尝试其他来源').fontSize(13).fontColor(MUTED)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.autoSwitch }).selectedColor(GREEN)
            .enabled(this.ready).onChange((value: boolean) => {
              this.autoSwitch = value;
              this.save('autoSwitch', String(value));
            })
        }.width('100%')
        Divider().color(TINT)
        Row({ space: 10 }) {
          Text('自动播放下一集').fontSize(16).fontColor(INK).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.autoNext }).selectedColor(GREEN)
            .enabled(this.ready).onChange((value: boolean) => {
              this.autoNext = value;
              this.save('autoNext', String(value));
            })
        }.width('100%')
      }.width('100%').padding(14).backgroundColor(Color.White).borderRadius(14)
      Row({ space: 8 }) {
        Text('影视源管理').fontSize(16).fontWeight(FontWeight.Medium).fontColor(INK).layoutWeight(1)
        Text('已添加 ' + this.sources.length + ' 个').fontSize(13).fontColor(MUTED)
        Button(this.sourcesExpanded ? '收起' : '展开').height(34).fontSize(13)
          .fontColor(GREEN).backgroundColor(SELECTED)
          .onClick(() => { this.sourcesExpanded = !this.sourcesExpanded; })
      }.width('100%').padding(12).backgroundColor(Color.White).borderRadius(14)
      if (this.sourcesExpanded) {
        this.sourceManagement()
      }
      if (this.settingsMessage) {
        this.label(this.settingsMessage)
      }
      Button('关于我们  ›').width('100%').fontColor(GREEN).backgroundColor(Color.White)
        .onClick(() => { this.aboutOpen = true; })
    }.width('100%')
  }

  @Builder
  sourceManagement() {
    Column({ space: 12 }) {
      this.label('填写支持 MacCMS JSON 的采集 API 地址')
      TextInput({ text: this.name, placeholder: '源名称' }).backgroundColor(TINT)
        .onChange((value: string) => { this.name = value; })
      TextInput({ text: this.url, placeholder: 'https://域名/api.php/provide/vod/' }).backgroundColor(TINT)
        .onChange((value: string) => { this.url = value; })
      Button('添加影视源').backgroundColor(GREEN).enabled(this.ready).width('100%')
        .onClick(() => this.addSource())
      Row({ space: 8 }) {
        Text('GitHub 寻源').fontSize(16).fontWeight(FontWeight.Medium).fontColor(INK).layoutWeight(1)
        Button('寻源').height(34).fontSize(13).backgroundColor(GREEN).enabled(this.ready)
          .onClick(() => {
            this.discoveryOpen = true;
            if (!this.discovering && this.discovered.length === 0) {
              void this.discoverSources();
            }
          })
          .bindSheet($$this.discoveryOpen, this.sourceDiscovery(), {
            height: SheetSize.LARGE,
            title: { title: 'GitHub 寻源' }
          })
      }.width('100%').padding(12).backgroundColor(Color.White).borderRadius(14)
      ForEach(this.sources, (source: Source) => {
        Row({ space: 8 }) {
          Column({ space: 4 }) {
            Text(source.name).fontColor(INK).fontSize(16)
            Text(source.url).fontColor(MUTED).fontSize(12).maxLines(2)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button('移除').fontColor(GREEN).backgroundColor(TINT).onClick(() => this.removeSource(source))
        }.width('100%').padding(12).backgroundColor(Color.White).borderRadius(14)
      }, (source: Source) => source.url)
    }.width('100%')
  }

  @Builder
  aboutPage() {
    Column({ space: 12 }) {
      Column({ space: 10 }) {
        Image($r('app.media.app_icon')).width(58).height(58).borderRadius(13)
        Text($r('app.string.app_name')).fontSize(23).fontWeight(FontWeight.Bold).fontColor(INK)
        if (this.version) {
          Text('版本 ' + this.version).fontSize(13).fontColor(MUTED)
        }
        Text('为 HarmonyOS 打造的原生视频播放器。支持多源搜索、选集、横屏全屏和历史续播。')
          .fontSize(15).fontColor(INK).lineHeight(23)
      }.width('100%').alignItems(HorizontalAlign.Start).padding(18).backgroundColor(Color.White).borderRadius(16)
      Column({ space: 8 }) {
        Text('项目致谢').fontSize(17).fontWeight(FontWeight.Bold).fontColor(INK)
        Text('影视源和播放流程参考 LibreTV 与 LunaTV，界面风格参考曲间拾声。')
          .fontSize(14).fontColor(MUTED).lineHeight(22)
      }.width('100%').alignItems(HorizontalAlign.Start).padding(18).backgroundColor(Color.White).borderRadius(14)
    }.width('100%')
  }

  private async clearHistory(): Promise<void> {
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: '清空播放历史？',
        message: '本机的播放记录和续播进度将被删除。',
        buttons: [{ text: '取消', color: MUTED }, { text: '清空', color: GREEN }]
      });
      if (result.index === 1) {
        this.history = [];
        this.save('history', '[]');
      }
    } catch (_) {
      // Closing the dialog leaves history intact.
    }
  }

  @Builder
  historyPage() {
    Column({ space: 10 }) {
      if (!this.history.length) {
        this.label('播放过的视频会显示在这里')
      } else {
        Row() {
          Text('播放记录').fontSize(17).fontColor(INK).layoutWeight(1)
          Button('清空').height(34).fontSize(13).fontColor(GREEN).backgroundColor(Color.White)
            .onClick(() => { void this.clearHistory(); })
        }.width('100%')
      }
      ForEach(this.history, (item: RecordItem) => {
        Row() {
          Column({ space: 5 }) {
            Text(item.title).fontColor(INK).fontSize(17)
            Text(item.episode.name + ' · ' + Math.floor(item.position / 60) + ' 分 ' +
              Math.floor(item.position % 60) + ' 秒').fontSize(13).fontColor(MUTED)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text('继续播放').fontColor(GREEN).fontSize(14)
            .onClick(() => {
              if (item.media) {
                void this.openTitle(item.media, item);
                return;
              }
              this.generation++;
              this.busy = false;
              this.status = '';
              this.title = item.title;
              this.play(item.episode, item.position);
            })
          Button('移除').fontColor(MUTED).backgroundColor(TINT).height(32).margin({ left: 10 })
            .onClick(() => {
              this.history = this.history.filter((entry: RecordItem) => entry.episode.url !== item.episode.url);
              this.save('history', JSON.stringify(this.history));
            })
        }.width('100%').padding(14).borderRadius(14).backgroundColor(Color.White)
      }, (item: RecordItem) => item.episode.url)
    }.width('100%')
  }

  @Builder
  castPickerLabel() {
    Text('投屏').fontSize(13).fontColor(INK).padding({ left: 8, right: 8 })
      .height(32).textAlign(TextAlign.Center).backgroundColor(SELECTED).borderRadius(16)
  }

  @Builder
  player(episode: Episode, attempt: number) {
    Stack({ alignContent: Alignment.Bottom }) {
      Video({ src: episode.url, controller: this.controller, currentProgressRate: this.speed })
        .width('100%').height('100%').backgroundColor(Color.Black)
        .autoPlay(true).controls(false).objectFit(ImageFit.Contain)
        .onPrepared((event) => {
          if (attempt === this.attempt && event) {
            this.duration = event.duration;
            if (this.resumeAt > 0 && this.resumeAt < event.duration - 3) {
              this.controller.setCurrentTime(this.resumeAt, SeekMode.Accurate);
            }
            this.resumeAt = 0;
          }
        })
        .onStart(() => {
          if (attempt === this.attempt && attempt !== this.failedAttempt && !this.castDevice) {
            this.playing = true;
            this.scheduleControlsHide();
            this.armWatchdog(episode, attempt);
            this.updateCastSession();
          }
        })
        .onUpdate((event) => {
          if (event && !this.castDevice) {
            this.updatePlayback(episode, attempt, event.time);
          }
        })
        .onPause(() => {
          if (attempt === this.attempt) {
            this.playing = false;
            this.cancelControlsTimer();
            this.stopWatchdog();
            this.checkpoint(true);
            this.updateCastSession();
          }
        })
        .onFinish(() => { if (!this.castDevice) this.finishEpisode(attempt); })
        .onError(() => { if (!this.castDevice) void this.recover(episode, attempt); })
      Column() {}.width('100%').height('100%').onClick(() => {
        if (this.locked) {
          this.unlockVisible = !this.unlockVisible;
        } else if (this.controlsVisible) {
          this.hideControls();
        } else {
          this.controlsVisible = true;
          this.scheduleControlsHide();
        }
      })
      if (this.locked) {
        if (this.unlockVisible || !this.fullscreen) {
          Button('解锁').fontColor(INK).backgroundColor(SELECTED).margin(12)
            .onClick(() => { this.locked = false; this.unlockVisible = false; })
        }
      } else if (this.controlsVisible || this.playbackError || this.castDevice) {
        Column({ space: 3 }) {
          if (this.castDevice) {
            Text('投屏到 ' + this.castDevice).fontColor(Color.White).fontSize(13).width('100%')
          }
          if (this.playbackError || this.playbackNotice) {
            Text(this.playbackError || this.playbackNotice).fontColor(Color.White).fontSize(13).width('100%')
          }
          Row({ space: 6 }) {
            Text(this.timeLabel(this.progress)).fontColor(Color.White).fontSize(12)
            Slider({ value: this.progress, min: 0, max: Math.max(1, this.duration), step: 1 })
              .layoutWeight(1).height(28).trackThickness(2).blockSize({ width: 10, height: 10 })
              .enabled(this.duration > 0)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.cancelControlsTimer();
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  if (this.castDevice) {
                    this.sendCastCommand({ command: 'seek', parameter: Math.round(value * 1000) });
                  } else {
                    this.controller.setCurrentTime(value, SeekMode.Accurate);
                  }
                  this.scheduleControlsHide();
                }
              })
            Text(this.timeLabel(this.duration)).fontColor(Color.White).fontSize(12)
          }.width('100%')
          Row({ space: 6 }) {
            Button(this.castDevice ? (this.castPlaying ? '暂停' : '播放') :
              (this.playbackError ? '重试' : (this.playing ? '暂停' : '播放'))).height(32).fontSize(13)
              .backgroundColor(GREEN).onClick(() => {
                if (this.castDevice) {
                  this.sendCastCommand({ command: this.castPlaying ? 'pause' : 'play' });
                } else if (this.playbackError) {
                  this.play(episode, this.currentTime);
                } else if (this.playing) {
                  this.controller.pause();
                } else if (attempt === this.failedAttempt) {
                  this.play(episode, 0);
                } else {
                  this.controller.start();
                }
              })
            if (!this.castDevice) {
              Button(this.speed + '×').height(32).fontSize(13).fontColor(INK).backgroundColor(SELECTED)
              .bindMenu([0.75, 1, 1.25, 1.5, 1.75, 2].map((rate: number): MenuElement => ({
                value: rate + '×',
                action: () => { this.speed = rate; this.save('speed', String(rate)); this.scheduleControlsHide(); }
              })))
            }
            Blank()
            if (this.castDevice) {
              Button('停止投屏').height(32).fontSize(13).fontColor(INK).backgroundColor(SELECTED)
                .onClick(() => { void this.stopCast(); })
            } else {
              if (this.castReady) {
                AVCastPicker({
                  sessionType: 'video',
                  customPicker: () => { this.castPickerLabel() },
                  onStateChange: (state: AVCastPickerState) => {
                    this.pickerOpen = state === AVCastPickerState.STATE_APPEARING;
                    if (this.pickerOpen) {
                      this.cancelControlsTimer();
                    } else {
                      this.scheduleControlsHide();
                    }
                  }
                }).width(48).height(32)
              }
              Button('锁定').height(32).fontSize(13).fontColor(INK).backgroundColor(SELECTED)
                .onClick(() => { this.hideControls(); this.locked = true; this.unlockVisible = true; })
            }
            Button(this.fullscreen ? '退出全屏' : '全屏').height(32).fontSize(13)
              .fontColor(INK).backgroundColor(SELECTED).onClick(() => this.setFullscreen(!this.fullscreen))
          }.width('100%')
        }.padding({ left: 8, right: 8, top: 2, bottom: 5 }).width('100%').backgroundColor('#CC000000')
      }
    }.width('100%').height('100%').clip(true)
  }

  @Builder
  detailPage() {
    Column({ space: 12 }) {
      if (this.selectedTitle && !this.locked) {
        Row() {
          Text(this.selectedTitle.source.name).fontSize(13).fontColor(MUTED).layoutWeight(1)
          Button(this.isFavorite(this.selectedTitle) ? '已收藏' : '收藏')
            .height(34).fontSize(14).fontColor(GREEN).backgroundColor(SELECTED)
            .onClick(() => {
              if (this.selectedTitle) {
                this.toggleFavorite(this.selectedTitle);
              }
            })
        }.width('100%')
        if (this.titleChoices.length > 1) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.titleChoices, (choice: Title) => {
              Button(choice.source.name).fontSize(13).fontColor(GREEN).backgroundColor(SELECTED)
                .margin({ right: 8, bottom: 8 })
                .enabled(!this.busy && this.selectedTitle !== undefined &&
                  this.titleKey(choice) !== this.titleKey(this.selectedTitle))
                .onClick(() => {
                  const record: RecordItem | undefined = this.active ?
                    { title: this.title, episode: this.active, position: this.currentTime } : undefined;
                  void this.openTitle(choice, record);
                })
            }, (choice: Title) => this.titleKey(choice))
          }.width('100%')
        }
        Button('片头片尾设置').height(34).fontColor(GREEN).backgroundColor(SELECTED)
          .onClick(() => {
            this.introInput = String(this.skipRule?.intro ?? 0);
            this.outroInput = String(this.skipRule?.outro ?? 0);
            this.skipMessage = '';
            this.skipOpen = !this.skipOpen;
          })
        if (this.skipOpen) {
          Column({ space: 8 }) {
            this.label('填写跳过秒数，填 0 关闭。设置适用于这部影片的分集。')
            TextInput({ text: this.introInput, placeholder: '片头秒数' }).type(InputType.Number)
              .onChange((value: string) => { this.introInput = value; })
            TextInput({ text: this.outroInput, placeholder: '片尾秒数' }).type(InputType.Number)
              .onChange((value: string) => { this.outroInput = value; })
            if (this.skipMessage) {
              this.label(this.skipMessage)
            }
            Button('保存').backgroundColor(GREEN).onClick(() => this.saveSkipRule())
          }.padding(12).width('100%').backgroundColor(Color.White).borderRadius(14)
        }
      }
      if (this.active) {
        Text(this.active.name).fontColor(INK).fontSize(16).width('100%')
        if (!this.locked && this.episodeIndex >= 0 && this.episodeQueue.length > 1) {
          Row({ space: 8 }) {
            Button('上一集').enabled(this.episodeIndex > 0).backgroundColor(TINT).fontColor(INK)
              .onClick(() => this.playQueueItem(this.episodeIndex - 1))
            Button('下一集').enabled(this.episodeIndex + 1 < this.episodeQueue.length)
              .backgroundColor(GREEN).onClick(() => this.playQueueItem(this.episodeIndex + 1))
          }.width('100%')
        }
      }
      if (this.playbackError) {
        this.label(this.playbackError)
      }
      if (this.playbackNotice) {
        this.label(this.playbackNotice)
      }
      if (this.busy) {
        this.label('正在加载分集…')
      }
      if (this.status) {
        this.label(this.status)
      }
      if (!this.locked && this.lines.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.lines, (item: Line, index: number) => {
            Button(item.name).fontSize(13).fontColor(index === this.line ? Color.White : INK)
              .backgroundColor(index === this.line ? GREEN : TINT).margin({ right: 8, bottom: 8 })
              .onClick(() => { this.line = index; })
          })
        }.width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.lines[this.line].episodes, (episode: Episode, index: number) => {
            Button(episode.name).fontSize(13).fontColor(this.active?.url === episode.url ? Color.White : INK)
              .backgroundColor(this.active?.url === episode.url ? GREEN : Color.White)
              .margin({ right: 8, bottom: 8 }).onClick(() => this.playFromLine(index))
          })
        }.width('100%')
      }
    }.width('100%')
  }

  build() {
    Column({ space: 12 }) {
      if (!this.fullscreen) {
      Row({ space: 10 }) {
        if (this.aboutOpen) {
          Button('返回').fontColor(GREEN).backgroundColor(TINT).onClick(() => { this.aboutOpen = false; })
        } else if (this.title) {
          Button('返回').fontColor(GREEN).backgroundColor(TINT).onClick(() => this.leaveTitle())
        }
        Text(this.aboutOpen ? '关于我们' : this.title || ['搜索', '片单', '设置'][this.tab])
          .fontSize(30).fontWeight(FontWeight.Bold).fontColor(INK)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (!this.title && !this.aboutOpen) {
          Text($r('app.string.app_name')).fontSize(14).fontColor(GREEN)
        }
      }.width('100%').constraintSize({ maxWidth: 760 }).padding({ top: 10 })
      }
      if (this.active) {
        Column() {
          ForEach([this.attempt], (attempt: number) => {
            this.player(this.active!, attempt)
          }, (attempt: number) => String(attempt))
        }.width('100%').height(this.fullscreen ? '100%' : 220)
          .constraintSize({ maxWidth: this.fullscreen ? '100%' : 760 })
          .borderRadius(this.fullscreen ? 0 : 14).clip(true)
      }
      if (!this.fullscreen) {
      Scroll() {
        Column() {
          if (this.aboutOpen) {
            this.aboutPage()
          } else if (this.title) {
            this.detailPage()
          } else if (this.tab === 0) {
            this.searchPage()
          } else if (this.tab === 1) {
            this.libraryPage()
          } else {
            this.settingsPage()
          }
        }.width('100%')
      }.layoutWeight(1).width('100%').constraintSize({ maxWidth: 760 }).align(Alignment.Top)
      if (!this.title && !this.aboutOpen) {
        Row({ space: 4 }) {
          ForEach(['搜索', '片单', '设置'], (label: string, index: number) => {
            Button(label).layoutWeight(1).height(40).fontSize(14)
              .fontColor(this.tab === index ? GREEN : MUTED)
              .backgroundColor(this.tab === index ? SELECTED : Color.Transparent)
              .onClick(() => { this.tab = index; })
          })
        }.width('100%').constraintSize({ maxWidth: 760 }).padding(5).backgroundColor(Color.White).borderRadius(14)
      }
      }
    }.width('100%').height('100%')
      .padding({ left: this.fullscreen ? 0 : 18, right: this.fullscreen ? 0 : 18,
        bottom: this.fullscreen ? 0 : 8 }).backgroundColor(this.fullscreen ? Color.Black : PAPER)
      .expandSafeArea(this.fullscreen ? [SafeAreaType.SYSTEM, SafeAreaType.CUTOUT] : [],
        [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
  }
}
