import http from 'node:http';
import https from 'node:https';
import { syncBuiltinESMExports } from 'node:module';
import { urlToHttpOptions } from 'node:url';
import { waitForSignal } from './abort.mjs';
import { AppError } from './errors.mjs';

export function runSourceRequest(context, request, response, handler, receiver) {
  const controller = new AbortController();
  let finished = false;
  const cleanup = () => {
    request.removeListener('aborted', cancel);
    response.removeListener('close', closed);
    response.removeListener('finish', complete);
  };
  const search = request.headers['x-yingxia-search'] === '1';
  const scope = { playSessionId: request.headers['x-wincat-play-session'],
    requestPath: request.headers['x-wincat-request-path'] || new URL(request.url || '/', 'http://local').pathname,
    signal: controller.signal, search, searchOperation: request.headers['x-yingxia-search-operation'],
    activeHTTP: 0, maximumBytes: search ? 8 * 1024 * 1024 : undefined,
    successful: false, detached: new Set() };
  const complete = () => {
    finished = true;
    if (search) controller.abort(new AppError('API_CANCELLED', '站点搜索已结束'));
    else {
      scope.successful = true;
      for (const detach of scope.detached) detach();
      scope.detached.clear();
    }
    cleanup();
  };
  const cancel = () => {
    controller.abort(new AppError('API_CANCELLED', '站点请求已取消'));
    cleanup();
  };
  const closed = () => {
    // writableFinished may become true before the finish event. A disconnect
    // in that gap must still release the source's finish-bound limiter leases.
    if (!finished) cancel();
    else cleanup();
  };
  request.once('aborted', cancel);
  response.once('close', closed);
  response.once('finish', complete);
  // Successful play replies may start background danmaku work. Only a client
  // disconnect before the reply finishes cancels work belonging to this scope.
  return context.run(scope, () => handler.call(receiver, request, response));
}

function isLocalBridge(input, options, port, protocol = 'http:') {
  if (!Number.isInteger(port) || port <= 0) return false;
  try {
    const target = typeof input === 'string' || input instanceof URL
      ? { ...urlToHttpOptions(new URL(input)), ...(options && typeof options === 'object' ? options : {}) }
      : input || {};
    const host = String(target.hostname || target.host || 'localhost').toLowerCase();
    return !target.socketPath && (target.protocol || protocol) === 'http:'
      && ['127.0.0.1', 'localhost', '::1', '[::1]'].includes(host)
      && Number(target.port || 80) === port && (target.path || '/') === '/msg';
  } catch { return false; }
}

