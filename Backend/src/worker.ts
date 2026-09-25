import { DurableObject } from 'cloudflare:workers';
import { sendPush, type PushJob } from './apns';

export interface Env {
  PAIR: DurableObjectNamespace<PairObject>;
  MEDIA: R2Bucket;
  BOOTSTRAP_TOKEN?: string;
  APNS_TEAM_ID?: string; APNS_KEY_ID?: string; APNS_PRIVATE_KEY?: string; APNS_TOPIC?: string;
}
type Device = { deviceID: string; identityPublic: string; authPublicJwk: JsonWebKey; confirmed: boolean; pushToken?: string; environment?: 'sandbox' | 'production'; alertsEnabled?: boolean; messageAlertsEnabled?: boolean; wishAlertsEnabled?: boolean };
type Pair = { pairID: string; epoch: number; devices: Device[]; active: boolean };
type Envelope = { wireVersion: number; pairID: string; epoch: number; sender: string; recipient: string; id: string; ciphertext: string; pushExpiresAt?: number; alertKind?: 'message' | 'wish' };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_BODY = 96 * 1024, TTL = 86_400_000;
class HTTPError extends Error { constructor(readonly status: number) { super('request_rejected'); } }
const json = (value: unknown, status = 200) => Response.json(value, { status, headers: { 'Cache-Control': 'no-store' } });
const hex = (buffer: ArrayBuffer) => Array.from(new Uint8Array(buffer), b => b.toString(16).padStart(2, '0')).join('');
const digest = async (s: string) => hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
const digestBytes = async (bytes: ArrayBuffer | Uint8Array) => hex(await crypto.subtle.digest('SHA-256', bytes));
const b64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
const unb64 = (s: string) => Uint8Array.from(atob(s), c => c.charCodeAt(0));
const randomToken = () => b64(crypto.getRandomValues(new Uint8Array(32))).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
async function readBody(request: Request): Promise<string> {
  if (Number(request.headers.get('content-length') ?? 0) > MAX_BODY) throw new HTTPError(413);
  if (!request.body) return '';
  const reader = request.body.getReader(); let size = 0; const chunks: Uint8Array[] = [];
  while (true) { const part = await reader.read(); if (part.done) break; size += part.value.byteLength;
    if (size > MAX_BODY) { await reader.cancel(); throw new HTTPError(413); } chunks.push(part.value); }
  const bytes = new Uint8Array(size); let offset = 0; for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
}
async function readMediaBody(request: Request): Promise<Uint8Array> {
  if (Number(request.headers.get('content-length') ?? 0) > 2_000_128) throw new HTTPError(413);
  if (!request.body) throw new HTTPError(400);
  const reader = request.body.getReader(); let size = 0; const chunks: Uint8Array[] = [];
  while (true) { const part = await reader.read(); if (part.done) break; size += part.value.byteLength;
    if (size > 2_000_128) { await reader.cancel(); throw new HTTPError(413); } chunks.push(part.value); }
  if (!size) throw new HTTPError(400);
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}
function deviceInput(value: any): Device {
  if (!value || !UUID.test(value.deviceID) || typeof value.identityPublic !== 'string' || value.identityPublic.length > 256 || value.identityPublic.length < 32) throw new HTTPError(400);
  const jwk = value.authPublicJwk;
  if (!jwk || jwk.kty !== 'EC' || jwk.crv !== 'P-256' || typeof jwk.x !== 'string' || typeof jwk.y !== 'string' || jwk.d || jwk.x.length !== 43 || jwk.y.length !== 43) throw new HTTPError(400);
  return { deviceID: value.deviceID, identityPublic: value.identityPublic, authPublicJwk: { kty: 'EC', crv: 'P-256', x: jwk.x, y: jwk.y, ext: true }, confirmed: false };
}

