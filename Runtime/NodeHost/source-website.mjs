import { fetchResponse } from './parity/lib/http.mjs';

// Same HTML capability rule as MacCat. A catch-all JSON /config route is not a
// website, and subscriptions that publish only /website/ keep that exact path.
export async function sourceWebsite(baseURL, { signal, headers = {} } = {}) {
  signal?.throwIfAborted();
  for (const pathname of ['/website', '/website/']) {
    let response, release;
    try {
      const target = new URL(pathname, baseURL);
      ({ response, release } = await fetchResponse(target.href, { signal, headers, timeoutMs: 4000 }));
      if (!response.ok || !/text\/html|application\/xhtml\+xml/i.test(response.headers.get('content-type') || '')) continue;
      const chunks = []; let length = 0;
      for await (const chunk of response.body) {
        const bytes = Buffer.from(chunk).subarray(0, 128 * 1024 - length);
        chunks.push(bytes); length += bytes.length;
        if (length >= 128 * 1024) break;
      }
      if (/<(?:!doctype|html|body)\b/i.test(Buffer.concat(chunks).toString('utf8'))) return target.href;
    } catch {
      signal?.throwIfAborted();
    } finally {
      await response?.body?.cancel().catch(() => {});
      release?.();
    }
  }
  return '';
}