export function installRequestCancellation(context, { bridgePort = () => undefined, activity = () => {} } = {}) {
  const originals = [];
  const tracked = new WeakSet();
  for (const module of [http, https]) for (const method of ['request', 'get']) {
    const original = module[method];
    originals.push(() => { module[method] = original; });
    module[method] = function (...args) {
      const scope = context.getStore(), signal = scope?.signal;
      const request = original.apply(this, args);
      // Legacy bundles POST to catDartServerPort instead of calling the global
      // bridge function. Carry the token only across that exact local boundary.
      if (scope?.playSessionId && !request.headersSent && request.method === 'POST'
        && isLocalBridge(args[0], args[1], bridgePort(), module === https ? 'https:' : 'http:'))
      {
        request.setHeader('X-Wincat-Play-Session', scope.playSessionId);
        if (scope.requestPath) request.setHeader('X-Wincat-Request-Path', scope.requestPath);
      }
      if (!signal || tracked.has(request)) return request;
      tracked.add(request);
      let counted = false;
      if (scope.search) {
        if (scope.activeHTTP >= 4) {
          request.destroy(Object.assign(new Error('The source has too many pending HTTP requests'), { code: 'ERR_SEARCH_HTTP_BUSY' }));
          return request;
        }
        scope.activeHTTP += 1; counted = true;
        // Observe pushed bytes before client data handlers allocate/parse the body.
        request.prependOnceListener('response', response => {
          let received = 0;
          const tooLarge = () => {
            const error = Object.assign(new Error('The source response exceeds the 8 MB search limit'), { code: 'ERR_RESPONSE_TOO_LARGE' });
            request.destroy(error); response.destroy(error);
          };
          if (Number(response.headers['content-length']) > scope.maximumBytes) { tooLarge(); return; }
          const push = response.push;
          response.push = function (chunk, ...rest) {
            if (chunk) {
              received += chunk.length;
              if (received > scope.maximumBytes) { tooLarge(); return false; }
            }
            return push.call(this, chunk, ...rest);
          };
        });
      }
      let trackedOperation = !scope.search && scope.successful ? undefined : scope.searchOperation;
      if (trackedOperation) activity(1, scope.search, trackedOperation);
      else if (scope.searchOperation) activity(1, false);
      const detach = () => {
        if (!trackedOperation) return;
        activity(0, false, trackedOperation, -1);
        trackedOperation = undefined;
      };
      if (trackedOperation && !scope.search) scope.detached.add(detach);
      const abort = () => request.destroy(signal.reason);
      const cleanup = () => {
        signal.removeEventListener('abort', abort);
        if (counted) { counted = false; scope.activeHTTP -= 1; }
        if (scope.searchOperation) activity(-1, scope.search, trackedOperation);
        scope.detached.delete(detach);
      };
      signal.addEventListener('abort', abort, { once: true });
      request.once('close', cleanup);
      // Preserve ClientRequest's asynchronous error contract even for an
      // already-cancelled retry. Axios can then attach config and release its
      // own inflight gate instead of retaining a slot until its safety timer.
      if (signal.aborted) abort();
      return request;
    };
  }
  const originalFetch = globalThis.fetch;
  globalThis.fetch = function (input, options = {}) {
    const scope = context.getStore(), signal = scope?.signal;
    if (scope?.playSessionId && String(options?.method || input?.method || 'GET').toUpperCase() === 'POST'
      && isLocalBridge(typeof input === 'string' || input instanceof URL ? input : input?.url, undefined, bridgePort())) {
      const headers = new Headers(options?.headers ?? input?.headers);
      headers.set('X-Wincat-Play-Session', scope.playSessionId);
      if (scope.requestPath) headers.set('X-Wincat-Request-Path', scope.requestPath);
      options = { ...options, headers };
    }
    if (!signal) return originalFetch.call(this, input, options);
    const supplied = options?.signal === undefined ? input?.signal : options.signal;
    return originalFetch.call(this, input, { ...options,
      ...(scope.search ? { maximumBytes: scope.maximumBytes, retryReusedSocket: false } : {}),
      signal: supplied ? AbortSignal.any([signal, supplied]) : signal });
  };
  syncBuiltinESMExports();
  return () => {
    originals.forEach(restore => restore());
    globalThis.fetch = originalFetch;
    syncBuiltinESMExports();
  };
}

const patched = new WeakSet();
export function patchSourceLimiters(registry, context) {
  const limiter = registry?.['concurrency-limiter']?.getLimiter?.();
  const prototype = limiter && Object.getPrototypeOf(limiter);
  if (!prototype || typeof prototype.acquire !== 'function' || patched.has(prototype)) return;
  const acquire = prototype.acquire;
  prototype.acquire = function (...args) {
    const signal = context.getStore()?.signal;
    if (!signal) return acquire.apply(this, args);
    signal.throwIfAborted();
    const acquired = Promise.resolve(acquire.apply(this, args)).then(release => {
      let released = false;
      const finish = () => {
        if (released) return;
        released = true;
        signal.removeEventListener('abort', finish);
        release();
      };
      signal.addEventListener('abort', finish, { once: true });
      if (signal.aborted) { finish(); signal.throwIfAborted(); }
      return finish;
    });
    // A queued request can be cancelled before acquiring a slot. Observe its
    // eventual acquisition and immediately release it, without running its site.
    return waitForSignal(acquired, signal);
  };
  patched.add(prototype);
}
