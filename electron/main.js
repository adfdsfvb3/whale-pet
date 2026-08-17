// WhalePet 鲸鱼娘 —— Electron 主进程
// 纯 JS，无框架。职责：宠物窗/气泡窗管理、拖拽移动、右键菜单、设置存储、ACP 客户端、直连 DeepSeek API。
const { app, BrowserWindow, ipcMain, Menu, shell, screen } = require('electron');
const { spawn, execFile } = require('child_process');
const fs = require('fs');
const path = require('path');
const https = require('https');

// ---------- 设置存储（userData/settings.json，API key 只存这里） ----------
const DEFAULT_SETTINGS = {
  apiKey: '',
  model: 'deepseek-v4-pro', // v4-pro/v4-flash 走 ACP agent；deepseek-chat/reasoner 直连 API
  tts: false,
  repoPath: '/Users/miao/deepseek-harness', // dsh 仓库路径（ACP agent 所在仓库）
};
let settings = { ...DEFAULT_SETTINGS };
function settingsFile() {
  return path.join(app.getPath('userData'), 'settings.json');
}
function loadSettings() {
  try {
    const raw = fs.readFileSync(settingsFile(), 'utf8');
    settings = { ...DEFAULT_SETTINGS, ...JSON.parse(raw) };
  } catch (_) { /* 首次运行无文件，用默认值 */ }
}
function saveSettings(patch) {
  settings = { ...settings, ...patch };
  fs.mkdirSync(app.getPath('userData'), { recursive: true });
  fs.writeFileSync(settingsFile(), JSON.stringify(settings, null, 2));
}

// ---------- 查找系统 node（用于启动 ACP agent） ----------
let cachedNode = null;
function findNode() {
  return new Promise((resolve) => {
    if (cachedNode) return resolve(cachedNode);
    const done = (p) => { cachedNode = p || 'node'; resolve(cachedNode); };
    if (process.platform === 'win32') {
      execFile('where.exe', ['node'], (err, stdout) => {
        done(err ? null : stdout.split(/\r?\n/)[0].trim());
      });
    } else {
      // 用登录 shell 解析 PATH，兼容 nvm 等安装方式
      const sh = process.env.SHELL || '/bin/zsh';
      execFile(sh, ['-l', '-c', 'command -v node'], (err, stdout) => {
        done(err ? null : stdout.trim());
      });
    }
  });
}

// ---------- 窗口 ----------
let petWin = null;
let bubbleWin = null;
let bubbleOpen = false;

