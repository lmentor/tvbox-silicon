import { createHash } from 'node:crypto';

// Serialized into the subscribed CommonJS module. Keep this function self-contained.
export async function biliOfficialChoices(initial, fetchQuality) {
  const choices = [];
  const available = new Map();
  let firstPlayable;
  const is1080 = id => [80, 112, 116].includes(id);
  const codecRank = (video, preferHEVC) => {
    const codec = String(video.codecs || '').toLowerCase();
    if (/^(avc|h264)/.test(codec) || Number(video.codecid) === 7) return preferHEVC ? 1 : 0;
    if (/^(hvc|hev|h265)/.test(codec) || Number(video.codecid) === 12) return preferHEVC ? 0 : 1;
    return 2;
  };
  function prefer(video, original, id) {
    if (video.height !== original.height || video.width !== original.width) return false;
    const colorFields = ['color_transfer', 'color_primaries', 'video_range', 'hdr_type'];
    if (colorFields.some(key => video[key] !== original[key])) return false;
    if ([125, 126].includes(id) && !original.color_transfer && !original.hdr_type && !original.video_range) return false;
    return codecRank(video, id >= 120) < codecRank(original, id >= 120);
  }
  function collect(dash) {
    for (const video of Array.isArray(dash?.video) ? dash.video : []) {
      const id = Number(video?.id);
      if (!(video?.backup_url?.[0] || video?.backupUrl?.[0] || video?.base_url || video?.baseUrl)) continue;
      firstPlayable ??= { video, dash };
      if (!id) continue;
      // A widescreen crop may have fewer than 1080 lines. Portrait uses the short edge.
      const shortEdge = Math.min(Number(video.width) || Infinity, Number(video.height) || Infinity);
      if (is1080(id) && Number.isFinite(shortEdge) && shortEdge > 1080) continue;
      const current = available.get(id);
      if (!current || prefer(video, current.video, id)) {
        available.set(id, { video, dash });
      }
    }
  }
  collect(initial.dash);
  const advertised = Array.isArray(initial.accept_quality) ? initial.accept_quality.map(Number) : [];
  const labelFor = (id, video) => initial.accept_description?.[advertised.indexOf(id)]
    || (video.height ? video.height + 'P' : 'DASH ' + id);
  // Keep the source menu order and its usual four entries, including explicit
  // 1080p/4K/HDR choices even if the provider places them farther down the menu.
  const menu = advertised.length ? advertised.filter((id, i) => i < 4 || [80, 120, 125].includes(id))
    : [...available.keys()];
  for (const id of new Set(menu)) {
    if (!available.has(id) && id !== 120) {
      // The initial authenticated request already requested 120.
      try { collect((await fetchQuality(id))?.dash); } catch { /* Retain other playable entries. */ }
    }
    const row = available.get(id);
    if (row) choices.push({ ...row, label: labelFor(id, row.video) });
  }
  if (!choices.length && available.size) {
    const id = Math.max(...available.keys());
    const row = available.get(id);
    choices.push({ ...row, label: labelFor(id, row.video) });
  } else if (!choices.length && firstPlayable) {
    const height = firstPlayable.video.height;
    choices.push({ ...firstPlayable, label: height ? height + 'P' : 'DASH' });
  }
  return choices;
}

const bundleHash = '992a3990d0261122727d1c91013cd14f39f86eba290eb738902ef15d12fac067';
const select = 'let f=(u.accept_quality||[120,116,112,80]).slice(0,4),p=[];for(let m of f)try{let h=m===120?u:await jPr({epId:n,cid:a,qn:m,server:e.server}),g=h?.dash;if(!g?.video?.length)continue;let y=VPr(g.video,E=>Number(E?.id)||0),';
const label = 'p.push(h.accept_description?.[h.accept_quality?.indexOf(m)]||`${m}P`,';

export function adaptBiliOfficialBundle(original, source = original) {
  if (!source.includes(select) || createHash('sha256').update(original).digest('hex') !== bundleHash)
    return { source, applied: false };
  const selector = `let f=await (${biliOfficialChoices.toString()})(u,qn=>jPr({epId:n,cid:a,qn,server:e.server})),p=[];for(const m of f)try{let {dash:g,video:y}=m,`;
  // Replace in just this handler. The subscription still constructs the source
  // proxy URLs, pairs the audio, supplies headers, and handles non-DASH playback.
  const start = source.indexOf(select);
  const end = source.indexOf('if(p.length)return', start);
  const loop = source.slice(start, end);
  if (end < 0 || !loop.includes(label)) return { source, applied: false };
  const adapted = loop.replace(select, () => selector).replace(label, 'p.push(m.label,');
  return { source: source.slice(0, start) + adapted + source.slice(end), applied: true };
}
