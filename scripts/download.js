#!/usr/bin/env node
// Generic downloader used by repo tooling on sandboxed Windows hosts
// where schannel TLS is unavailable. Usage:
//   node scripts/download.js <url> <destFile>
// Honors HTTPS_PROXY / HTTP_PROXY / ALL_PROXY, falls back to the Windows
// system proxy (127.0.0.1:7890 on this dev box) when env vars are absent.
const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');

const PROXY_CANDIDATES = [
  process.env.HTTPS_PROXY || process.env.https_proxy,
  process.env.HTTP_PROXY || process.env.http_proxy,
  process.env.ALL_PROXY || process.env.all_proxy,
  'http://127.0.0.1:7890',
].filter(Boolean);

async function tryRequest(target, proxy) {
  return new Promise((resolve, reject) => {
    const opts = { timeout: 60000 };
    let req;
    const make = (mod, options) => mod.request(options, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        return resolve({ redirect: res.headers.location });
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error('HTTP ' + res.statusCode));
      }
      resolve({ res });
    });
    if (proxy) {
      const p = new URL(proxy);
      const targetUrl = new URL(target);
      req = make(http, {
        host: p.hostname,
        port: p.port,
        method: 'CONNECT',
        path: targetUrl.hostname + ':443',
        timeout: 20000,
      });
      req.on('connect', (res, socket) => {
        if (res.statusCode !== 200) {
          return reject(new Error('proxy CONNECT ' + res.statusCode));
        }
        const r2 = https.request({
          host: targetUrl.hostname,
          path: targetUrl.pathname + targetUrl.search,
          socket,
          agent: false,
          timeout: 120000,
        }, (res2) => {
          if (res2.statusCode >= 300 && res2.statusCode < 400 && res2.headers.location) {
            res2.resume();
            return resolve({ redirect: res2.headers.location });
          }
          if (res2.statusCode !== 200) {
            res2.resume();
            return reject(new Error('HTTP ' + res2.statusCode));
          }
          resolve({ res: res2 });
        });
        r2.on('error', reject);
        r2.on('timeout', () => { r2.destroy(new Error('timeout')); });
        r2.end();
      });
      req.on('error', reject);
      req.end();
    } else {
      const u = new URL(target);
      req = make(https, { hostname: u.hostname, path: u.pathname + u.search, ...opts });
      req.on('error', reject);
      req.end();
    }
  });
}

async function download(target, dest) {
  const attempts = [null, ...PROXY_CANDIDATES];
  for (const proxy of attempts) {
    try {
      process.stdout.write(`[try] ${proxy ? 'via ' + proxy : 'direct'} ... `);
      const result = await tryRequest(target, proxy);
      if (result.redirect) {
        console.log('redirect -> ' + result.redirect);
        return download(result.redirect, dest);
      }
      console.log('streaming');
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      await new Promise((resolve, reject) => {
        const out = fs.createWriteStream(dest);
        result.res.pipe(out);
        out.on('finish', resolve);
        out.on('error', reject);
        result.res.on('error', reject);
      });
      const size = fs.statSync(dest).size;
      console.log(`saved ${dest} (${(size / 1024 / 1024).toFixed(1)} MB)`);
      return true;
    } catch (e) {
      console.log('failed: ' + e.message);
    }
  }
  return false;
}

async function main() {
  const [target, dest] = process.argv.slice(2);
  if (!target || !dest) {
    console.error('usage: node download.js <url> <destFile>');
    process.exit(2);
  }
  const ok = await download(target, dest);
  process.exit(ok ? 0 : 1);
}
main();