function createPetWindow() {
  petWin = new BrowserWindow({
    width: 220,
    height: 220,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    resizable: false,
    skipTaskbar: true,
    hasShadow: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  petWin.setAlwaysOnTop(true, 'screen-saver');
  petWin.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  // 初始位置：屏幕右下角
  const { workAreaSize } = screen.getPrimaryDisplay();
  petWin.setPosition(workAreaSize.width - 260, workAreaSize.height - 260);
  petWin.loadFile(path.join(__dirname, 'renderer', 'pet.html'));
  petWin.on('closed', () => { petWin = null; });
}

function createBubbleWindow() {
  bubbleWin = new BrowserWindow({
    width: 360,
    height: 420,
    frame: false,
    show: false,
    alwaysOnTop: true,
    resizable: false,
    skipTaskbar: true,
    roundedCorners: true, // macOS；圆角主要靠 CSS
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  bubbleWin.setAlwaysOnTop(true, 'screen-saver');
  bubbleWin.loadFile(path.join(__dirname, 'renderer', 'bubble.html'));
  bubbleWin.on('closed', () => { bubbleWin = null; bubbleOpen = false; });
}

// 气泡定位：优先宠物正上方，顶部空间不足则放到下方
function positionBubble() {
  if (!petWin || !bubbleWin) return;
  const [px, py] = petWin.getPosition();
  const pb = petWin.getBounds();
  const pw = pb.width, ph = pb.height;
  const display = screen.getDisplayNearestPoint({ x: px, y: py });
  const area = display.workArea;
  const bw = 360, bh = 420;
  let x = Math.round(px + pw / 2 - bw / 2);
  x = Math.max(area.x, Math.min(x, area.x + area.width - bw));
  let y = py - bh - 8;
  if (y < area.y) y = py + ph + 8; // 上方放不下，翻到下方
  bubbleWin.setPosition(x, Math.round(y));
}

function toggleBubble(show) {
  if (!bubbleWin) createBubbleWindow();
  bubbleOpen = show === undefined ? !bubbleOpen : show;
  if (bubbleOpen) {
    positionBubble();
    bubbleWin.show();
    bubbleWin.focus();
  } else {
    bubbleWin.hide();
  }
}

// ---------- 宠物窗口拖拽（渲染进程发 mousedown 时的光标偏移，主进程跟踪全局光标） ----------
let dragState = null; // { offsetX, offsetY, winX, winY, moved }
ipcMain.on('pet-drag-start', () => {
  if (!petWin) return;
  const cursor = screen.getCursorScreenPoint();
  const [wx, wy] = petWin.getPosition();
  dragState = { offsetX: cursor.x - wx, offsetY: cursor.y - wy, startX: cursor.x, startY: cursor.y, moved: false };
});
ipcMain.on('pet-drag-move', () => {
  if (!petWin || !dragState) return;
  const cursor = screen.getCursorScreenPoint();
  if (!dragState.moved) {
    // 超过 5px 才算拖动，否则视为点击
    const dx = cursor.x - dragState.startX;
    const dy = cursor.y - dragState.startY;
    if (Math.hypot(dx, dy) <= 5) return;
    dragState.moved = true;
    petWin.webContents.send('pet-dragging', true); // 通知渲染进程播 drag 动画
  }
  petWin.setPosition(Math.round(cursor.x - dragState.offsetX), Math.round(cursor.y - dragState.offsetY));
});
ipcMain.on('pet-drag-end', () => {
  const wasDrag = dragState && dragState.moved;
  dragState = null;
  if (petWin) petWin.webContents.send('pet-dragging', false);
  if (petWin) petWin.webContents.send('pet-click-result', !wasDrag); // true=单击
});

// 宠物动画状态转发：气泡请求宠物播某个动作
ipcMain.on('pet-play', (_e, action) => {
  if (petWin) petWin.webContents.send('pet-play', action);
});

// 打开/关闭气泡
ipcMain.on('toggle-bubble', (_e, show) => toggleBubble(show));
ipcMain.on('bubble-close', () => toggleBubble(false));

// ---------- 右键菜单 ----------
ipcMain.on('pet-context-menu', () => {
  const menu = Menu.buildFromTemplate([
    { label: '对话', click: () => toggleBubble(true) },
    { label: '设置', click: () => { toggleBubble(true); if (bubbleWin) bubbleWin.webContents.send('open-settings'); } },
    { label: '打开完整版（Web）', click: () => openFullWeb() },
    { type: 'separator' },
    { label: '退出', click: () => app.quit() },
  ]);
  menu.popup({ window: petWin });
});

// 打开完整版 Web：先探测 127.0.0.1:3080，不通则在 dsh 仓库里起 `pnpm dsh web` 并轮询
async function openFullWeb() {
  const url = 'http://127.0.0.1:3080';
  const probe = () => new Promise((resolve) => {
    const req = require('http').get(url, (res) => { res.resume(); resolve(true); });
    req.on('error', () => resolve(false));
    req.setTimeout(1500, () => { req.destroy(); resolve(false); });
  });
  if (await probe()) return shell.openExternal(url);
  sendBubbleStatus('正在启动 dsh web 服务……');
  try {
    const child = spawn('pnpm', ['dsh', 'web'], {
      cwd: settings.repoPath || DEFAULT_SETTINGS.repoPath,
      detached: true,
      stdio: 'ignore',
      shell: process.platform === 'win32',
    });
    child.unref();
  } catch (_) { /* 下面轮询失败会给提示 */ }
  for (let i = 0; i < 40; i++) { // 最多等 ~40s
    await new Promise((r) => setTimeout(r, 1000));
    if (await probe()) return shell.openExternal(url);
  }
  sendBubbleStatus('dsh web 服务启动超时，请检查仓库路径设置');
}

// ---------- 设置 IPC ----------
ipcMain.handle('settings-get', () => ({ ...settings }));
ipcMain.handle('settings-set', (_e, patch) => {
  const needRespawn = patch.apiKey !== undefined || patch.model !== undefined || patch.repoPath !== undefined;
  saveSettings(patch || {});
  if (needRespawn) {
    acp.respawn(); // key/model/仓库变了，重启 ACP
    acpFirstPrompt = true; // 新会话首条 prompt 重新加设定前缀
  }
  return { ...settings };
});

// ---------- 气泡状态/事件转发 ----------
function sendBubble(channel, payload) {
  if (bubbleWin && !bubbleWin.isDestroyed()) bubbleWin.webContents.send(channel, payload);
}
const sendBubbleStatus = (text) => sendBubble('chat-status', text);

// ---------- ACP 客户端（ndjson JSON-RPC over stdio） ----------
// 注意：DSH_ACP_MODEL 生效依赖仓库里 examples/acp-agent/cordis.yml 已把 model 行改为
//   model: !!js "process.env.DSH_ACP_MODEL ?? 'deepseek-v4-pro'"
// 本机仓库已打好该补丁；换机器部署时需同步该修改。
class AcpClient {
  constructor() {
    this.proc = null;
    this.buf = '';
    this.nextId = 1;
    this.pending = new Map(); // id -> {resolve, reject, timer}
    this.sessionId = null;
    this.state = 'idle'; // idle | starting | ready | failed
    this.retryCount = 0;
    this.disabled = false; // 连续失败后本轮运行禁用 ACP，回退直连
    this.startPromise = null;
  }

  // 发送一行 JSON-RPC
  write(obj) {
    if (this.proc && this.proc.stdin.writable) {
      this.proc.stdin.write(JSON.stringify(obj) + '\n');
    }
  }

  call(method, params, timeoutMs) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} 超时`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.write({ jsonrpc: '2.0', id, method, params });
    });
  }

  onLine(line) {
    let msg;
    try { msg = JSON.parse(line); } catch (_) { return; }
    if (msg.id !== undefined && (msg.result !== undefined || msg.error !== undefined) && !msg.method) {
      // 响应
      const p = this.pending.get(msg.id);
      if (p) {
        this.pending.delete(msg.id);
        clearTimeout(p.timer);
        msg.error ? p.reject(new Error(msg.error.message || JSON.stringify(msg.error))) : p.resolve(msg.result);
      }
    } else if (msg.method === 'session/update') {
      // 会话更新：agent_message_chunk 是“已提交块”而非增量，直接追加
      const u = msg.params && msg.params.update;
      if (u && u.sessionUpdate === 'agent_message_chunk' && u.content && u.content.type === 'text') {
        sendBubble('chat-chunk', u.content.text || '');
      } else if (u && u.sessionUpdate === 'tool_call') {
        sendBubbleStatus('dsh agent 干活中……（调用工具：' + (u.title || '工具') + '）');
      }
    } else if (msg.method === 'session/request_permission') {
      // 服务器请求权限：自动选第一个 kind 以 allow 开头的选项，否则选第一个
      const opts = (msg.params && msg.params.options) || [];
      const opt = opts.find((o) => String(o.kind || '').startsWith('allow')) || opts[0];
      if (opt) {
        this.write({ jsonrpc: '2.0', id: msg.id, result: { outcome: { outcome: 'selected', optionId: opt.optionId } } });
      }
    }
  }

  async spawn() {
    if (this.proc) this.kill();
    this.state = 'starting';
    this.sessionId = null;
    const node = await findNode();
    const workspace = path.join(app.getPath('userData'), 'workspace');
    fs.mkdirSync(workspace, { recursive: true });
    const repo = settings.repoPath || DEFAULT_SETTINGS.repoPath;
    const env = {
      ...process.env,
      DEEPSEEK_API_KEY: settings.apiKey,
      DSH_ACP_MODEL: settings.model,
      HOME: process.env.HOME || process.env.USERPROFILE || '',
      PATH: process.env.PATH || '',
    };
    this.proc = spawn(node, [
      '--import', 'tsx',
      'packages/examples/acp-demo/src/bin.ts',
      '--config', 'examples/acp-agent/cordis.yml',
    ], { cwd: repo, env });

    this.proc.stdout.setEncoding('utf8');
    this.proc.stdout.on('data', (chunk) => {
      this.buf += chunk;
      let idx;
      while ((idx = this.buf.indexOf('\n')) >= 0) {
        const line = this.buf.slice(0, idx).trim();
        this.buf = this.buf.slice(idx + 1);
        if (line) this.onLine(line);
      }
    });
    this.proc.stderr.on('data', () => { /* 静默丢弃 agent 日志 */ });
    this.proc.on('error', (err) => {
      // 启动失败（如 node 路径不对）：拒绝所有挂起请求，走重试/回退逻辑
      for (const [, p] of this.pending) { clearTimeout(p.timer); p.reject(err); }
      this.pending.clear();
    });
    this.proc.on('exit', () => {
      const wasReady = this.state === 'ready';
      this.proc = null;
      this.sessionId = null;
      this.state = 'idle';
      // 拒绝所有挂起的请求
      for (const [, p] of this.pending) { clearTimeout(p.timer); p.reject(new Error('ACP agent 意外退出')); }
      this.pending.clear();
      if (wasReady) sendBubbleStatus('dsh agent 断开了，下条消息会自动重连');
    });

    // 启动慢（tsx 编译），initialize/session/new 给 120s
    await this.call('initialize', { protocolVersion: 1, clientCapabilities: {} }, 120000);
    const r = await this.call('session/new', { cwd: workspace, mcpServers: [] }, 120000);
    this.sessionId = r.sessionId;
    this.state = 'ready';
    this.retryCount = 0;
  }

  kill() {
    if (this.proc) {
      try { this.proc.kill(); } catch (_) {}
      this.proc = null;
    }
    this.state = 'idle';
    this.sessionId = null;
  }

  respawn() {
    this.retryCount = 0;
    this.disabled = false;
    this.kill();
  }

  // 确保可用；失败时重试最多 3 次，再不行返回 false（调用方回退直连）
  async ensureReady() {
    if (this.disabled) return false;
    if (this.state === 'ready' && this.proc) return true;
    if (this.startPromise) return this.startPromise;
    this.startPromise = (async () => {
      while (this.retryCount < 3) {
        try {
          await this.spawn();
          return true;
        } catch (e) {
          this.retryCount++;
          this.kill();
        }
      }
      this.disabled = true;
      return false;
    })();
    const ok = await this.startPromise;
    this.startPromise = null;
    return ok;
  }

  async prompt(text, firstOfSession) {
    const prefix = '（对话设定：你是住在用户电脑桌面上的女仆装鲸鱼娘桌面宠物，说话软萌、用中文；工具结果照实汇报，但日常对话保持简短可爱。以下开始是用户的话。）';
    const full = firstOfSession ? prefix + text : text;
    // 把前缀标记翻转放在调用方；这里只发 prompt
    const result = await this.call('session/prompt', {
      sessionId: this.sessionId,
      prompt: [{ type: 'text', text: full }],
    }, 600000);
    return result;
  }

  cancel() {
    if (this.sessionId) {
      this.write({ jsonrpc: '2.0', method: 'session/cancel', params: { sessionId: this.sessionId } });
    }
  }

  newSession() {
    // 直接重建：kill 后下条消息 ensureReady 会重新 spawn + session/new
    this.kill();
  }
}

const acp = new AcpClient();

// ---------- 直连 DeepSeek API ----------
function directChat(messages, signal, model) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      model: model || settings.model,
      messages,
      stream: false,
    });
    const req = https.request({
      hostname: 'api.deepseek.com',
      path: '/chat/completions',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + settings.apiKey,
        'Content-Length': Buffer.byteLength(body),
      },
    }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        try {
          const j = JSON.parse(data);
          if (j.choices && j.choices[0] && j.choices[0].message) {
            resolve(j.choices[0].message.content || '');
          } else {
            reject(new Error((j.error && j.error.message) || ('HTTP ' + res.statusCode)));
          }
        } catch (e) {
          reject(new Error('API 返回解析失败'));
        }
      });
    });
    req.on('error', reject);
    req.setTimeout(120000, () => { req.destroy(new Error('请求超时')); });
    if (signal) {
      signal.addEventListener('abort', () => req.destroy(new Error('已取消')));
    }
    req.write(body);
    req.end();
  });
}

// ---------- 聊天 IPC ----------
let abortCtl = null; // 直连模式的中止控制器
let acpFirstPrompt = true; // 每个 ACP 会话的首条 prompt 要加设定前缀

ipcMain.on('chat-send', async (e, payload) => {
  const { text, history } = payload; // history: [{role, content}...] 仅直连模式用
  if (!settings.apiKey) {
    sendBubble('chat-error', '还没设置 API Key，点右上角 ⚙ 填一下 DeepSeek API Key 吧');
    return;
  }
  const useAcp = settings.model === 'deepseek-v4-pro' || settings.model === 'deepseek-v4-flash';
  if (petWin) petWin.webContents.send('pet-play', 'look');
  try {
    if (useAcp) {
      const ok = await acp.ensureReady();
      if (ok) {
        sendBubbleStatus('dsh agent 干活中……');
        const wasFirst = acpFirstPrompt;
        const result = await acp.prompt(text, wasFirst);
        if (wasFirst) acpFirstPrompt = false;
        sendBubble('chat-done', { ok: true, mode: 'acp' });
        return;
      }
      sendBubbleStatus('dsh agent 启动失败，本次改用直连模式');
      // 回退直连：把模型换成直连可用的 deepseek-chat（仅本次请求）
    }
    // 直连模式
    const sys = { role: 'system', content: '你是「鲸鱼娘」，一只穿女仆装的深海鲸鱼少女，住在用户的电脑桌面上当宠物。说话软萌、简短（每次一两句话），偶尔带「呜」「咕噜」等语气词。始终用中文回复。' };
    const msgs = [sys, ...history.slice(-12), { role: 'user', content: text }];
    abortCtl = new AbortController();
    sendBubbleStatus('思考中……');
    // ACP 失败回退时临时用 deepseek-chat，不污染用户设置
    const reply = await directChat(msgs, abortCtl.signal, useAcp ? 'deepseek-chat' : undefined);
    sendBubble('chat-chunk', reply);
    sendBubble('chat-done', { ok: true, mode: 'direct' });
  } catch (err) {
    sendBubble('chat-error', String(err && err.message ? err.message : err));
    sendBubble('chat-done', { ok: false });
  } finally {
    abortCtl = null;
  }
});

ipcMain.on('chat-stop', () => {
  if (abortCtl) abortCtl.abort();
  acp.cancel();
});

ipcMain.on('chat-new', () => {
  acp.newSession();
  acpFirstPrompt = true;
});

// ---------- 应用生命周期 ----------
app.whenReady().then(() => {
  loadSettings();
  createPetWindow();
  createBubbleWindow();
});

app.on('window-all-closed', () => {
  app.quit(); // 桌宠：宠物窗关了就整体退出
});

app.on('quit', () => {
  acp.kill();
});
