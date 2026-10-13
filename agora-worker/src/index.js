// Cloudflare Worker: يصدر Agora RTC Token بعد التحقق من تسجيل الدخول والصلاحيات.
// Secrets المطلوبة: AGORA_APP_ID ، AGORA_APP_CERTIFICATE
// Vars (في wrangler.toml): FIREBASE_PROJECT_ID

const JWKS_URL = 'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';
let jwksCache = { keys: null, at: 0 };

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*' },
  });
const fail = (status, code, message) => json({ error: { code, message } }, status);

// ---------------------------------------------------------------- Firebase ID token
const b64uToBytes = (s) => {
  s = s.replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4) s += '=';
  const bin = atob(s);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
};
const b64uToJson = (s) => JSON.parse(new TextDecoder().decode(b64uToBytes(s)));

async function getJwks() {
  if (jwksCache.keys && Date.now() - jwksCache.at < 3600_000) return jwksCache.keys;
  const r = await fetch(JWKS_URL);
  if (!r.ok) throw new Error('jwks fetch failed');
  const { keys } = await r.json();
  jwksCache = { keys, at: Date.now() };
  return keys;
}

async function verifyIdToken(idToken, projectId) {
  const parts = String(idToken || '').split('.');
  if (parts.length !== 3) throw new Error('bad token');
  const header = b64uToJson(parts[0]);
  const payload = b64uToJson(parts[1]);
  if (header.alg !== 'RS256') throw new Error('bad alg');
  const jwk = (await getJwks()).find((k) => k.kid === header.kid);
  if (!jwk) throw new Error('unknown kid');
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, b64uToBytes(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  if (!ok) throw new Error('bad signature');
  const now = Math.floor(Date.now() / 1000);
  if (payload.aud !== projectId || payload.iss !== `https://securetoken.google.com/${projectId}`) throw new Error('bad aud/iss');
  if (!payload.sub || payload.exp < now - 30 || payload.iat > now + 300) throw new Error('expired');
  return payload; // payload.sub = uid
}

// ---------------------------------------------------------------- Firestore REST (بصلاحيات المستخدم نفسه، فتطبق firestore.rules)
function decodeValue(v) {
  if (!v) return null;
  if ('stringValue' in v) return v.stringValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return v.doubleValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('timestampValue' in v) return v.timestampValue;
  if ('nullValue' in v) return null;
  if ('mapValue' in v) return decodeFields(v.mapValue.fields || {});
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(decodeValue);
  return null;
}
const decodeFields = (f) => Object.fromEntries(Object.entries(f || {}).map(([k, v]) => [k, decodeValue(v)]));

async function getDoc(env, idToken, path) {
  const url = `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents/${path}`;
  const r = await fetch(url, { headers: { Authorization: `Bearer ${idToken}` } });
  if (r.status === 404 || r.status === 403) return null; // 403 = ترفضها القواعد = لا صلاحية
  if (!r.ok) throw new Error(`firestore ${r.status}`);
  return decodeFields((await r.json()).fields);
}

// ---------------------------------------------------------------- Agora AccessToken (v006)
const crcTable = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(str) {
  let c = 0xffffffff;
  for (const b of new TextEncoder().encode(str)) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
const u16 = (n) => { const b = new Uint8Array(2); new DataView(b.buffer).setUint16(0, n, true); return b; };
const u32 = (n) => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n >>> 0, true); return b; };
const concat = (...arrs) => {
  const out = new Uint8Array(arrs.reduce((a, x) => a + x.length, 0));
  let o = 0;
  for (const x of arrs) { out.set(x, o); o += x.length; }
  return out;
};
const packBytes = (b) => concat(u16(b.length), b);

