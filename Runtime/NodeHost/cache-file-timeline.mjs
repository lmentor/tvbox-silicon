import { inspectSegmentedMP4 } from './segmented-mp4.mjs';

const maximumPrefix = 512 * 1024;
const maximumSuffix = 64 * 1024;

// Read only already-owned bytes. Statistics must never trigger an additional
// source request, reopen a Python proxy, or move the active demuxer's position.
async function cachedBytes(cache, resource, start, end) {
  if (!cache.covers(resource, start, end - 1)) return null;
  const chunks = [];
  for (let position = start; position < end;) {
    const bytes = await cache.read(resource, position, end - 1, false);
    if (!bytes?.length) return null;
    chunks.push(bytes); position += bytes.length;
  }
  return Buffer.concat(chunks);
}

async function fileIndex(cache, resource) {
  const total = resource.meta?.total;
  if (!Number.isSafeInteger(total) || total <= 0 || !resource.forwardCache) return null;
  const revision = resource.owner.cacheRevision;
  const previous = resource.fileTimeline;
  if (previous?.revision === revision && previous.total === total) return previous.segments;
  // Inspect boxes incrementally. Prefix parsing stops at mdat/moof; a large
  // regular MP4 moov or incomplete prefix is left to the native sample index.
  let count = Math.min(16, total), index;
  while (count <= maximumPrefix) {
    const bytes = await cachedBytes(cache, resource, 0, count);
    if (!bytes) return null;
    index = inspectSegmentedMP4(bytes, { includeRandomAccess: true });
    if (!index) {
      resource.fileTimeline = { revision, total, segments: null };
      return null;
    }
    if (index.segments) break;
    if (!Number.isSafeInteger(index.need) || index.need <= count || index.need > total) return null;
    count = index.need;
  }
  if (!index?.segments?.length) return null;
  const end = index.segments.at(-1).end + 1;
  if (end > total || total - end > maximumSuffix) return null;
  if (end < total) {
    const suffix = await cachedBytes(cache, resource, end, total);
    if (!suffix) return null;
    let offset = 0;
    while (offset + 8 <= suffix.length) {
      const size = suffix.readUInt32BE(offset), kind = suffix.toString('ascii', offset + 4, offset + 8);
      if (!['mfra', 'free'].includes(kind) || size < 8 || offset + size > suffix.length) return null;
      offset += size;
    }
    if (offset !== suffix.length) return null;
  }
  const segments = index.segments.map(segment => [segment.start, segment.end + 1,
    segment.time / index.timescale, (segment.time + segment.duration) / index.timescale, segment.randomAccess]);
  resource.fileTimeline = { revision, total, segments };
  return segments;
}

export async function enrichCacheCoverage(cache, id, coverage) {
  const owner = cache.owners.get(id);
  if (!owner || owner.closed || !owner.enabled) return [];
  const revision = owner.cacheRevision;
  const resources = new Map([...owner.resources.values()].map(resource => [resource.token, resource]));
  const result = [];
  for (const entry of coverage.slice(0, 64)) {
    const resource = resources.get(entry.id);
    if (!resource) continue;
    // A cache-only read can fail through eviction or disk failure while the
    // player continues. Omitting its index must not break the stats endpoint.
    const segments = await fileIndex(cache, resource).catch(() => null);
    if (owner.closed || !owner.enabled || owner.cacheRevision !== revision || cache.owners.get(id) !== owner) return [];
    // Send only fully available fragments and join contiguous ones. A long
    // movie must not resend tens of thousands of index entries every second.
    const available = [];
    let byteIndex = 0, previousEnd = -1;
    for (const segment of segments || []) {
      while (byteIndex < entry.ranges.length && entry.ranges[byteIndex][1] <= segment[0]) byteIndex++;
      const bytes = entry.ranges[byteIndex];
      if (!bytes) break;
      if (bytes[0] > segment[0] || bytes[1] < segment[1]) { previousEnd = -1; continue; }
      if (!segment[4] && previousEnd !== segment[0]) continue;
      previousEnd = segment[1];
      const last = available.at(-1);
      if (last && last[1] === segment[0] && Math.abs(last[3] - segment[2]) < 1e-7) {
        last[1] = segment[1]; last[3] = segment[3];
      } else if (available.length < 256) available.push(segment.slice(0, 4));
    }
    result.push(available.length ? { ...entry, segments: available } : entry);
  }
  return result;
}
