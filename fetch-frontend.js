// 抓取网易官网前端 JS，提取 weapi 加密常量（检查 RSA 公钥是否已更换）
async function main() {
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  const home = await fetch('https://music.163.com/', { headers: { 'User-Agent': ua } });
  const html = await home.text();
  console.log('homepage status', home.status, 'len', html.length);
  const scripts = [...html.matchAll(/<script[^>]+src="([^"]+)"/g)].map((m) => m[1]);
  console.log('--- all scripts ---');
  console.log(scripts.join('\n'));

  // 抓取每个本地脚本，搜索加密常量
  const targets = scripts.filter((s) => !/^https?:/i.test(s));
  for (const src of targets) {
    const url = src.startsWith('//')
      ? 'https:' + src
      : src.startsWith('/')
        ? 'https://music.163.com' + src
        : src;
    try {
      const r = await fetch(url, {
        headers: {
          'User-Agent': ua,
          Referer: 'https://music.163.com/',
        },
      });
      const js = await r.text();
      console.log('\n=== ', url, r.status, js.length, ' ===');
      if (js.length < 200) {
        console.log('short body:', js.slice(0, 200));
        continue;
      }
      const needles = [
        '0CoJUm6Qyw8W8jud', 'e0b509f6', '010001', 'b509f625',
        'encSecKey', 'eapi', 'linuxapi', 'rFgB', 'e82ckenh8dichen8',
        'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDhWmcPZzJ7oUZ',
        'BarrettMu', 'RSAKeyPair', 'register/anonimous', 'cloudsearch',
        'secKey', 'secretKey', 'jsonp', 'wapi',
      ];
      for (const needle of needles) {
        const idx = js.indexOf(needle);
        if (idx >= 0) {
          console.log('found "' + needle + '" at', idx, ':');
          console.log(js.slice(Math.max(0, idx - 200), idx + 300));
          console.log('---');
        } else {
          console.log('NOT found:', needle);
        }
      }
    } catch (e) {
      console.log('FAIL', url, e.message);
    }
  }
}
main().catch((e) => console.error(e));
