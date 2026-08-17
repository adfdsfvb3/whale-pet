// 鲸鱼娘聊天气泡渲染进程：对话流、迷你 markdown、设置表单、TTS/STT
(function () {
  const $ = (id) => document.getElementById(id);
  const transcript = $('transcript');
  const statusEl = $('status');
  const input = $('input');
  const btnSend = $('btn-send');
  const btnMic = $('btn-mic');

  let inFlight = false;       // 是否有回复进行中
  let history = [];           // [{role, content}]，直连模式用（发给主进程取最近 12 条）
  let currentPetMsg = null;   // 当前正在追加 chunk 的宠物气泡
  let replyText = '';         // 累积本轮回复全文（TTS / 历史用）
  let ttsEnabled = false;

  // ---- 迷你 markdown：``` 代码块、**粗体**、`行内代码` ----
  function escapeHtml(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
  function renderMd(text) {
    let html = escapeHtml(text);
    //  fenced code block
    html = html.replace(/```(\w*)\n?([\s\S]*?)```/g, (_m, _lang, code) =>
      '<pre><code>' + code.replace(/\n$/, '') + '</code></pre>');
    html = html.replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>');
    html = html.replace(/`([^`\n]+)`/g, '<code>$1</code>');
    return html;
  }

  function addMsg(role, text) {
    const div = document.createElement('div');
    div.className = 'msg ' + role;
    div.innerHTML = renderMd(text);
    transcript.appendChild(div);
    transcript.scrollTop = transcript.scrollHeight;
    return div;
  }

  function setStatus(text) {
    statusEl.textContent = text || '';
  }

  function setInFlight(v) {
    inFlight = v;
    btnSend.textContent = v ? '■' : '➤';
    btnSend.title = v ? '停止' : '发送';
    btnSend.classList.toggle('stop', v);
  }

  // ---- 发送 ----
  function send() {
    const text = input.value.trim();
    if (!text || inFlight) return;
    input.value = '';
    addMsg('user', text);
    currentPetMsg = addMsg('pet', '');
    replyText = '';
    setInFlight(true);
    setStatus('发送中……');
    window.whale.petPlay('look'); // 等待时宠物东张西望
    window.whale.chatSend(text, history);
    history.push({ role: 'user', content: text }); // 失败时会在 onError 里弹出
  }

  btnSend.addEventListener('click', () => {
    if (inFlight) {
      window.whale.chatStop(); // ACP → session/cancel；直连 → abort
      setStatus('已停止');
    } else {
      send();
    }
  });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') send();
  });

  // ---- 主进程事件 ----
  window.whale.onChunk((text) => {
    // ACP 的 chunk 是已提交块，直接追加
    replyText += text;
    if (currentPetMsg) {
      currentPetMsg.innerHTML = renderMd(replyText);
      transcript.scrollTop = transcript.scrollHeight;
    }
  });

  window.whale.onStatus((text) => setStatus(text));

  window.whale.onDone((info) => {
    setInFlight(false);
    if (info && info.ok) {
      setStatus('');
      if (replyText) history.push({ role: 'assistant', content: replyText });
      window.whale.petPlay('happy'); // 开心一下再回 idle
      speak(replyText);
    }
    currentPetMsg = null;
  });

  window.whale.onError((text) => {
    setInFlight(false);
    setStatus('出错了：' + text);
    window.whale.petPlay('angry');
    if (history.length && history[history.length - 1].role === 'user') history.pop(); // 本轮不算数
  });

  // ---- TTS：zh-CN 语音，截断到 200 字 ----
  function speak(text) {
    if (!ttsEnabled || !text || !('speechSynthesis' in window)) return;
    try {
      speechSynthesis.cancel();
      const u = new SpeechSynthesisUtterance(text.slice(0, 200));
      u.lang = 'zh-CN';
      const zh = speechSynthesis.getVoices().find((v) => v.lang && v.lang.startsWith('zh'));
      if (zh) u.voice = zh;
      speechSynthesis.speak(u);
    } catch (_) { /* TTS 失败静默 */ }
  }

  // ---- STT：webkitSpeechRecognition（不支持则禁用麦克风按钮） ----
  const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!SR) {
    btnMic.disabled = true;
    btnMic.title = '当前环境不支持语音输入';
  } else {
    let rec = null;
    let recording = false;
    btnMic.addEventListener('click', () => {
      if (recording) {
        rec.stop();
        return;
      }
      rec = new SR();
      rec.lang = 'zh-CN';
      rec.continuous = false;
      rec.interimResults = true;
      rec.onresult = (e) => {
        let partial = '';
        for (const r of e.results) partial += r[0].transcript;
        input.value = partial; // 中间结果直接进输入框
      };
      rec.onend = () => {
        recording = false;
        btnMic.classList.remove('recording');
      };
      rec.onerror = () => {
        recording = false;
        btnMic.classList.remove('recording');
        setStatus('语音识别失败，请检查麦克风权限');
      };
      recording = true;
      btnMic.classList.add('recording');
      rec.start();
    });
  }

  // ---- 头部按钮 ----
  $('btn-close').addEventListener('click', () => window.whale.bubbleClose());
  $('btn-new').addEventListener('click', () => {
    transcript.innerHTML = '';
    history = [];
    replyText = '';
    currentPetMsg = null;
    window.whale.chatNew(); // 主进程重建 ACP 会话
    setStatus('新对话已开始');
    setTimeout(() => setStatus(''), 2000);
  });

  // ---- 设置面板 ----
  const settingsPanel = $('settings');
  async function openSettings() {
    const s = await window.whale.settingsGet();
    $('set-key').value = s.apiKey || '';
    $('set-model').value = s.model || 'deepseek-v4-pro';
    $('set-tts').checked = !!s.tts;
    $('set-repo').value = s.repoPath || '';
    settingsPanel.classList.add('show');
  }
  $('btn-settings').addEventListener('click', () => {
    if (settingsPanel.classList.contains('show')) {
      settingsPanel.classList.remove('show');
    } else {
      openSettings();
    }
  });
  window.whale.onOpenSettings(() => openSettings()); // 右键菜单“设置”直达
  $('btn-save').addEventListener('click', async () => {
    await window.whale.settingsSet({
      apiKey: $('set-key').value.trim(),
      model: $('set-model').value,
      tts: $('set-tts').checked,
      repoPath: $('set-repo').value.trim(),
    });
    ttsEnabled = $('set-tts').checked;
    settingsPanel.classList.remove('show');
    setStatus('设置已保存');
    setTimeout(() => setStatus(''), 2000);
  });

  // 启动时同步 TTS 开关
  window.whale.settingsGet().then((s) => { ttsEnabled = !!s.tts; });

  input.focus();
})();
