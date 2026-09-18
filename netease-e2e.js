// 验证老搜索接口 + 歌词接口的完整链路
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

async function weapi(path, params) {
  const enc = weapiEncrypt(params);
  const res = await fetch('https://music.163.com' + path + '?csrf_token=', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': UA,
      Referer: 'https://music.163.com',
      Origin: 'https://music.163.com/',
      Accept: '*/*',
      Cookie: 'os=pc',
    },
    body: new URLSearchParams(enc).toString(),
  });
  return { status: res.status, json: await res.json().catch(() => null) };
}

(async () => {
  // 1. 老搜索接口（多个关键词）
  for (const kw of ['Lyla esoragoto', '星になる 倚水 Islet', '白日夢 tayori']) {
    const r = await weapi('/weapi/search/get', { s: kw, type: 1, limit: 30, offset: 0 });
    const songs = r.json && r.json.result && r.json.result.songs;
    console.log('search', JSON.stringify(kw), 'status', r.status, 'count', songs ? songs.length : null);
    if (songs && songs.length) {
      const top = songs[0];
      console.log('  top:', top.id, JSON.stringify(top.name), 'artists:', JSON.stringify((top.artists || top.ar || []).map((a) => a.name)));
      // 2. 歌词接口
      const lr = await weapi('/weapi/song/lyric', { id: top.id, lv: -1, tv: -1 });
      const lrc = lr.json && lr.json.lrc ? lr.json.lrc.lyric : null;
      const tlyric = lr.json && lr.json.tlyric ? lr.json.tlyric.lyric : null;
      console.log('  lyric status', lr.status, 'code', lr.json && lr.json.code);
      console.log('  lrc head:', JSON.stringify((lrc || '').slice(0, 120)));
      console.log('  tlyric head:', JSON.stringify((tlyric || '').slice(0, 120)));
    }
  }
})().catch((e) => console.error(e));
