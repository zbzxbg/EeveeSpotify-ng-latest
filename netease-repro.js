// 复现设备日志场景：中文歌 search/get 实测
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
function weapiEncrypt(object) {
  const text = JSON.stringify(object);
  const secKey = Array.from(crypto.randomBytes(16))
    .map((b) => 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'[b % 62])
    .join('');
  return {
    params: aesB(Buffer.from(aesB(Buffer.from(text), '0CoJUm6Qyw8W8jud').toString('base64')), secKey).toString('base64'),
    encSecKey: rsaPow(secKey),
  };
}

(async () => {
  // 与 Swift 端一致的 4 关键词序列（周杰伦两首）
  const cases = [
    ['擱淺', '周杰倫'],
    ['晴天', '周杰倫'],
  ];
  for (const [title, artist] of cases) {
    const stripped = title.replace(/\(.*\)/, '').replace(/- .*/, '').trim();
    const keywords = [`${title} ${artist}`, `${stripped} ${artist}`, title, stripped];
    console.log('==== ', title, '-', artist, '====');
    for (const kw of keywords) {
      const trimmed = kw.trim();
      if (!trimmed) continue;
      const enc = weapiEncrypt({ s: trimmed, type: 1, limit: 30, offset: 0, csrf_token: '' });
      const res = await fetch('https://music.163.com/weapi/search/get?csrf_token=', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          Referer: 'https://music.163.com',
          Origin: 'https://music.163.com/',
          Accept: '*/*',
          Cookie: 'os=pc',
        },
        body: new URLSearchParams(enc).toString(),
      });
      const text = await res.text();
      let songs = null;
      try {
        songs = JSON.parse(text).result.songs;
      } catch (e) {}
      console.log(
        ' kw="' + trimmed + '"',
        'status', res.status,
        'songs', songs ? songs.length : 'PARSE FAIL',
        'body head:', text.slice(0, 100)
      );
      if (songs && songs.length) break;
    }
  }
})().catch((e) => console.error(e));
