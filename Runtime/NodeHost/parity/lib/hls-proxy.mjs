import { createHash, randomBytes } from 'node:crypto';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fetchResponse } from './http.mjs';
import { normalizeHeaders } from './playback.mjs';
import { cleanHlsPlaylist, hlsCacheTimeline } from './hls-cleaner.mjs';
import { fetchScopedMedia, scopedMediaHeaders } from './media-cache.mjs';
import { ForwardMediaReader } from './forward-media.mjs';

const httpUrl = value => typeof value === 'string' && /^https?:\/\//i.test(value);
function isHls(quality, inferProxy) {
  if (quality.format === 'm3u8' || /\.m3u8(?:[?#]|$)/i.test(quality.url)) return true;
  if (!inferProxy || quality.format) return false;
  try {
    const url = new URL(quality.url);
    if (!/\/(?:proxy|m3u8-clean)\/?$/i.test(url.pathname)) return false;
    if (/^(?:m3u8|hls)$/i.test(url.searchParams.get('type') || url.searchParams.get('format') || '')) return true;
    // Python proxies often hide a signed playlist in an encoded query value.
    // Inspect a parsed copy, keeping the original URL and its signature intact.
    return ['url', 'source'].some(name => {
      const target = url.searchParams.get(name);
      return httpUrl(target) && /\.m3u8$/i.test(new URL(target).pathname);
    });
  } catch { return false; }
}
const responseHeaders = ['content-type', 'content-range', 'accept-ranges', 'etag', 'last-modified'];
const crossOriginLiveHeaders = new Set(['range', 'if-range', 'accept-encoding', 'user-agent', 'accept', 'accept-language']);
function scopedLiveHeaders(headers, source, target) {
  const fields = [...new Headers(headers)];
  return Object.fromEntries(new URL(source).origin === new URL(target).origin
    ? fields : fields.filter(([name]) => crossOriginLiveHeaders.has(name)));
}

function finiteMedia(response) {
  const length = Number(response.headers.get('content-length'));
  if (![200, 206].includes(response.status) || !Number.isSafeInteger(length) || length <= 0
    || ![null, 'identity'].includes(response.headers.get('content-encoding'))) return null;
  let start = 0, end = length - 1, total = length;
  if (response.status === 206) {
    const range = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(response.headers.get('content-range') || '');
    if (!range) return null;
    [start, end, total] = range.slice(1).map(Number);
    if (![start, end, total].every(Number.isSafeInteger) || start < 0 || end < start || end >= total || end - start + 1 !== length) return null;
  }
  const etag = response.headers.get('etag');
  const validatorName = etag && !etag.startsWith('W/') ? 'etag' : 'last-modified';
  return { start, end, total, length, validatorName, validator: response.headers.get(validatorName) };
}

// URLs are unguessable capabilities. Upstream addresses and credentials remain
// in memory; the endpoint never accepts an arbitrary target from the client.
export class HlsProxy {
  constructor({ baseUrl, timeoutMs = 60_000, maxPlaylistBytes = 8 * 1024 * 1024,
    liveRetentionMs = 5 * 60_000, liveResourceBytes = 8 * 1024 ** 2, now = Date.now } = {}) {
    this.baseUrl = typeof baseUrl === 'function' ? baseUrl : () => baseUrl;
    this.timeoutMs = timeoutMs;
    this.maxPlaylistBytes = maxPlaylistBytes;
    Object.assign(this, { liveRetentionMs, liveResourceBytes, now });
    this.contexts = new Map();
    this.sessions = new Map();
    this.selections = new Map();
    this.prefetches = new Map();
    this.prefetchDrains = new Map();
    this.prefetchCleanups = new Set();
  }

  prepare(session, { enabled = true, forceProxy = false, mediaCache, cacheOwner, scopeIPTVHeaders = false, sniffInput = false } = {}) {
    if (!session?.id || session.parse || !this.baseUrl()) return session;
    session.qualities = (session.qualities || []).map(quality => {
      if (quality.hlsAdClean) {
        const existing = this.lookup(quality.url);
        if (existing) existing.context.enabled = enabled;
        return quality;
      }
      if ((!enabled && !forceProxy) || !httpUrl(quality.url) || (!scopeIPTVHeaders && !sniffInput && !isHls(quality, !session.parse))) return quality;
      const token = randomBytes(24).toString('hex');
      const context = { token, sessionId: session.id, headers: normalizeHeaders(quality.headers),
        resources: new Map(), windows: new Map(), controller: new AbortController(), enabled, scopeIPTVHeaders, sniffInput,
        live: session.isLive === true || session.request?.isLive === true };
      if (mediaCache && cacheOwner && !context.live) Object.assign(context, { mediaCache, cacheOwner });
      this.contexts.set(token, context);
      if (!this.sessions.has(session.id)) this.sessions.set(session.id, new Set());
      this.sessions.get(session.id).add(token);
      const prepared = { ...quality, originalUrl: quality.url,
        originalHeaders: { ...quality.headers }, hlsAdClean: true,
        url: this.register(context, quality.url, (!scopeIPTVHeaders && !sniffInput) || isHls(quality, !session.parse)),
        format: scopeIPTVHeaders || sniffInput ? quality.format : 'm3u8' };
      if (httpUrl(quality.fallbackUrl)) {
        prepared.originalFallbackUrl = quality.fallbackUrl;
        prepared.fallbackUrl = this.register(context, quality.fallbackUrl, true);
      }
      return prepared;
    });
    // Stale sessions are normally released at commit/stop. This also bounds
    // retention for callers that forget to signal a replaced session.
    while (this.sessions.size > 16) this.release(this.sessions.keys().next().value);
    return session;
  }

  lookup(address) {
    let match;
    try { match = new URL(address).pathname.match(/^\/hls\/([a-f\d]{48})\/([a-f\d]{32})\.[a-z\d]{1,8}$/i); } catch { return null; }
    const context = match && this.contexts.get(match[1]), resource = context?.resources.get(match[2]);
    return resource ? { context, resource, id: match[2] } : null;
  }

  rewrite(context, resource, original, sourceUrl, scopedHeaders = context.headers) {
    const collected = new Set();
    const cleaned = cleanHlsPlaylist(original, sourceUrl, {
      enabled: context.enabled && !context.separateRenditions,
      rewriteUri: (target, { playlist }) => this.register(context, target, playlist, collected,
        context.speculative ? scopedMediaHeaders(scopedHeaders, sourceUrl, target)
          : context.cacheOwner ? scopedMediaHeaders(scopedHeaders, sourceUrl, target)
          : context.live || context.scopeIPTVHeaders ? scopedLiveHeaders(scopedHeaders, sourceUrl, target) : context.headers),
    });
    const live = /^#EXTINF:/m.test(original) && !/^#EXT-X-ENDLIST/m.test(original);
    const id = [...context.resources].find(([, item]) => item === resource)?.[0];
    this.retainPlaylist(context, id, collected, live);
    const timeline = context.mediaCache && !live ? hlsCacheTimeline(cleaned.content, sourceUrl) : null;
    // Resolve local route identities once, while rewriting the manifest. The
    // per-second statistics call only checks the small acquired byte ranges.
    const resolve = entries => entries?.map(entry => ({ ...entry,
      parts: entry.parts.map(part => ({ cached: this.lookup(part.url)?.resource.cachedMedia, range: part.range })) })) ?? null;
    resource.cacheTimeline = resolve(timeline);
    // Discontinuities invalidate a simple media-time mapping but not the
    // ordered finite segment list. Remove only those markers for scheduling;
    // never publish this synthetic continuous timeline as cachedTimeRanges.
    resource.prefetchTimeline = resource.cacheTimeline || (context.mediaCache && !live
      ? resolve(hlsCacheTimeline(cleaned.content.replace(/^#EXT-X-DISCONTINUITY\r?\n/gm, ''), sourceUrl)) : null);
    return cleaned.content;
  }

  cachedTimeRanges(sessionId, coverage) {
    const timelines = [];
    for (const token of this.sessions.get(sessionId) || []) {
      const context = this.contexts.get(token);
      if (!context || context.live || context.separateRenditions || !context.cacheOwner?.enabled || context.cacheOwner.closed) return [];
      const selection = this.selections.get(sessionId);
      for (const resource of context.resources.values())
        if (resource.cacheTimeline && (!selection || selection.context === context && selection.playlist === resource))
          timelines.push({ context, entries: resource.cacheTimeline });
    }
    // Multiple acquired variants/renditions need native selection identity.
    // Do not draw a different rendition's completed segment as current video.
    if (timelines.length !== 1) return [];
    const { context, entries } = timelines[0], ranges = [];
    const available = new Map((coverage || context.mediaCache.coverage(context.cacheOwner)).map(item => [item.id, item.ranges]));
    for (const entry of entries) {
      const ready = entry.parts.every(part => {
        const cached = part.cached;
        if (!cached || cached.owner !== context.cacheOwner) return false;
        const start = part.range?.[0] ?? 0, end = part.range?.[1] ?? cached.meta?.total;
        return Number.isSafeInteger(start) && Number.isSafeInteger(end) && end > start
          && available.get(cached.token)?.some(range => range[0] <= start && range[1] >= end);
      });
      if (!ready) continue;
      const last = ranges.at(-1);
      if (last && last[1] === entry.start) last[1] = entry.end;
      else ranges.push([entry.start, entry.end]);
    }
    return ranges.slice(0, 256);
  }

  async stopPrefetch(sessionId) {
    const state = this.prefetches.get(sessionId);
    if (!state) return this.prefetchDrains.get(sessionId);
    this.prefetches.delete(sessionId);
    state.controller.abort();
    state.cache.wakeForward();
    const cleanup = (async () => {
      await state.work;
      await Promise.allSettled(state.readers.map(reader => reader.close()));
      await Promise.allSettled(state.leases.splice(0).map(lease => state.cache.unpinCachedRange(lease)));
    })();
    this.prefetchDrains.set(sessionId, cleanup);
    this.prefetchCleanups.add(cleanup);
    try { await cleanup; } finally {
      this.prefetchCleanups.delete(cleanup);
      if (this.prefetchDrains.get(sessionId) === cleanup) this.prefetchDrains.delete(sessionId);
    }
  }

  async stopPrefetches({ clear = false } = {}) {
    const pending = [...this.prefetches.keys()].map(id => this.stopPrefetch(id));
    if (clear) this.selections.clear();
    await Promise.allSettled([...pending, ...this.prefetchCleanups]);
  }

  resumePrefetches() {
    for (const selection of this.selections.values()) this.startPrefetch(selection);
  }

  // A manifest or HEAD/cache-only probe does not prove which variant the
  // decoder selected. Only an ordinary media GET advances the disk window.
  async selectMedia(context, resource, request) {
    if (request.method !== 'GET' || !context.mediaCache || !context.cacheOwner?.enabled
      || context.cacheOwner.closed || context.live || context.separateRenditions) return null;
    const match = /^bytes=(\d+)-(\d*)$/.exec(request.headers.range || '');
    const position = match ? Number(match[1]) : null;
    const choices = [];
    for (const playlist of context.resources.values()) {
      if (!playlist.prefetchTimeline) continue;
      const index = playlist.prefetchTimeline.findIndex(entry => {
        const media = entry.parts[0];
        return media?.cached === resource.cachedMedia && (!media.range || position !== null
          && position >= media.range[0] && position < media.range[1]);
      });
      if (index >= 0) choices.push({ context, playlist, index });
    }
    if (choices.length !== 1) return null;
    const selection = choices[0];
    this.selections.set(context.sessionId, selection);
    // Drain a partially acquired future segment before the foreground opens
    // it. The normal transfer path reuses complete bytes/validated prefixes;
    // there is never a competing speculative Range on that resource.
    await this.stopPrefetch(context.sessionId);
    return selection;
  }

  startPrefetch(selection) {
    const { context, playlist, index } = selection;
    const cache = context.mediaCache, owner = context.cacheOwner, id = context.sessionId;
    const draining = this.prefetchDrains.get(id);
    if (draining) { void draining.then(() => this.startPrefetch(selection)).catch(() => {}); return; }
    if (this.selections.get(id) !== selection || this.prefetches.has(id) || context.controller.signal.aborted
      || !cache || !owner?.enabled || owner.closed || context.live || context.separateRenditions) return;
    const state = { cache, owner, selection, controller: new AbortController(), readers: [], leases: [], revision: owner.cacheRevision };
    this.prefetches.set(id, state);
    const signal = AbortSignal.any([state.controller.signal, context.controller.signal, owner.controller.signal]);
    state.work = (async () => {
      const pinned = new Set();
      // Include the current entry's key/map (the demuxer may request them in
      // either order), then continue strictly forward. A single worker and
      // pinned disk blocks share the existing 1–4 GiB forward-read budget.
      for (let next = index; next < playlist.prefetchTimeline.length; next++) {
        for (const part of playlist.prefetchTimeline[next].parts) {
          signal.throwIfAborted();
          if (!owner.enabled || owner.closed || owner.cacheRevision !== state.revision) return;
          const resource = part.cached;
          if (!resource || resource.owner !== owner) return;
          const start = part.range?.[0] ?? 0, end = part.range?.[1] ?? resource.meta?.total;
          if (Number.isSafeInteger(end) && end > start && cache.covers(resource, start, end - 1)) {
            // Advancing playback unpins the old window. Protect the nearest
            // already cached future data before fetching farther segments;
            // otherwise LRU would evict precisely what the decoder needs next.
            const key = `${resource.token}:${start}:${end}`;
            if (next > index && !pinned.has(key)) {
              const lease = await cache.pinCachedRange(resource, start, end - 1);
              if (lease) { state.leases.push(lease); pinned.add(key); }
            }
            continue;
          }
          // Do not acquire a connection solely to wait for disk space. The
          // producer takes the real reservation after its response is known.
          const reserve = Math.min(cache.blockBytes, owner.maxBytes, cache.videoMaxBytes);
          if (reserve <= 0) return;
          await cache.reserveForward(owner, reserve, signal, () => false, state.revision);
          owner.forwardBytes = Math.max(0, owner.forwardBytes - reserve); cache.wakeForward();
          signal.throwIfAborted();
          let upstream;
          try {
            upstream = await cache.open(resource, 'GET', part.range ? `bytes=${start}-${end - 1}` : 'bytes=0-', '', signal);
            signal.throwIfAborted();
            const meta = cache.accept(resource, upstream.response);
            if (!meta || !upstream.response.ok || meta.start !== start
              || part.range && (upstream.response.status !== 206 || meta.end !== end - 1)) return;
            const reader = new ForwardMediaReader(cache, resource, upstream, meta, signal, { background: true });
            state.readers.push(reader);
            upstream = null; // The reader owns this response and its lease.
            await reader.finished;
            signal.throwIfAborted();
            if (reader.error) return;
          } finally {
            upstream?.controller.abort();
            await upstream?.response.body?.cancel().catch(() => {});
            upstream?.releaseBudget?.();
          }
        }
      }
    })().catch(() => { /* Foreground playback retains its own retry/error path. */ }).finally(async () => {
      // A write failure can disable the cache inside its producer. Release
      // background pins immediately; no decoder exists to consume that queue.
      if (!owner.enabled || owner.closed || owner.cacheRevision !== state.revision) {
        await Promise.allSettled(state.readers.map(reader => reader.close()));
        await Promise.allSettled(state.leases.splice(0).map(lease => cache.unpinCachedRange(lease)));
      }
    });
  }

  register(context, url, playlist, collected, headers = context.headers) {
    if (!httpUrl(url)) return url;
    const id = createHash('sha256').update(JSON.stringify([playlist, url, headers])).digest('hex').slice(0, 32);
    if (!context.resources.has(id)) {
      if (context.resources.size >= 100_000) throw new Error('HLS playlist has too many resources');
      context.resources.set(id, { url, headers, playlist, seen: this.now(), live: false });
    }
    context.resources.get(id).seen = this.now();
    const resource = context.resources.get(id);
    if (!playlist && context.mediaCache && context.cacheOwner && !context.live && !resource.cachedMedia) {
      resource.cachedMedia = context.mediaCache.resource(context.cacheOwner, url, headers);
      resource.cachedMedia.scopedCredentials = true;
      resource.cachedMedia.resumeOnTruncation = true;
    }
    collected?.add(id);
    let extension = 'bin';
    try { extension = new URL(url).pathname.match(/\.([a-z\d]{1,8})$/i)?.[1] || extension; } catch {}
    return `${this.baseUrl()}/hls/${context.token}/${id}.${playlist ? 'm3u8' : extension}`;
  }

  retainPlaylist(context, owner, ids, live) {
    if (!live) {
      for (const id of ids) { const item = context.resources.get(id); if (item) item.vod = true; }
      return;
    }
    const previous = context.windows.get(owner)?.current || new Set();
    context.windows.delete(owner);
    context.windows.set(owner, { current: ids, previous });
    while (context.windows.size > 64) context.windows.delete(context.windows.keys().next().value);
    for (const id of ids) { const item = context.resources.get(id); if (item) item.live = true; }
    const protectedIds = new Set();
    for (const window of context.windows.values()) for (const id of [...window.current, ...window.previous]) protectedIds.add(id);
    let bytes = 0;
    for (const item of context.resources.values()) if (item.live && !item.vod) bytes += item.url.length * 2 + 128;
    const expiry = this.now() - this.liveRetentionMs;
    for (const [id, item] of context.resources) {
      if (!item.live || item.vod || item.playlist || protectedIds.has(id)) continue;
      if (item.seen < expiry || bytes > this.liveResourceBytes) {
        bytes -= item.url.length * 2 + 128;
        context.resources.delete(id);
      }
    }
  }

  release(sessionId) {
    this.selections.delete(sessionId);
    const stopped = this.stopPrefetch(sessionId);
    for (const token of this.sessions.get(sessionId) || []) {
      this.contexts.get(token)?.controller.abort();
      this.contexts.delete(token);
    }
    this.sessions.delete(sessionId);
    return stopped;
  }

  close() {
    return Promise.allSettled([...this.sessions.keys()].map(sessionId => this.release(sessionId)));
  }

  async fetch(context, resource, options) {
    if (context.speculative || context.cacheOwner) return fetchScopedMedia(resource.url, { ...options, allowInsecureRedirect: true });
    if (!context.live && !context.scopeIPTVHeaders) return fetchResponse(resource.url, options);
    // Live dispatchers can select an HTTP CDN from an HTTPS entry point.
    // Follow that media route without sending the subscription's credentials
    // or custom headers to a different origin, including its later playlists.
    let url = resource.url, headers = Object.fromEntries(new Headers(options.headers));
    const deadline = Date.now() + this.timeoutMs;
    for (let hop = 0; hop <= 5; hop++) {
      const upstream = await fetchResponse(url, { ...options, headers,
        timeoutMs: Math.max(1, deadline - Date.now()), followRedirect: false });
      if (![301, 302, 303, 307, 308].includes(upstream.response.status))
        return { ...upstream, scopedHeaders: upstream.headers };
      const location = upstream.response.headers.get('location');
      upstream.release();
      await upstream.response.body?.cancel();
      if (!location || hop === 5) throw new Error('Invalid live HLS redirect');
      const next = new URL(location, upstream.url);
      next.username = ''; next.password = ''; next.hash = '';
      headers = scopedLiveHeaders(upstream.headers, upstream.url, next);
      url = next.toString();
    }
  }

  async *mediaBody(context, resource, upstream, iterator, prefix, next, headers, signal) {
    const original = finiteMedia(upstream.response);
    const recoverable = resource.vod && !context.live && original?.validator;
    const deadline = Date.now() + this.timeoutMs;
    let received = 0, retries = 0, current = upstream;
    try {
      while (true) {
        try {
          for (const bytes of prefix) { received += bytes.length; yield bytes; }
          prefix = [];
          while (!next.done) {
            signal.throwIfAborted();
            next = await iterator.next();
            if (!next.done) {
              const bytes = Buffer.from(next.value);
              if (context.cacheOwner) context.cacheOwner.networkBytes += bytes.length;
              if (original && received + bytes.length > original.length) throw new Error('Invalid HLS media length');
              received += bytes.length; yield bytes;
            }
          }
          if (original && received !== original.length) throw new Error('Truncated HLS media');
          return;
        } catch (error) {
          signal.throwIfAborted();
          if (!recoverable || received <= 0 || received >= original.length || retries >= 2 || Date.now() >= deadline) throw error;
          retries++;
          current.release();
          await iterator.return?.().catch(() => {});
          const resumeHeaders = new Headers(headers);
          resumeHeaders.set('range', `bytes=${original.start + received}-${original.end}`);
          resumeHeaders.set('if-range', original.validator);
          current = await this.fetch(context, resource, { headers: resumeHeaders, signal, method: 'GET',
            timeoutMs: Math.max(1, deadline - Date.now()) });
          const resumed = finiteMedia(current.response);
          if (current.response.status !== 206 || !resumed || resumed.start !== original.start + received
            || resumed.end !== original.end || resumed.total !== original.total
            || current.response.headers.get(original.validatorName) !== original.validator) {
            await current.response.body?.cancel();
            throw new Error('HLS media changed or rejected the resumed range');
          }
          iterator = current.response.body[Symbol.asyncIterator]();
          next = { done: false };
        }
      }
    } finally { current.release(); await iterator.return?.().catch(() => {}); }
  }

  async handle(request, response, url, suppliedUpstream) {
    if (!url.pathname.startsWith('/hls/')) return false;
    if (!['GET', 'HEAD'].includes(request.method)) {
      response.writeHead(405, { Allow: 'GET, HEAD' }).end();
      return true;
    }
    const match = url.pathname.match(/^\/hls\/([a-f\d]{48})\/([a-f\d]{32})\.[a-z\d]{1,8}$/i);
    const context = match && this.contexts.get(match[1]);
    const resource = context?.resources.get(match[2]);
    if (!resource) {
      response.writeHead(404).end();
      return true;
    }
    const disconnected = new AbortController();
    const onClose = () => { if (!response.writableEnded) disconnected.abort(); };
    response.once('close', onClose);
    const signal = AbortSignal.any([context.controller.signal, disconnected.signal]);
    let release, suppliedDeadline, abortSupplied;
    try {
      const preview = url.searchParams.get('cacheOnly') === '1';
      if (preview && (!context.mediaCache || context.live || context.cacheOwner?.closed)) {
        response.writeHead(504, { 'Cache-Control': 'no-store' }).end(); return true;
      }
      if (resource.cachedMedia && context.mediaCache && !context.live) {
        if (preview) {
          await context.mediaCache.preview(resource.cachedMedia, request, response); return true;
        }
        const selection = await this.selectMedia(context, resource, request);
        await context.mediaCache.transfer(resource.cachedMedia.owner, resource.cachedMedia, {}, request, response, signal);
        if (selection && response.writableFinished && response.statusCode >= 200 && response.statusCode < 300)
          this.startPrefetch(selection);
        return true;
      }
      if (resource.snapshot) {
        const snapshot = resource.snapshot;
        let content = this.rewrite(context, resource, snapshot.content, snapshot.url, snapshot.headers);
        if (preview) content = this.cacheOnlyPlaylist(content);
        const bytes = Buffer.from(content);
        response.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8',
          'Content-Length': bytes.length, 'Cache-Control': 'no-store' });
        response.end(request.method === 'HEAD' ? undefined : bytes);
        return true;
      }
      if (preview) { response.writeHead(504, { 'Cache-Control': 'no-store' }).end(); return true; }
      const headers = new Headers(resource.headers);
      headers.set('accept-encoding', 'identity');
      headers.delete('range');
      headers.delete('if-range');
      if (!resource.playlist && typeof request.headers.range === 'string') {
        headers.set('range', request.headers.range);
        if (typeof request.headers['if-range'] === 'string') headers.set('if-range', request.headers['if-range']);
      }
      const upstream = suppliedUpstream || await this.fetch(context, resource, {
        headers, signal, timeoutMs: this.timeoutMs, method: request.method,
      });
      release = upstream.release;
      if (suppliedUpstream) {
        // MediaCache releases the fetch deadline to allow hour-long movies.
        // A reused playlist read still needs this proxy's bounded deadline,
        // and must stop when its HLS context or client is cancelled.
        abortSupplied = () => suppliedUpstream.controller.abort(signal.reason);
        signal.addEventListener('abort', abortSupplied, { once: true });
        if (signal.aborted) abortSupplied();
        suppliedDeadline = setTimeout(() => suppliedUpstream.controller.abort(), this.timeoutMs);
        suppliedDeadline.unref?.();
      }
      const remote = upstream.response;
      const outgoing = { 'Cache-Control': 'no-store' };
      for (const name of responseHeaders) if (remote.headers.has(name)) outgoing[name] = remote.headers.get(name);
      if (remote.headers.has('content-length') && !remote.headers.has('content-encoding'))
        outgoing['content-length'] = remote.headers.get('content-length');
      if (request.method === 'HEAD' || !remote.body) {
        // A transformed playlist has a different length from its origin.
        if (resource.playlist) delete outgoing['content-length'];
        response.writeHead(remote.status, outgoing).end();
        await remote.body?.cancel();
        return true;
      }
      const iterator = remote.body[Symbol.asyncIterator]();
      const prefix = [];
      let count = 0, next;
      do {
        next = await iterator.next();
        if (!next.done) {
          prefix.push(Buffer.from(next.value)); count += next.value.length;
          if (context.cacheOwner) context.cacheOwner.networkBytes += next.value.length;
        }
      } while (!next.done && count < 16);
      // Public unknown inputs may be DASH instead of HLS. Keep the upstream
      // base for relative MPD resources; protected inputs never leave the proxy.
      const xmlManifest = /application\/dash\+xml/i.test(remote.headers.get('content-type') || '')
        || /^\s*(?:<\?xml\b|<MPD\b)/i.test(Buffer.concat(prefix).toString('utf8', 0, 128));
      if (context.sniffInput && !context.scopeIPTVHeaders && remote.ok && xmlManifest) {
        await iterator.return?.();
        response.writeHead(307, { Location: upstream.url, 'Cache-Control': 'no-store' }).end();
        return true;
      }
      // Sniff the body as well as the declared media type. Some providers serve
      // extensionless HLS as application/octet-stream; keys remain binary.
      const playlist = remote.ok && Buffer.concat(prefix).toString('utf8', 0, 128).trimStart().startsWith('#EXTM3U');
      if (playlist) {
        const chunks = prefix;
        while (!next.done) {
          if (count > this.maxPlaylistBytes) throw new Error('HLS playlist exceeds the size limit');
          next = await iterator.next();
          if (!next.done) {
            chunks.push(Buffer.from(next.value)); count += next.value.length;
            if (context.cacheOwner) context.cacheOwner.networkBytes += next.value.length;
          }
        }
        if (count > this.maxPlaylistBytes) throw new Error('HLS playlist exceeds the size limit');
        const original = Buffer.concat(chunks).toString('utf8');
        // DEFINE/IMPORT bind variables to a playlist's original URI and parent.
        // Redirect the whole branch so the native HLS demuxer keeps that scope.
        if (/^#EXT-X-DEFINE:/m.test(original) || original.includes('{$')) {
          if (context.scopeIPTVHeaders) throw new Error('此加密线路的 HLS 变量暂不支持');
          if (context.cacheOwner) context.cacheOwner.nativeFallback = true;
          response.writeHead(307, { Location: upstream.url, 'Cache-Control': 'no-store' }).end();
          return true;
        }
        // Cutting only one of separate audio/video/subtitle playlists moves it
        // off the others' timeline. Keep all branches intact until coordinated
        // cuts across renditions are supported; dependencies still use headers.
        if (original.split(/\r?\n/).some(line => line.startsWith('#EXT-X-MEDIA:') &&
            /[:,]TYPE=(?:AUDIO|VIDEO|SUBTITLES)(?:,|$)/.test(line) && /[:,]URI=/.test(line)))
          context.separateRenditions = true;
        if (/^#EXTINF:/m.test(original) && !/^#EXT-X-ENDLIST/m.test(original)) {
          context.live = true;
          if (context.cacheOwner) context.cacheOwner.nativeFallback = true;
        }
        if (context.mediaCache && !context.live) {
          // Keep only acquired finite playlists, bounded by the same memory cap
          // as a playlist read. Media blocks remain on disk, never in snapshots.
          const size = Buffer.byteLength(original);
          const before = resource.snapshot?.bytes || 0;
          if ((context.snapshotBytes || 0) - before + size <= this.maxPlaylistBytes) {
            context.snapshotBytes = (context.snapshotBytes || 0) - before + size;
            resource.snapshot = { content: original, url: upstream.url, headers: upstream.scopedHeaders, bytes: size };
          }
        }
        const bytes = Buffer.from(this.rewrite(context, resource, original, upstream.url, upstream.scopedHeaders));
        response.writeHead(remote.status, {
          'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8',
          'Content-Length': bytes.length,
          'Cache-Control': 'no-store',
        }).end(bytes);
      } else {
        // The connection deadline protects open and sniffing. An indefinite live stream
        // can run for hours, and closes via session or downstream cancellation.
        if ((context.scopeIPTVHeaders || context.sniffInput) && context.live) upstream.release();
        response.writeHead(remote.status, outgoing);
        // Do not expose a transient segment EOF to FFmpeg's HLS demuxer: it
        // advances to the next segment on EOF, even when bytes are missing.
        // The client still receives the first prefix immediately; only a
        // validated, same-entity VOD Range can continue that response in place.
        const body = Readable.from(this.mediaBody(context, resource, upstream, iterator, prefix, next, headers, signal));
        await pipeline(body, response, { signal });
      }
    } catch {
      if (signal.aborted || response.headersSent) response.destroy();
      else response.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' }).end('播放资源读取失败，请重试或关闭 M3U8 去广告');
    } finally {
      clearTimeout(suppliedDeadline);
      if (abortSupplied) signal.removeEventListener('abort', abortSupplied);
      suppliedUpstream?.controller.abort();
      release?.();
      disconnected.abort();
      response.removeListener('close', onClose);
    }
    return true;
  }

  cacheOnlyPlaylist(content) {
    const prefix = `${this.baseUrl()}/hls/`;
    const mark = address => {
      if (!address.startsWith(prefix)) return address;
      const url = new URL(address); url.searchParams.set('cacheOnly', '1'); return url.href;
    };
    return content.split('\n').map(line => {
      if (!line.startsWith('#')) return mark(line);
      return line.replace(/([:,])URI="([^"]*)"/g, (_match, delimiter, address) => `${delimiter}URI="${mark(address)}"`);
    }).join('\n');
  }
}
