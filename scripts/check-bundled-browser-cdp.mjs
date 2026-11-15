// Exercise the same Page/Runtime protocol used by live scrapes, on a private
// about:blank target. No website sessions or personal browser profiles are used.
import {readFileSync, watch} from 'node:fs';
import {join} from 'node:path';

const profile = process.argv[2];
const port = await new Promise((resolve, reject) => {
  const watcher = watch(profile, probe);
  function probe() {
    try {
      const value = Number(readFileSync(join(profile, 'DevToolsActivePort'), 'utf8').split('\n')[0]);
      if (value > 0 && value <= 65535) { watcher.close(); resolve(value); }
    } catch (error) { if (error.code !== 'ENOENT') { watcher.close(); reject(error); } }
  }
  probe();
});
const response = await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, {method: 'PUT'});
if (!response.ok) throw new Error(`CDP target creation failed: ${response.status}`);
const target = await response.json();
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.addEventListener('open', resolve, {once: true});
  socket.addEventListener('error', reject, {once: true});
});
let nextId = 0;
const pending = new Map();
socket.addEventListener('message', event => {
  const message = JSON.parse(String(event.data));
  const request = pending.get(message.id);
  if (!request) return;
  pending.delete(message.id);
  if (message.error) request.reject(new Error(message.error.message));
  else request.resolve(message.result);
});
function call(method, params = {}) {
  const id = ++nextId;
  return new Promise((resolve, reject) => {
    pending.set(id, {resolve, reject});
    socket.send(JSON.stringify({id, method, params}));
  });
}
try {
  await call('Page.enable');
  await call('Runtime.enable');
  const result = await call('Runtime.evaluate', {
    expression: '(()=>{let n=0;for(let i=0;i<100000;i++)n+=i;return n})()',
    returnByValue: true,
  });
  if (result.result?.value !== 4999950000) throw new Error('Renderer returned an unexpected result');
  console.log('Page.enable and JavaScript execution passed');
} finally {
  socket.close();
}