async function buildRtcToken(appId, certificate, channel, uid, expireTs) {
  const enc = new TextEncoder();
  const salt = Math.floor(Math.random() * 99999999) + 1;
  const ts = Math.floor(Date.now() / 1000) + 24 * 3600;
  const privileges = [1, 2, 3, 4]; // join + publish audio/video/data
  const message = concat(
    u32(salt), u32(ts), u16(privileges.length),
    ...privileges.map((p) => concat(u16(p), u32(expireTs))),
  );
  const uidStr = uid === 0 ? '' : String(uid);
  const toSign = concat(enc.encode(appId), enc.encode(channel), enc.encode(uidStr), message);
  const hkey = await crypto.subtle.importKey('raw', enc.encode(certificate), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signature = new Uint8Array(await crypto.subtle.sign('HMAC', hkey, toSign));
  const content = concat(packBytes(signature), u32(crc32(channel)), u32(crc32(uidStr)), packBytes(message));
  let bin = '';
  for (const b of content) bin += String.fromCharCode(b);
  return `006${appId}${btoa(bin)}`;
}

function numericUid(text) {
  let n = 0;
  for (const ch of text) n = (Math.imul(n, 31) + ch.charCodeAt(0)) >>> 0;
  return (n % 2147483646) + 1;
}

// ---------------------------------------------------------------- منطق الصلاحيات (نفس منطق Cloud Functions السابقة)
async function meetingToken(env, idToken, uid, body) {
  const requestId = String(body.requestId || '').trim();
  if (!requestId) return fail(400, 'invalid-argument', 'معرّف المحاضرة مطلوب');
  const profile = (await getDoc(env, idToken, `users/${uid}`)) || {};
  if (profile.status === 'blocked') return fail(403, 'permission-denied', 'الحساب محظور');
  const isAdmin = profile.isAdmin === true || profile.role === 'admin';
  const m = await getDoc(env, idToken, `istifhams/${requestId}`);
  if (!m) return fail(404, 'not-found', 'المحاضرة غير موجودة');
  if (!(uid === m.mustafhemId || uid === m.mufhemId || isAdmin)) return fail(403, 'permission-denied', 'لست من أطراف هذه المحاضرة');
  if (m.status !== 'paid' && !isAdmin) return fail(412, 'failed-precondition', 'المحاضرة لم يتم تفعيلها بالدفع');
  const startMs = new Date(m.meetingTime || '').getTime();
  if (Number.isFinite(startMs) && !isAdmin) {
    if (Date.now() < startMs - 5 * 60_000) return fail(412, 'failed-precondition', 'لم يحن موعد المحاضرة بعد');
    if (Date.now() > startMs + 6 * 3600_000) return fail(412, 'failed-precondition', 'انتهت مدة الدخول للمحاضرة');
  }
  const channel = `Fahimni_${requestId}`.replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 64);
  const agoraUid = numericUid(`${uid}:${requestId}`);
  const expire = Math.floor(Date.now() / 1000) + 3600;
  const token = await buildRtcToken(env.AGORA_APP_ID.trim(), env.AGORA_APP_CERTIFICATE.trim(), channel, agoraUid, expire);
  return json({ appId: env.AGORA_APP_ID.trim(), channel, uid: agoraUid, token, expiresAt: expire });
}

async function groupToken(env, idToken, uid, body) {
  const groupId = String(body.groupId || '').trim();
  const sessionId = String(body.sessionId || '').trim();
  if (!groupId || !sessionId) return fail(400, 'invalid-argument', 'بيانات الجلسة ناقصة');
  const profile = (await getDoc(env, idToken, `users/${uid}`)) || {};
  if (profile.status === 'blocked') return fail(403, 'permission-denied', 'الحساب محظور');
  const isAdmin = profile.isAdmin === true || profile.role === 'admin';
  // القواعد تسمح بقراءة المجموعة للمالك/العضو فقط (الأدمن لا تشمله القواعد).
  const g = await getDoc(env, idToken, `groups/${groupId}`);
  let isOwner = false;
  let record = false;
  if (g) {
    if (g.status !== 'active') return fail(412, 'failed-precondition', 'المجموعة متوقفة مؤقتًا');
    const s = await getDoc(env, idToken, `groups/${groupId}/sessions/${sessionId}`);
    if (!s || s.status !== 'live') return fail(412, 'failed-precondition', 'الجلسة غير متاحة الآن');
    isOwner = g.ownerUid === uid;
    record = s.record === true;
  } else if (!isAdmin) {
    return fail(403, 'permission-denied', `الجلسة لأعضاء المجموعة فقط (uid=${uid.slice(0, 6)}.. group=${groupId.slice(0, 6)}..)`);
  }
  const channel = `Group_${groupId}_${sessionId}`.replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 64);
  const agoraUid = numericUid(`${uid}:${groupId}:${sessionId}`);
  const expire = Math.floor(Date.now() / 1000) + 3 * 3600;
  const token = await buildRtcToken(env.AGORA_APP_ID.trim(), env.AGORA_APP_CERTIFICATE.trim(), channel, agoraUid, expire);
  return json({ appId: env.AGORA_APP_ID.trim(), channel, uid: agoraUid, token, expiresAt: expire, moderator: isOwner, record });
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Authorization, Content-Type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' } });
    }
    const url = new URL(request.url);
    if (request.method !== 'POST' || !['/meeting', '/group'].includes(url.pathname)) return fail(404, 'not-found', 'Not found');
    if (!env.AGORA_APP_ID || !env.AGORA_APP_CERTIFICATE) return fail(500, 'failed-precondition', 'إعدادات Agora ناقصة على الـ Worker');

    const idToken = (request.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    let uid;
    try { uid = (await verifyIdToken(idToken, env.FIREBASE_PROJECT_ID)).sub; }
    catch (_) { return fail(401, 'unauthenticated', 'لازم تسجل الدخول أولاً'); }

    let body = {};
    try { body = await request.json(); } catch (_) {}
    try {
      return url.pathname === '/meeting' ? await meetingToken(env, idToken, uid, body) : await groupToken(env, idToken, uid, body);
    } catch (e) {
      return fail(500, 'internal', 'خطأ في الخادم');
    }
  },
};
