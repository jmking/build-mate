// Manual reliability spike. Playwright/ffmpeg are project hook tools, not app dependencies.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs = require('node:fs/promises');
const { execFileSync } = require('node:child_process');
(async () => {
 const root = await fs.mkdtemp('/tmp/buildmate-recording-');
 const html = root + '/index.html';
 await fs.writeFile(html, '<!doctype html><title>Proof fixture</title><button onclick="this.textContent=\'Passed\'">Run check</button>');
 const browser = await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 try { for(let i=0;i<3;i++) {
  const started=Date.now();
  const context=await browser.newContext({recordVideo:{dir:root,size:{width:800,height:600}}});
  const page=await context.newPage();await page.goto('file://'+html);
  await page.getByRole('button',{name:'Run check'}).click();
  await page.getByRole('button',{name:'Passed'}).waitFor();
  const video=page.video();await context.close();const source=await video.path();
  const target=root+'/proof-'+i+'.mp4';
  execFileSync('/opt/homebrew/bin/ffmpeg',['-loglevel','error','-i',source,'-c:v','libx264','-pix_fmt','yuv420p',target]);
  const bytes=(await fs.stat(target)).size;
  console.log(JSON.stringify({run:i+1,bytes,elapsedMs:Date.now()-started}));
 }
 } finally { await browser.close(); }
 console.log('Recording directory: '+root);
})().catch(e=>{console.error(e.message);process.exitCode=1});
