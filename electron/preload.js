// WhalePet 预加载脚本：通过 contextBridge 暴露最小类型化 API
// 同一个 preload 同时服务宠物窗和气泡窗，渲染进程按需要使用各自子集。
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('whale', {
  // ---- 宠物窗 ----
  dragStart: () => ipcRenderer.send('pet-drag-start'),
  dragMove: () => ipcRenderer.send('pet-drag-move'),
  dragEnd: () => ipcRenderer.send('pet-drag-end'),
  openContextMenu: () => ipcRenderer.send('pet-context-menu'),
  toggleBubble: (show) => ipcRenderer.send('toggle-bubble', show),
  onDragging: (cb) => ipcRenderer.on('pet-dragging', (_e, v) => cb(v)),
  onClickResult: (cb) => ipcRenderer.on('pet-click-result', (_e, isClick) => cb(isClick)),
  onPlay: (cb) => ipcRenderer.on('pet-play', (_e, action) => cb(action)),

  // ---- 气泡窗 ----
  bubbleClose: () => ipcRenderer.send('bubble-close'),
  onOpenSettings: (cb) => ipcRenderer.on('open-settings', () => cb()),
  chatSend: (text, history) => ipcRenderer.send('chat-send', { text, history }),
  chatStop: () => ipcRenderer.send('chat-stop'),
  chatNew: () => ipcRenderer.send('chat-new'),
  petPlay: (action) => ipcRenderer.send('pet-play', action),
  onChunk: (cb) => ipcRenderer.on('chat-chunk', (_e, text) => cb(text)),
  onStatus: (cb) => ipcRenderer.on('chat-status', (_e, text) => cb(text)),
  onDone: (cb) => ipcRenderer.on('chat-done', (_e, info) => cb(info)),
  onError: (cb) => ipcRenderer.on('chat-error', (_e, text) => cb(text)),
  settingsGet: () => ipcRenderer.invoke('settings-get'),
  settingsSet: (patch) => ipcRenderer.invoke('settings-set', patch),
});
