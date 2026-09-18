// 抓取 core JS 的加密函数区 + asrsea 调用点 + BF2W 混淆常量区
async function main() {
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  const core = 'https://s3.music.126.net/web/s/core_acddf9e8ef94d38b11fc0a622cbc0234.js?acddf9e8ef94d38b11fc0a622cbc0234';
  const r = await fetch(core, { headers: { 'User-Agent': ua, Referer: 'https://music.163.com/' } });
  const js = await r.text();
  console.log('len', js.length);

  // 1. asrsea 定义区（含 a/b/c/d/e 函数完整定义）
  const encIdx = js.indexOf('encSecKey');
  console.log('\n=== ENCRYPT BLOCK ===');
  console.log(js.slice(encIdx - 1200, encIdx + 600));

  // 2. 所有 asrsea 调用点
  console.log('\n=== asrsea CALL SITES ===');
  let idx = -1;
  let count = 0;
  while ((idx = js.indexOf('asrsea', idx + 1)) >= 0 && count < 6) {
    console.log('--- call at', idx, '---');
    console.log(js.slice(Math.max(0, idx - 400), idx + 400));
    count++;
  }

  // 3. BF2W 混淆常量区（模数等）
  console.log('\n=== BF2W CONSTANTS ===');
  const bf2w = js.indexOf('BF2W.emj');
  if (bf2w >= 0) console.log(js.slice(bf2w - 200, bf2w + 3000));
}
main().catch((e) => console.error(e));
