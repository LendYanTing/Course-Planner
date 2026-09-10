#!/usr/bin/env node
// Signs in to Course Planner in a browser and captures the long-lived MCP
// token it issues, then prints a ready-to-paste MCP client config.
//
//   node scripts/mcp-connect.js [options]
//
//     --server <url>    backend origin            (default http://127.0.0.1:8080)
//     --name <label>    token label               (default "MCP client")
//     --scopes <list>   read | read,write         (default read,write)
//     --days <n>        0 = never expires         (default 0)
//     --write <path>    also write the config to this file (e.g. .mcp.json)
//     --json            print only the JSON config (script-friendly)
//
// Set MCP_CONNECT_NO_BROWSER=1 to skip opening a browser (headless hosts).
// The token is only ever printed to stdout (and the file you ask for); this
// script never writes a credential anywhere on its own.
const http = require('http');
const fs = require('fs');
const { spawn } = require('child_process');

const TIMEOUT_MS = 5 * 60 * 1000;

function parseArgs(argv) {
  const opts = { server: 'http://127.0.0.1:8080', name: 'MCP client', scopes: 'read,write', days: '0', json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      i += 1;
      if (i >= argv.length) throw new Error(arg + ' needs a value');
      return argv[i];
    };
    switch (arg) {
      case '--server': opts.server = next(); break;
      case '--name': opts.name = next(); break;
      case '--scopes': opts.scopes = next(); break;
      case '--days': opts.days = next(); break;
      case '--write': opts.write = next(); break;
      case '--json': opts.json = true; break;
      case '--help': case '-h': opts.help = true; break;
      default: throw new Error('unknown option: ' + arg);
    }
  }
  return opts;
}

function usage() {
  return [
    'Usage: node scripts/mcp-connect.js [--server URL] [--name LABEL]',
    '                                  [--scopes read|read,write] [--days N]',
    '                                  [--write FILE] [--json]',
  ].join('\n');
}

function openBrowser(url) {
  const platform = process.platform;
  let cmd;
  let args;
  if (platform === 'win32') {
    cmd = 'cmd';
    // The empty "" is the window title; without it `start` would treat the
    // URL as the title and open nothing.
    args = ['/c', 'start', '""', url];
  } else if (platform === 'darwin') {
    cmd = 'open';
    args = [url];
  } else {
    cmd = 'xdg-open';
    args = [url];
  }
  try {
    const child = spawn(cmd, args, { stdio: 'ignore', detached: true });
    child.on('error', () => {});
    child.unref();
  } catch (err) {
    // Not fatal: the URL is printed either way.
  }
}

function clientConfig(server, token) {
  return {
    mcpServers: {
      'course-planner': {
        type: 'http',
        url: server.replace(/\/$/, '') + '/api/v1/mcp',
        headers: { Authorization: 'Bearer ' + token },
      },
    },
  };
}

function callbackPage(ok, message) {
  return '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">' +
    '<title>Course Planner MCP</title><style>body{font:15px/1.6 system-ui,"Microsoft YaHei",sans-serif;' +
    'display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#f5f6f8;color:#1c1f24}' +
    '.box{background:#fff;border:1px solid #e3e6ea;border-radius:14px;padding:28px 32px;text-align:center;max-width:460px}' +
    'h1{font-size:18px;margin:0 0 8px}p{margin:0;color:#5c6570}</style></head><body><div class="box">' +
    '<h1>' + (ok ? '凭证已收到' : '取值失败') + '</h1><p>' + message + '</p></div></body></html>';
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    console.log(usage());
    return 0;
  }

  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      const incoming = new URL(req.url, 'http://127.0.0.1');
      if (incoming.pathname !== '/callback') {
        res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('not found');
        return;
      }
      const token = incoming.searchParams.get('token');
      if (!token) {
        res.writeHead(400, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(callbackPage(false, '回调里没有 token，请重试。'));
        return;
      }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(callbackPage(true, '已保存到终端输出，可以关闭这个窗口。'));

      const config = clientConfig(opts.server, token);
      const rendered = JSON.stringify(config, null, 2);
      console.log('');
      console.log('凭证名称：' + (incoming.searchParams.get('name') || opts.name));
      console.log('权限范围：' + (incoming.searchParams.get('scopes') || opts.scopes));
      console.log('tokenId ：' + (incoming.searchParams.get('tokenId') || '-') + '  (用它吊销)');
      console.log('');
      console.log(rendered);
      if (opts.write) {
        fs.writeFileSync(opts.write, rendered + '\n', 'utf8');
        console.log('\n已写入 ' + opts.write + '（该文件含凭证，已在 .gitignore 中）');
      }
      console.log('');
      console.log('Claude Code 一行命令：');
      console.log('  claude mcp add --transport http course-planner ' +
        opts.server.replace(/\/$/, '') + '/api/v1/mcp --header "Authorization: Bearer ' + token + '"');
      console.log('');
      resolve(0);
    });

    server.on('error', (err) => {
      console.error('无法监听本地回调端口：' + err.message);
      resolve(1);
    });

    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      const connectURL = opts.server.replace(/\/$/, '') + '/mcp/connect?' + new URLSearchParams({
        redirect_uri: 'http://127.0.0.1:' + port + '/callback',
        name: opts.name,
        scopes: opts.scopes,
      }).toString();

      if (!opts.json) {
        console.log('在浏览器中打开下面的地址并登录：');
        console.log('  ' + connectURL);
        console.log('');
        console.log('（如果浏览器没有自动打开，请手动粘贴上面的地址）');
      }
      if (!opts.json && !process.env.MCP_CONNECT_NO_BROWSER) openBrowser(connectURL);
    });

    const timer = setTimeout(() => {
      console.error('等待超时（5 分钟），没有收到回调。');
      server.close(() => resolve(1));
    }, TIMEOUT_MS);
    timer.unref();
    server.on('close', () => clearTimeout(timer));
  });
}

main()
  .then((code) => process.exit(code))
  .catch((err) => {
    console.error(err.message);
    console.error(usage());
    process.exit(1);
  });
