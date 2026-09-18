// 带真实 cookie 链测试：首页拿 NMTID → 再请求 cloudsearch
const crypto = require('crypto');
const IV = '0102030405060708';
const MOD =
  '00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725' +
  '152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e031' +
  '2ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b4' +
  '24d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a2' +
  '2b8e7';

function aesB(d, k) {
  const c = crypto.createCipheriv('aes-128-cbc', Buffer.from(k), Buffer.from(IV));
  return Buffer.concat([c.update(d), c.final()]);
}
function rsaPow(t) {
  const rev = t.split('').reverse().join('');
  const m = BigInt('0x' + Buffer.from(rev).toString('hex'));
  const n = BigInt('0x' + MOD);
  let r = 1n,
    b = m % n,
    e = 65537n;
  while (e > 0n) {
    if (e & 1n) r = (r * b) % n;
    b = (b * b) % n;
    e >>= 1n;
  }
  return r.toString(16).padStart(256, '0');
}

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

function cookieFrom(res, existing) {
  const jar = new Map();
  for (const c of existing) jar.set(c.split('=')[0], c);
  const sc = res.headers.getSetCookie ? res.headers.getSetCookie() : [];
  for (const line of sc) {
    const [pair] = line.split(';');
    const i = pair.indexOf('=');
    if (i > 0) jar.set(pair.slice(0, i), pair);
  }
  return [...jar.values()];
}

(async () => {
  const cookieJar = [];
  // 1. 首页
  const home = await fetch('https://music.163.com/', {
    headers: { 'User-Agent': UA, Accept: 'text/html,application/xhtml+xml,*/*;q=0.8' },
  });
  console.log('home status', home.status, 'set-cookie:', JSON.stringify(home.headers.getSetCookie ? home.headers.getSetCookie() : home.headers.get('set-cookie')));
  for (const c of cookieFrom(home, cookieJar)) cookieJar.push(c);
  console.log('jar now:', cookieJar.join('; ').slice(0, 300));

  // 2. 加密 cloudsearch 请求
  const secKey = 'abcdefghijklmnop';
  const body = JSON.stringify({ s: 'Lyla esoragoto', type: 1, limit: 5, offset: 0, total: true, csrf_token: '' });
  const first = aesB(Buffer.from(body), '0CoJUm6Qyw8W8jud');
  const params = aesB(Buffer.from(first.toString('base64')), secKey).toString('base64');
  const encSecKey = rsaPow(secKey);
  const form = new URLSearchParams({ params, encSecKey }).toString();

  const res = await fetch('https://music.163.com/weapi/cloudsearch/get/web?csrf_token=', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': UA,
      Referer: 'https://music.163.com/',
      Origin: 'https://music.163.com/',
      Accept: '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      Cookie: cookieJar.join('; '),
    },
    body: form,
  });
  console.log('search status', res.status);
  console.log('body:', (await res.text()).slice(0, 300));

  // 3. 对照：老 API /api/search/get（web 端）
  const oldRes = await fetch('https://music.163.com/weapi/search/get?csrf_token=', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': UA,
      Referer: 'https://music.163.com/',
      Origin: 'https://music.163.com/',
      Accept: '*/*',
      Cookie: cookieJar.join('; '),
    },
    body: form.replace('cloudsearch', 'search').includes('') ? form : form,
  });
  console.log('old search status', oldRes.status, 'body:', (await oldRes.text()).slice(0, 300));
})().catch((e) => console.error(e));
