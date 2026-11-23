import { createHash } from 'node:crypto';
import { cardNavigation, siteIntegrationEnabled } from './catalog.mjs';
import { normalizePanShare } from './home-library.mjs';

function diskType(input) {
  if (/^magnet:/i.test(input)) return 'magnet';
  if (/^ed2k:/i.test(input)) return 'ed2k';
  let url;
  try { url = new URL(input); } catch { return ''; }
  const host = url.hostname.toLowerCase();
  const domains = [
    ['quark', /^pan\.q(?:u|o)ark\.cn$/], ['uc', /^drive\.uc\.cn$/],
    ['baidu', /^pan\.baidu\.com$/], ['aliyun', /^(www\.)?(aliyundrive|alipan)\.com$/],
    ['tianyi', /^cloud\.189\.cn$/], ['115', /^(www\.)?(115|115cdn|anxia)\.com$/],
    ['123', /^(?:(?:www\.)?123(?:pan|684|685|865|912|592)\.(?:com|cn)|(?:[a-z0-9-]+\.)?share\.123(?:pan|684|685|865|912|592)\.(?:com|cn))$/],
    ['xunlei', /^pan\.xunlei\.com$/], ['mobile', /^(?:(?:www\.)?(?:caiyun|yun)\.139\.com|caiyun\.feixin\.10086\.cn)$/],
    ['guangya', /^(www\.)?guangyapan\.com$/], ['pikpak', /^(?:(www\.)?(my)?pikpak\.com|toapp\.mypikpak\.com)$/],
  ];
  return domains.find(([, pattern]) => pattern.test(host))?.[0] || '';
}

// Only immediate leaf data is considered. In particular never search an opaque
// ID for URLs: group IDs can contain hundreds of nested shares.
export function sitePanShare(item, site) {
  if (!siteIntegrationEnabled(site.panCheck) || ['folder', 'search'].includes(cardNavigation(item, site).kind)) return undefined;
  const raw = item.panShare && typeof item.panShare === 'object' ? item.panShare : { url: item.vod_id ?? item.id };
  if (typeof raw.url !== 'string' || raw.url.length > 2048) return undefined;
  if (!item.panShare && !/^(https?:\/\/|magnet:\?|ed2k:\/\/)/i.test(raw.url)) return undefined;
  const first = normalizePanShare(raw.url, raw.password);
  const type = first && diskType(first.input);
  if (!type) return undefined;
  const share = normalizePanShare(raw.url, raw.password, type);
  if (!share) return undefined;
  return {
    id: createHash('sha256').update(JSON.stringify([type, share.input, share.password])).digest('hex'),
    url: share.input, password: share.password, diskType: type,
    datetime: String(raw.datetime ?? '').slice(0, 80),
  };
}
