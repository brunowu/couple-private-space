import { env } from 'cloudflare:workers';
import { SELF, runInDurableObject } from 'cloudflare:test';
import { describe, it, expect, beforeAll } from 'vitest';
import type { Env } from '../src/worker';

const encoder = new TextEncoder();
const base = 'https://local.test';
const b64 = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b)));
const hash = async (s: string) => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(s))), b => b.toString(16).padStart(2,'0')).join('');
const hashBytes = async (bytes: Uint8Array) => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), b => b.toString(16).padStart(2,'0')).join('');
type Client = { deviceID: string; identityPublic: string; authPublicJwk: JsonWebKey; privateKey: CryptoKey };
async function client(): Promise<Client> {
 const key = await crypto.subtle.generateKey({ name:'ECDSA', namedCurve:'P-256' },true,['sign','verify']);
 return {deviceID:crypto.randomUUID(),identityPublic:b64(crypto.getRandomValues(new Uint8Array(33)).buffer), authPublicJwk:await crypto.subtle.exportKey('jwk',key.publicKey),privateKey:key.privateKey};
}
const pub = (c: Client) => ({deviceID:c.deviceID,identityPublic:c.identityPublic,authPublicJwk:c.authPublicJwk});
const request = (path: string, init?: RequestInit) => SELF.fetch(base+path,init);
async function dispatch(request: Request<any, any>) {
 return SELF.fetch(request.url, { method: request.method, headers: request.headers,
  body: request.method === 'GET' ? undefined : await request.text() });
}
async function signed(c: Client, path: string, method: string, value?: unknown) {
 const body = value === undefined ? '' : JSON.stringify(value);
 const response = await request('/v1/auth/challenges',{method:'POST',body:JSON.stringify({deviceID:c.deviceID})});
 expect(response.status).toBe(200);
 const challenge = await response.json() as {nonce:string;epoch:number};
 const canonical = JSON.stringify(['couple-api-v1',challenge.nonce,method,path,await hash(body),challenge.epoch,c.deviceID]);
 const signature = b64(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},c.privateKey,encoder.encode(canonical)));
 return new Request(base+path,{method,headers:{'x-device-id':c.deviceID,'x-challenge':challenge.nonce,'x-signature':signature},body:method==='GET'?undefined:body});
}
const send = async (c: Client,path:string,method:string,value?:unknown) => dispatch(await signed(c,path,method,value));
async function sendMedia(c: Client, id: string, method: 'PUT'|'GET'|'DELETE', bytes = new Uint8Array()) {
 const path='/v1/media/'+id;
 const response=await request('/v1/auth/challenges',{method:'POST',body:JSON.stringify({deviceID:c.deviceID})});
 const challenge=await response.json() as {nonce:string;epoch:number};
 const canonical=JSON.stringify(['couple-api-v1',challenge.nonce,method,path,await hashBytes(bytes),challenge.epoch,c.deviceID]);
 const signature=b64(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},c.privateKey,encoder.encode(canonical)));
 return SELF.fetch(base+path,{method,headers:{'x-device-id':c.deviceID,'x-challenge':challenge.nonce,'x-signature':signature,
  ...(method==='PUT'?{'content-type':'application/octet-stream'}:{})},body:method==='PUT'?bytes:undefined});
}
let a:Client,b:Client,pairID:string;
const envelope = () => ({wireVersion:1,pairID,epoch:1,sender:a.deviceID,recipient:b.deviceID,id:crypto.randomUUID(),ciphertext:b64(crypto.getRandomValues(new Uint8Array(100)).buffer)});
beforeAll(async()=>{
 a=await client();b=await client();pairID=crypto.randomUUID();
 const bootstrap=await request('/v1/bootstrap',{method:'POST',headers:{authorization:'Bearer test-bootstrap-only-not-a-deployment-secret'},body:JSON.stringify({pairID,device:pub(a)})});
 expect(bootstrap.status).toBe(201);
 const invite=await (await send(a,'/v1/pair/invitations','POST',{})).json() as {invitation:string};
 const join=await request('/v1/pair/join',{method:'POST',body:JSON.stringify({invitation:invite.invitation,device:pub(b)})});expect(join.status).toBe(201);
 expect((await send(a,'/v1/pair/confirm','POST',{})).status).toBe(200);
 expect((await send(b,'/v1/pair/confirm','POST',{})).status).toBe(200);
});
describe('authenticated temporary mailbox',()=>{
 it('stores short lived generic alert jobs only after receiver opts in, and removes token on disable',async()=>{
  expect((await send(b,'/v1/device/push-token','PUT',{token:'b'.repeat(64),environment:'sandbox',alertsEnabled:true})).status).toBe(200);
  const e={...envelope(),wireVersion:2,pushExpiresAt:(Date.now()+800_000)/1000};
  expect((await send(a,'/v1/mailbox/'+e.id,'PUT',e)).status).toBe(201);
  const bindings=env as unknown as Env; const stub=bindings.PAIR.get(bindings.PAIR.idFromName('only-pair'));
  await runInDurableObject(stub,async(_instance:DurableObject,state:DurableObjectState)=>{
   const row=state.storage.sql.exec<{expires:number}>('SELECT expires FROM mailbox WHERE id=?',e.id).one();
   expect(row.expires).toBe(e.pushExpiresAt*1000);
   const jobs=await state.storage.get<Record<string,{envelopeID?:string;expires:number}>>('pushJobs');
   expect(jobs?.[b.deviceID+':affection'].envelopeID).toBe(e.id); expect(jobs?.[b.deviceID+':affection'].expires).toBe(row.expires);
  });
  expect((await send(a,'/v1/mailbox/'+e.id,'PUT',{...e,pushExpiresAt:(Date.now()+3600_000)/1000})).status).toBe(400);
  expect((await send(a,'/v1/mailbox/'+e.id,'PUT',{...e,kind:'hug'})).status).toBe(400);
  expect((await send(b,'/v1/device/push-token','DELETE')).status).toBe(200);
  await runInDurableObject(stub,async(_instance:DurableObject,state:DurableObjectState)=>{
   const pair=await state.storage.get<{devices:{deviceID:string;pushToken?:string;alertsEnabled?:boolean}[]}>('pair');
   const recipient=pair?.devices.find(d=>d.deviceID===b.deviceID);
   expect(recipient?.pushToken).toBeUndefined(); expect(recipient?.alertsEnabled).toBe(false);
  });
 });
 it('routes only opted-in coarse categories and rejects plaintext or invalid categories',async()=>{
  expect((await send(b,'/v1/device/push-token','PUT',{token:'b'.repeat(64),environment:'sandbox',alertsEnabled:true,messageAlertsEnabled:true,wishAlertsEnabled:false})).status).toBe(200);
  const message={...envelope(),alertKind:'message'};
  expect((await send(a,'/v1/mailbox/'+message.id,'PUT',message)).status).toBe(201);
  const affection={...envelope(),wireVersion:2,pushExpiresAt:(Date.now()+800_000)/1000};
  expect((await send(a,'/v1/mailbox/'+affection.id,'PUT',affection)).status).toBe(201);
  const bindings=env as unknown as Env; const stub=bindings.PAIR.get(bindings.PAIR.idFromName('only-pair'));
  await runInDurableObject(stub,async(_instance:DurableObject,state:DurableObjectState)=>{
   const jobs=await state.storage.get<Record<string,{alertKind?:string;envelopeID?:string}>>('pushJobs');
   expect(jobs?.[b.deviceID+':message'].alertKind).toBe('message'); expect(jobs?.[b.deviceID+':message'].envelopeID).toBe(message.id);
   expect(jobs?.[b.deviceID+':affection'].envelopeID).toBe(affection.id);
  });
  const invalid={...envelope(),alertKind:'hug'};
  expect((await send(a,'/v1/mailbox/'+invalid.id,'PUT',invalid)).status).toBe(400);
  const plaintext={...envelope(),alertKind:'wish',text:'private'};
  expect((await send(a,'/v1/mailbox/'+plaintext.id,'PUT',plaintext)).status).toBe(400);
  expect((await send(b,'/v1/device/push-token','DELETE')).status).toBe(200);
 });
 it('returns only public pairing material to authenticated members',async()=>{
  expect((await request('/v1/pair/status')).status).toBe(401);
  const status=await (await send(a,'/v1/pair/status','GET')).json() as {pairID:string;devices:Record<string,unknown>[]};
  expect(status.pairID).toBe(pairID); expect(status.devices.length).toBe(2);
  expect(status.devices.every(d=>Object.keys(d).sort().join(',')==='authPublicJwk,deviceID,identityPublic')).toBe(true);
 });
 it('requires device authentication',async()=>{expect((await request('/v1/mailbox')).status).toBe(401);});
 it('cannot bootstrap a second pair',async()=>{expect((await request('/v1/bootstrap',{method:'POST',headers:{authorization:'Bearer test-bootstrap-only-not-a-deployment-secret'},body:JSON.stringify({pairID:crypto.randomUUID(),device:pub(a)})})).status).toBe(409);});
 it('accepts same ciphertext idempotently, rejects different bytes',async()=>{
  const e=envelope();expect((await send(a,'/v1/mailbox/'+e.id,'PUT',e)).status).toBe(201);
  expect((await send(a,'/v1/mailbox/'+e.id,'PUT',e)).status).toBe(200);
  expect((await send(a,'/v1/mailbox/'+e.id,'PUT',{...e,ciphertext:b64(new Uint8Array([3]).buffer)})).status).toBe(409);
 });
 it('stores only authenticated ciphertext media until the recipient downloads it',async()=>{
  const id=crypto.randomUUID(), bytes=crypto.getRandomValues(new Uint8Array(1024));
  expect((await sendMedia(a,id,'PUT',bytes)).status).toBe(201);
  expect((await sendMedia(a,id,'PUT',bytes)).status).toBe(200);
  expect((await sendMedia(a,id,'PUT',new Uint8Array([1]))).status).toBe(409);
  const downloaded=await sendMedia(b,id,'GET');
  expect(downloaded.status).toBe(200);
  expect(new Uint8Array(await downloaded.arrayBuffer())).toEqual(bytes);
  expect((await sendMedia(b,id,'DELETE')).status).toBe(200);
  expect((await sendMedia(b,id,'GET')).status).toBe(404);
 });
 it('fetch does not delete; only recipient can acknowledge',async()=>{
  const e=envelope();await send(a,'/v1/mailbox/'+e.id,'PUT',e);
  const fetched=await (await send(b,'/v1/mailbox','GET')).json() as {envelopes:{id:string}[]};expect(fetched.envelopes.some(x=>x.id===e.id)).toBe(true);
  expect((await send(a,'/v1/mailbox/ack','POST',{ids:[e.id]})).status).toBe(403);
  expect((await send(b,'/v1/mailbox/ack','POST',{ids:[e.id]})).status).toBe(200);
  expect((await send(b,'/v1/mailbox/ack','POST',{ids:[e.id]})).status).toBe(200);
 });
 it('rejects signature replay',async()=>{const req=await signed(a,'/v1/mailbox','GET');expect((await dispatch(req.clone())).status).toBe(200);expect((await dispatch(req)).status).toBe(401);});
 it('rejects third recipient and plaintext side fields',async()=>{
  const e=envelope();expect((await send(a,'/v1/mailbox/'+e.id,'PUT',{...e,recipient:crypto.randomUUID()})).status).toBe(403);
  expect((await send(a,'/v1/mailbox/'+e.id,'PUT',{...e,text:'sensitive plaintext'})).status).toBe(400);
 });
 it('filters expired messages even before alarm cleanup',async()=>{
  const e=envelope();await send(a,'/v1/mailbox/'+e.id,'PUT',e);
  const bindings=env as unknown as Env; const stub=bindings.PAIR.get(bindings.PAIR.idFromName('only-pair'));
  await runInDurableObject(stub,async(_instance: DurableObject,state: DurableObjectState)=>{state.storage.sql.exec('UPDATE mailbox SET expires=? WHERE id=?',Date.now()-1,e.id);});
  const fetched=await (await send(b,'/v1/mailbox','GET')).json() as {envelopes:{id:string}[]};expect(fetched.envelopes.some(x=>x.id===e.id)).toBe(false);
 });
 it('rejects oversized bodies before parsing them',async()=>{expect((await request('/v1/bootstrap',{method:'POST',body:'x'.repeat(100_000)})).status).toBe(413);});
});
