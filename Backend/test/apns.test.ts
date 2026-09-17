import { describe, it, expect, vi } from 'vitest';
import { pushRequest, classifyPushResponse, sendPush } from '../src/apns';
describe('APNs provider boundary', () => {
  it('signs a valid ES256 provider token while the Apple network request is mocked', async () => {
    const keys = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const der = await crypto.subtle.exportKey('pkcs8', keys.privateKey);
    const pem = btoa(String.fromCharCode(...new Uint8Array(der)));
    const mock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(null, { status: 200 }));
    try {
      expect((await sendPush({ APNS_TEAM_ID: 'TESTTEAM', APNS_KEY_ID: 'TESTKEY', APNS_PRIVATE_KEY: pem, APNS_TOPIC: 'test.space' },
        { pushToken: 'a'.repeat(64), environment: 'sandbox', alertsEnabled: true }, { next: 0, attempts: 0, expires: Date.now() + 10000 })).outcome).toBe('sent');
      const request = mock.mock.calls[0][0] as Request;
      const parts = request.headers.get('authorization')!.slice(7).split('.');
      const bytes = (s: string) => Uint8Array.from(atob(s.replaceAll('-', '+').replaceAll('_', '/')), c => c.charCodeAt(0));
      expect(JSON.parse(new TextDecoder().decode(bytes(parts[0])))).toEqual({ alg: 'ES256', kid: 'TESTKEY' });
      expect(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, keys.publicKey, bytes(parts[2]), new TextEncoder().encode(parts.slice(0, 2).join('.')))).toBe(true);
      await sendPush({ APNS_TEAM_ID: 'TESTTEAM', APNS_KEY_ID: 'TESTKEY', APNS_PRIVATE_KEY: pem, APNS_TOPIC: 'test.space' },
        { pushToken: 'a'.repeat(64), environment: 'sandbox', alertsEnabled: true }, { next: 0, attempts: 0, expires: Date.now() + 10000 });
      expect((mock.mock.calls[1][0] as Request).headers.get('authorization')).toBe(request.headers.get('authorization'));
    } finally { mock.mockRestore(); }
  });
  it('uses generic alert payload and bounded expiry without affection type or plaintext', async () => {
    const request = pushRequest({ APNS_TOPIC: 'test.space' }, { pushToken: 'a'.repeat(64), environment: 'sandbox' },
      { next: 0, attempts: 0, expires: 1234000, envelopeID: 'public-envelope-id' }, 'test-jwt');
    expect(new URL(request.url).hostname).toBe('api.sandbox.push.apple.com');
    expect(request.headers.get('apns-push-type')).toBe('alert');
    expect(request.headers.get('apns-expiration')).toBe('1234');
    expect(request.headers.get('apns-collapse-id')).toBe('private-affection');
    expect(await request.json()).toEqual({ aps: { alert: { title: '我们', body: '你收到了一份小心意' }, sound: 'default', 'content-available': 1, category: 'PRIVATE_AFFECTION' }, affection_envelope: 'public-envelope-id' });
  });
  it('sends category-only message and wish alerts without content or names', async () => {
    for (const [kind, body] of [['message', '你有一条新消息'], ['wish', '你有一个新愿望']] as const) {
      const request = pushRequest({ APNS_TOPIC: 'test.space' }, { pushToken: 'a'.repeat(64), environment: 'sandbox' },
        { next: 0, attempts: 0, expires: 1234000, envelopeID: 'opaque-id', alertKind: kind }, 'test');
      expect(request.headers.get('apns-collapse-id')).toBe(`private-${kind}`);
      expect(await request.json()).toEqual({ aps: { alert: { title: '我们', body }, sound: 'default', 'content-available': 1 }, destination: kind });
    }
  });
  it('keeps ordinary mailbox wakes silent', async () => {
    const request = pushRequest({ APNS_TOPIC: 'test.space' }, { pushToken: 'a'.repeat(64), environment: 'production' }, { next: 0, attempts: 0, expires: 1234000 }, 'test');
    expect(request.headers.get('apns-priority')).toBe('5');
    expect(await request.json()).toEqual({ aps: { 'content-available': 1 } });
  });
  it('distinguishes invalid tokens, provider configuration failures and retryable errors', async () => {
    expect((await classifyPushResponse(Response.json({ reason: 'Unregistered' }, { status: 410 }))).outcome).toBe('invalidToken');
    expect((await classifyPushResponse(Response.json({ reason: 'InvalidProviderToken' }, { status: 403 }))).outcome).toBe('permanent');
    expect(await classifyPushResponse(Response.json({}, { status: 429, headers: { 'retry-after': '120' } }))).toEqual({ outcome: 'retry', retryAfter: 120000 });
    expect((await classifyPushResponse(Response.json({}, { status: 503 }))).outcome).toBe('retry');
    expect((await sendPush({}, {}, { next: 0, attempts: 0, expires: Date.now() + 10000 })).outcome).toBe('unconfigured');
  });
});
