export interface APNSConfig {
  APNS_TEAM_ID?: string; APNS_KEY_ID?: string; APNS_PRIVATE_KEY?: string; APNS_TOPIC?: string;
}
export type PushDevice = { pushToken?: string; environment?: 'sandbox' | 'production'; alertsEnabled?: boolean; messageAlertsEnabled?: boolean; wishAlertsEnabled?: boolean };
export type PushJob = { next: number; attempts: number; expires: number; envelopeID?: string; alertKind?: 'affection' | 'message' | 'wish' };
export type PushResult = { outcome: 'sent' | 'unconfigured' | 'invalidToken' | 'permanent' | 'retry'; retryAfter?: number };
let cachedToken: { team: string; keyID: string; privateKey: string; issuedAt: number; jwt: string } | undefined;
const url64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
export function pushRequest(config: APNSConfig, device: PushDevice, job: PushJob, jwt: string): Request {
  const kind = job.alertKind ?? (job.envelopeID ? 'affection' : undefined);
  const alert = !!kind;
  const host = device.environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
  return new Request(`https://${host}/3/device/${device.pushToken}`, {
    method: 'POST', headers: {
      authorization: `bearer ${jwt}`, 'apns-topic': config.APNS_TOPIC!,
      'apns-push-type': alert ? 'alert' : 'background', 'apns-priority': alert ? '10' : '5',
      'apns-expiration': String(Math.floor(job.expires / 1000)),
      'apns-collapse-id': alert ? `private-${kind}` : 'private-mailbox'
    }, body: JSON.stringify(alert ? {
      aps: { alert: { title: '我们', body: kind === 'message' ? '你有一条新消息' : kind === 'wish' ? '你有一个新愿望' : '你收到了一份小心意' }, sound: 'default', 'content-available': 1, ...(kind === 'affection' ? { category: 'PRIVATE_AFFECTION' } : {}) },
      ...(kind === 'affection' ? { affection_envelope: job.envelopeID } : { destination: kind })
    } : { aps: { 'content-available': 1 } }), signal: AbortSignal.timeout(5000)
  });
}
export async function classifyPushResponse(response: Response, now = Date.now()): Promise<PushResult> {
  if (response.ok) return { outcome: 'sent' };
  const body = await response.json().catch(() => ({})) as { reason?: string };
  if (response.status === 410 || (response.status === 400 && ['BadDeviceToken', 'DeviceTokenNotForTopic'].includes(body.reason ?? ''))) return { outcome: 'invalidToken' };
  if (response.status === 429 || response.status >= 500 || body.reason === 'ExpiredProviderToken') {
    const header = response.headers.get('retry-after');
    const delay = header ? (/^\d+$/.test(header) ? Number(header) * 1000 : Date.parse(header) - now) : 0;
    return { outcome: 'retry', retryAfter: Number.isFinite(delay) ? Math.max(0, Math.min(delay, 3600_000)) : 0 };
  }
  return { outcome: 'permanent' };
}
export async function sendPush(config: APNSConfig, device: PushDevice, job: PushJob): Promise<PushResult> {
  if (!device.pushToken || !config.APNS_TEAM_ID || !config.APNS_KEY_ID || !config.APNS_PRIVATE_KEY || !config.APNS_TOPIC) return { outcome: 'unconfigured' };
  if (job.expires <= Date.now() ||
      (job.alertKind === 'message' && !device.messageAlertsEnabled) ||
      (job.alertKind === 'wish' && !device.wishAlertsEnabled) ||
      ((job.alertKind === 'affection' || (job.envelopeID && !job.alertKind)) && !device.alertsEnabled)) return { outcome: 'permanent' };
  try {
    const now = Math.floor(Date.now()/1000);
    if (!cachedToken || cachedToken.team !== config.APNS_TEAM_ID || cachedToken.keyID !== config.APNS_KEY_ID || cachedToken.privateKey !== config.APNS_PRIVATE_KEY || now < cachedToken.issuedAt || now - cachedToken.issuedAt >= 3000) {
      const encode = (value: unknown) => url64(new TextEncoder().encode(JSON.stringify(value)));
      const unsigned = encode({ alg: 'ES256', kid: config.APNS_KEY_ID }) + '.' + encode({ iss: config.APNS_TEAM_ID, iat: now });
      const der = Uint8Array.from(atob(config.APNS_PRIVATE_KEY.replace(/-----[^-]+-----|\s/g,'')), c => c.charCodeAt(0));
      const key = await crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
      const signature = url64(new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(unsigned))));
      cachedToken = { team: config.APNS_TEAM_ID, keyID: config.APNS_KEY_ID, privateKey: config.APNS_PRIVATE_KEY, issuedAt: now, jwt: `${unsigned}.${signature}` };
    }
    const response = await fetch(pushRequest(config, device, job, cachedToken.jwt));
    if (response.status === 403) {
      const reason = await response.clone().json().catch(() => ({})) as { reason?: string };
      if (reason.reason === 'ExpiredProviderToken') cachedToken = undefined;
    }
    return await classifyPushResponse(response);
  } catch { return { outcome: 'retry' }; }
}