export class PairObject extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS mailbox (id TEXT PRIMARY KEY, sender TEXT NOT NULL, recipient TEXT NOT NULL, digest TEXT NOT NULL, envelope TEXT NOT NULL, expires INTEGER NOT NULL, seq INTEGER NOT NULL UNIQUE)');
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS challenges (nonce TEXT PRIMARY KEY, device TEXT NOT NULL, expires INTEGER NOT NULL)');
  }
  private async pair(): Promise<Pair> { const p = await this.ctx.storage.get<Pair>('pair'); if (!p) throw new HTTPError(403); return p; }
  private async authenticate(request: Request, bodyDigest: string, pair: Pair): Promise<Device> {
    const deviceID = request.headers.get('x-device-id') ?? '', nonce = request.headers.get('x-challenge') ?? '', signature = request.headers.get('x-signature') ?? '';
    if (nonce.length > 64 || signature.length > 128) throw new HTTPError(401);
    const device = pair.devices.find(d => d.deviceID === deviceID);
    const rows = this.ctx.storage.sql.exec<{ device: string; expires: number }>('SELECT device,expires FROM challenges WHERE nonce=?', nonce).toArray();
    if (!device || rows.length !== 1 || rows[0].device !== deviceID || rows[0].expires <= Date.now()) throw new HTTPError(401);
    const url = new URL(request.url);
    const canonical = JSON.stringify(['couple-api-v1', nonce, request.method, url.pathname + url.search, bodyDigest, pair.epoch, deviceID]);
    const key = await crypto.subtle.importKey('jwk', device.authPublicJwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
    let valid = false;
    try { valid = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, unb64(signature), new TextEncoder().encode(canonical)); } catch {}
    if (!valid) throw new HTTPError(401);
    // Crypto awaits may interleave: consume only if it still exists, in one synchronous SQL operation.
    const consumed = this.ctx.storage.sql.exec('DELETE FROM challenges WHERE nonce=? AND expires>? RETURNING nonce', nonce, Date.now()).toArray();
    if (consumed.length !== 1) throw new HTTPError(401);
    return device;
  }
  async fetch(request: Request): Promise<Response> {
    return this.ctx.blockConcurrencyWhile(async () => {
      try { return await this.route(request); }
      catch (error) { return json({ error: error instanceof HTTPError ? 'request_rejected' : 'invalid_request' }, error instanceof HTTPError ? error.status : 400); }
    });
  }
  private async route(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    const mediaMatch = path.match(/^\/v1\/media\/([0-9a-f-]{36})$/i);
    if (mediaMatch && UUID.test(mediaMatch[1])) return this.media(request, mediaMatch[1]);
    const body = await readBody(request);
    const input = body ? JSON.parse(body) : {};
    if (path === '/v1/bootstrap' && request.method === 'POST') {
      if (!this.env.BOOTSTRAP_TOKEN || await digest(request.headers.get('authorization') ?? '') !== await digest('Bearer ' + this.env.BOOTSTRAP_TOKEN)) throw new HTTPError(401);
      if (!UUID.test(input.pairID)) throw new HTTPError(400);
      const device = deviceInput(input.device);
      await crypto.subtle.importKey('jwk', device.authPublicJwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
      await this.ctx.storage.transaction(async txn => {
        if (await txn.get('pair')) throw new HTTPError(409);
        await txn.put('pair', { pairID: input.pairID, epoch: 1, devices: [device], active: false } satisfies Pair);
      });
      return json({ pairID: input.pairID, epoch: 1 }, 201);
    }
    if (path === '/v1/pair/join' && request.method === 'POST') {
      const hash = await digest(String(input.invitation ?? ''));
      const device = deviceInput(input.device);
      await crypto.subtle.importKey('jwk', device.authPublicJwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
      const result = await this.ctx.storage.transaction(async txn => {
        const invitation = await txn.get<{ hash: string; expires: number }>('invitation');
        const pair = await txn.get<Pair>('pair');
        if (!pair || !invitation || invitation.hash !== hash || invitation.expires <= Date.now() || pair.active) throw new HTTPError(403);
        if (pair.devices.length === 2) {
          if (JSON.stringify(pair.devices[1]) !== JSON.stringify(device)) throw new HTTPError(409);
        } else {
          if (pair.devices[0].deviceID === device.deviceID) throw new HTTPError(409);
          pair.devices.push(device); await txn.put('pair', pair);
        }
        return { pairID: pair.pairID, epoch: pair.epoch, peer: pair.devices[0] };
      });
      return json(result, 201);
    }
    const pair = await this.pair();
    if (path === '/v1/auth/challenges' && request.method === 'POST') {
      this.ctx.storage.sql.exec('DELETE FROM challenges WHERE expires<=?', Date.now());
      if (!pair.devices.some(d => d.deviceID === input.deviceID)) throw new HTTPError(401);
      if (this.ctx.storage.sql.exec<{ n: number }>('SELECT count(*) AS n FROM challenges').one().n >= 128) throw new HTTPError(429);
      const nonce = randomToken(), expires = Date.now() + 60_000;
      this.ctx.storage.sql.exec('INSERT INTO challenges VALUES(?,?,?)', nonce, input.deviceID, expires);
      await this.schedule(); return json({ nonce, expires, epoch: pair.epoch });
    }
    const device = await this.authenticate(request, await digest(body), pair);
    if (path === '/v1/pair/status' && request.method === 'GET') {
      return json({ pairID: pair.pairID, epoch: pair.epoch, active: pair.active,
        devices: pair.devices.map(({ deviceID, identityPublic, authPublicJwk }) => ({ deviceID, identityPublic, authPublicJwk })) });
    }
    if (path === '/v1/pair/invitations' && request.method === 'POST') {
      if (pair.active || pair.devices.length !== 1 || device.deviceID !== pair.devices[0].deviceID) throw new HTTPError(409);
      const token = randomToken(), expires = Date.now() + 600_000;
      await this.ctx.storage.put('invitation', { hash: await digest(token), expires }); await this.schedule(); return json({ invitation: token, expires });
    }
    if (path === '/v1/pair/confirm' && request.method === 'POST') {
      const updated = await this.ctx.storage.transaction(async txn => {
        const current = (await txn.get<Pair>('pair'))!;
        if (current.devices.length !== 2 || current.epoch !== pair.epoch) throw new HTTPError(409);
        current.devices.find(d => d.deviceID === device.deviceID)!.confirmed = true;
        current.active = current.devices.every(d => d.confirmed); await txn.put('pair', current);
        if (current.active) await txn.delete('invitation');
        return current.active;
      });
      return json({ active: updated });
    }
    if (path === '/v1/pair/revoke' && request.method === 'POST') {
      await this.ctx.storage.transaction(async txn => {
        const current = (await txn.get<Pair>('pair'))!; current.active = false; current.epoch += 1;
        current.devices.forEach(d => { d.confirmed = false; delete d.pushToken; });
        await txn.put('pair', current); await txn.delete('invitation');
      });
      this.ctx.storage.sql.exec('DELETE FROM mailbox'); this.ctx.storage.sql.exec('DELETE FROM challenges');
      for (const socket of this.ctx.getWebSockets()) socket.close(1008, 'pair revoked');
      await this.deleteMediaPrefix(pair.pairID);
      await this.ctx.storage.delete('pushJobs'); return json({ revoked: true });
    }
    if (!pair.active) throw new HTTPError(403);
    if (path === '/v1/media/socket' && request.method === 'GET') {
      if (request.headers.get('upgrade')?.toLowerCase() !== 'websocket') throw new HTTPError(426);
      const sockets = new WebSocketPair();
      for (const old of this.ctx.getWebSockets()) {
        if (old.deserializeAttachment()?.deviceID === device.deviceID) old.close(1000, 'reconnected');
      }
      this.ctx.acceptWebSocket(sockets[1]);
      sockets[1].serializeAttachment({ deviceID: device.deviceID, epoch: pair.epoch });
      return new Response(null, { status: 101, webSocket: sockets[0] });
    }
    if (path === '/v1/device/push-token' && request.method === 'PUT') {
      if (typeof input.token !== 'string' || !/^[a-f0-9]{64,256}$/i.test(input.token) || !['sandbox','production'].includes(input.environment)) throw new HTTPError(400);
      if (typeof input.alertsEnabled !== 'boolean') throw new HTTPError(400);
      if (input.messageAlertsEnabled !== undefined && typeof input.messageAlertsEnabled !== 'boolean') throw new HTTPError(400);
      if (input.wishAlertsEnabled !== undefined && typeof input.wishAlertsEnabled !== 'boolean') throw new HTTPError(400);
      await this.ctx.storage.transaction(async txn => { const current = (await txn.get<Pair>('pair'))!;
        const d = current.devices.find(x => x.deviceID === device.deviceID)!; d.pushToken = input.token; d.environment = input.environment; d.alertsEnabled = input.alertsEnabled;
        d.messageAlertsEnabled = input.messageAlertsEnabled === true; d.wishAlertsEnabled = input.wishAlertsEnabled === true; await txn.put('pair', current); });
      console.info('push_registration', { environment: input.environment, affection: input.alertsEnabled, message: input.messageAlertsEnabled === true, wish: input.wishAlertsEnabled === true });
      return json({ updated: true });
    }
    if (path === '/v1/device/push-token' && request.method === 'DELETE') {
      const current = await this.pair(); const d = current.devices.find(x => x.deviceID === device.deviceID)!;
      delete d.pushToken; d.alertsEnabled = false; d.messageAlertsEnabled = false; d.wishAlertsEnabled = false; await this.ctx.storage.put('pair', current);
      return json({ removed: true });
    }
    if (path.startsWith('/v1/mailbox/') && path !== '/v1/mailbox/ack' && request.method === 'PUT') {
      const envelope = input as Envelope;
      if (![1, 2].includes(envelope.wireVersion)) throw new HTTPError(426);
      const transient = envelope.wireVersion === 2;
      if (envelope.alertKind !== undefined && (transient || !['message','wish'].includes(envelope.alertKind))) throw new HTTPError(400);
      if (transient && (typeof envelope.pushExpiresAt !== 'number' || !Number.isFinite(envelope.pushExpiresAt) || envelope.pushExpiresAt * 1000 <= Date.now() || envelope.pushExpiresAt * 1000 > Date.now() + 960_000)) throw new HTTPError(400);
      if (!UUID.test(envelope.id) || path !== '/v1/mailbox/' + envelope.id || envelope.pairID !== pair.pairID || envelope.epoch !== pair.epoch || envelope.sender !== device.deviceID || envelope.recipient === device.deviceID || !pair.devices.some(d => d.deviceID === envelope.recipient)) throw new HTTPError(403);
      if (typeof envelope.ciphertext !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(envelope.ciphertext) || envelope.ciphertext.length > 87_384 || unb64(envelope.ciphertext).byteLength > 65_536) throw new HTTPError(413);
      // Whitelist fields: reject side-channel plaintext fields even if a buggy client supplies them.
      if (Object.keys(envelope).sort().join(',') !== ['wireVersion','pairID','epoch','sender','recipient','id','ciphertext', ...(transient ? ['pushExpiresAt'] : []), ...(envelope.alertKind ? ['alertKind'] : [])].sort().join(',')) throw new HTTPError(400);
      const content = JSON.stringify(envelope), hash = await digest(content), now = Date.now();
      this.ctx.storage.sql.exec('DELETE FROM mailbox WHERE expires<=?', now);
      const old = this.ctx.storage.sql.exec<{ digest: string }>('SELECT digest FROM mailbox WHERE id=?', envelope.id).toArray();
      if (old.length) { if (old[0].digest !== hash) throw new HTTPError(409); return json({ accepted: true }); }
      const usage = this.ctx.storage.sql.exec<{ n: number; bytes: number }>('SELECT count(*) n, coalesce(sum(length(envelope)),0) bytes FROM mailbox WHERE recipient=?', envelope.recipient).one();
      if (usage.n >= 1000 || usage.bytes + content.length > 10 * 1024 * 1024) throw new HTTPError(429);
      await this.ctx.storage.transaction(async txn => {
        const seq = ((await txn.get<number>('sequence')) ?? 0) + 1;
        const expires = transient ? Math.min(now + TTL, envelope.pushExpiresAt! * 1000) : now + TTL;
        this.ctx.storage.sql.exec('INSERT INTO mailbox VALUES(?,?,?,?,?,?,?)', envelope.id, envelope.sender, envelope.recipient, hash, content, expires, seq);
        await txn.put('sequence', seq);
        const jobs = (await txn.get<Record<string, PushJob>>('pushJobs')) ?? {};
        const recipient = pair.devices.find(d => d.deviceID === envelope.recipient)!;
        if (transient && recipient.alertsEnabled) {
          const last = (await txn.get<Record<string, number>>('lastAlert')) ?? {};
          const key = `${envelope.recipient}:affection`;
          jobs[key] = { next: Math.max(now, (last[key] ?? 0) + 10000), attempts: 0, expires, envelopeID: envelope.id, alertKind: 'affection' };
        } else if (!transient && ((envelope.alertKind === 'message' && recipient.messageAlertsEnabled) || (envelope.alertKind === 'wish' && recipient.wishAlertsEnabled))) {
          const last = (await txn.get<Record<string, number>>('lastAlert')) ?? {};
          const key = `${envelope.recipient}:${envelope.alertKind}`;
          jobs[key] = { next: Math.max(now, (last[key] ?? 0) + 10000), attempts: 0, expires, envelopeID: envelope.id, alertKind: envelope.alertKind };
        } else { jobs[envelope.recipient] ??= { next: now, attempts: 0, expires }; }
        await txn.put('pushJobs', jobs);
      });
      await this.schedule(); return json({ accepted: true }, 201);
    }
    if (path === '/v1/mailbox' && request.method === 'GET') {
      const url = new URL(request.url), cursor = Number(url.searchParams.get('cursor') ?? 0), limit = Number(url.searchParams.get('limit') ?? 50);
      if (!Number.isSafeInteger(cursor) || cursor < 0 || !Number.isInteger(limit) || limit < 1 || limit > 50) throw new HTTPError(400);
      const rows = this.ctx.storage.sql.exec<{ envelope: string; seq: number }>('SELECT envelope,seq FROM mailbox WHERE recipient=? AND expires>? AND seq>? ORDER BY seq LIMIT ?', device.deviceID, Date.now(), cursor, limit).toArray();
      const selected: typeof rows = []; let bytes = 0;
      for (const row of rows) { if (bytes + row.envelope.length > 512 * 1024) break; selected.push(row); bytes += row.envelope.length; }
      return json({ envelopes: selected.map(r => JSON.parse(r.envelope)), cursor: selected.at(-1)?.seq ?? cursor, hasMore: selected.length < rows.length || rows.length === limit });
    }
    if (path === '/v1/mailbox/ack' && request.method === 'POST') {
      if (!Array.isArray(input.ids) || input.ids.length > 100 || !input.ids.every((id: unknown) => typeof id === 'string' && UUID.test(id))) throw new HTTPError(400);
      for (const id of input.ids) { const row = this.ctx.storage.sql.exec<{ recipient: string }>('SELECT recipient FROM mailbox WHERE id=?', id).toArray()[0]; if (row && row.recipient !== device.deviceID) throw new HTTPError(403); }
      this.ctx.storage.transactionSync(() => { for (const id of input.ids) this.ctx.storage.sql.exec('DELETE FROM mailbox WHERE id=? AND recipient=?', id, device.deviceID); });
      return json({ removed: true });
    }
    throw new HTTPError(404);
  }
  private mediaKey(pair: Pair, id: string) { return `${pair.pairID}/${pair.epoch}/${id}`; }
  private async media(request: Request, id: string): Promise<Response> {
    const pair = await this.pair();
    if (!pair.active) throw new HTTPError(403);
    const bytes = request.method === 'PUT' ? await readMediaBody(request) : new Uint8Array();
    const device = await this.authenticate(request, await digestBytes(bytes), pair);
    const key = this.mediaKey(pair, id);
    if (request.method === 'PUT') {
      if (request.headers.get('content-type') !== 'application/octet-stream') throw new HTTPError(415);
      const checksum = await digestBytes(bytes);
      const old = await this.env.MEDIA.head(key);
      if (old) {
        if (old.customMetadata?.uploader !== device.deviceID || old.customMetadata?.checksum !== checksum) throw new HTTPError(409);
        return json({ accepted: true, byteCount: old.size });
      }
      const recipient = pair.devices.find(d => d.deviceID !== device.deviceID)!;
      await this.env.MEDIA.put(key, bytes, { httpMetadata: { contentType: 'application/octet-stream' },
        customMetadata: { uploader: device.deviceID, recipient: recipient.deviceID, checksum, createdAt: String(Date.now()) } });
      return json({ accepted: true, byteCount: bytes.byteLength }, 201);
    }
    const object = await this.env.MEDIA.get(key);
    if (!object) throw new HTTPError(404);
    if (![object.customMetadata?.uploader, object.customMetadata?.recipient].includes(device.deviceID)) throw new HTTPError(403);
    if (request.method === 'GET') return new Response(object.body, { headers: { 'Content-Type': 'application/octet-stream', 'Cache-Control': 'no-store' } });
    if (request.method === 'DELETE') { await this.env.MEDIA.delete(key); return json({ removed: true }); }
    throw new HTTPError(405);
  }
  private async deleteMediaPrefix(pairID: string) {
    let cursor: string | undefined;
    do {
      const page = await this.env.MEDIA.list({ prefix: `${pairID}/`, cursor, limit: 1000 });
      if (page.objects.length) await this.env.MEDIA.delete(page.objects.map(o => o.key));
      cursor = page.truncated ? page.cursor : undefined;
    } while (cursor);
  }
  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer) {
    const source = socket.deserializeAttachment() as { deviceID?: string; epoch?: number } | null;
    const pair = await this.ctx.storage.get<Pair>('pair');
    if (!source?.deviceID || !pair?.active || source.epoch !== pair.epoch) {
      socket.close(1008, 'pair inactive'); return;
    }
    if (typeof message === 'string') {
      if (message.length > 128 || !/^need:[0-9a-f-]{36}$/i.test(message) || !UUID.test(message.slice(5))) {
        socket.close(1008, 'invalid request'); return;
      }
    } else {
      if (message.byteLength > 2_001_000 || message.byteLength < 44 ||
          !/^photo:[0-9a-f-]{36}:$/i.test(new TextDecoder().decode(message.slice(0, 43)))) {
        socket.close(1009, 'invalid photo'); return;
      }
    }
    const peer = this.ctx.getWebSockets().find(other => other !== socket &&
      other.deserializeAttachment()?.deviceID !== source.deviceID &&
      other.deserializeAttachment()?.epoch === pair.epoch);
    if (peer) {
      try { peer.send(message); } catch { peer.close(1011, 'delivery failed'); }
    }
  }
  private async schedule() {
    const now = Date.now(); const times = [now + 60_000];
    const expiry = this.ctx.storage.sql.exec<{ t: number | null }>('SELECT min(expires) t FROM mailbox').one().t;
    if (expiry) times.push(expiry);
    const jobs = await this.ctx.storage.get<Record<string, { next: number }>>('pushJobs');
    if (jobs) times.push(...Object.values(jobs).map(j => j.next));
    await this.ctx.storage.setAlarm(Math.max(now + 1000, Math.min(...times)));
  }
  async alarm() { await this.ctx.blockConcurrencyWhile(() => this.cleanup()); }
  private async cleanup() {
    const now = Date.now(); this.ctx.storage.sql.exec('DELETE FROM mailbox WHERE expires<=?', now); this.ctx.storage.sql.exec('DELETE FROM challenges WHERE expires<=?', now);
    const invitation = await this.ctx.storage.get<{ expires: number }>('invitation'); if (invitation && invitation.expires <= now) await this.ctx.storage.delete('invitation');
    const pair = await this.ctx.storage.get<Pair>('pair');
    const jobs = await this.ctx.storage.get<Record<string, PushJob>>('pushJobs') ?? {};
    for (const [key, job] of Object.entries(jobs)) {
      const id = key.split(':')[0];
      const count = this.ctx.storage.sql.exec<{ n: number }>('SELECT count(*) n FROM mailbox WHERE recipient=?', id).one().n;
      if (!count || job.expires <= now || job.attempts >= 5) { delete jobs[key]; continue; }
      if (job.next > now) continue;
      const device = pair?.devices.find(d => d.deviceID === id);
      if (job.envelopeID && !this.ctx.storage.sql.exec('SELECT id FROM mailbox WHERE id=? AND recipient=?', job.envelopeID, id).toArray().length) { delete jobs[key]; continue; }
      const result = device ? await sendPush(this.env, device, job) : { outcome: 'permanent' as const };
      console.info('push_delivery', { kind: job.alertKind ?? 'background', outcome: result.outcome, registered: !!device?.pushToken });
      if (result.outcome === 'invalidToken' && device && pair) {
        delete device.pushToken; await this.ctx.storage.put('pair', pair);
      }
      if (result.outcome === 'sent' && job.envelopeID) {
        const last = await this.ctx.storage.get<Record<string, number>>('lastAlert') ?? {};
        last[key] = now; await this.ctx.storage.put('lastAlert', last);
      }
      if (result.outcome !== 'retry') delete jobs[key];
      else { job.attempts++; job.next = now + Math.max(result.retryAfter ?? 0, Math.min(300_000, 10_000 * 2 ** job.attempts)); }
    }
    await this.ctx.storage.put('pushJobs', jobs);
    const count = this.ctx.storage.sql.exec<{ n: number }>('SELECT count(*) n FROM mailbox').one().n + this.ctx.storage.sql.exec<{ n: number }>('SELECT count(*) n FROM challenges').one().n;
    if (count || Object.keys(jobs).length || await this.ctx.storage.get('invitation')) await this.schedule();
    else await this.ctx.storage.deleteAlarm();
  }
}
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (new URL(request.url).pathname === '/health') return json({ status: 'ok' });
    return env.PAIR.get(env.PAIR.idFromName('only-pair')).fetch(request);
  }
} satisfies ExportedHandler<Env>;
