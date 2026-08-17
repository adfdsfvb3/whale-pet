// 鲸鱼娘宠物渲染进程：帧动画播放器 + 交互（拖拽/单击/双击/随机小动作）
// 帧序列：frames/<action>/000.png..120.png，12fps（约 83ms 一帧）
(function () {
  const FPS_MS = 83;
  const FRAME_COUNT = 121;
  // 循环动作 / 一次性动作（播完回 idle）
  const LOOP_ACTIONS = new Set(['idle', 'drag', 'crab']);
  const ONE_SHOT = ['look', 'hum', 'stretch', 'cube', 'crab']; // 随机小动作池
  const DBLCLICK_ACTIONS = ['happy', 'shy', 'angry'];

  const img = document.getElementById('pet');
  const preloaded = new Set(); // 已预热的动作目录
  let current = 'idle';
  let frame = 0;
  let dragging = false;
  let oneShotActive = false;

  function framePath(action, n) {
    return '../frames/' + action + '/' + String(n).padStart(3, '0') + '.png';
  }

  // 懒加载：第一次播某动作时预热全部帧，避免播放中卡顿
  function preload(action) {
    if (preloaded.has(action)) return;
    preloaded.add(action);
    for (let i = 0; i < FRAME_COUNT; i++) {
      const im = new Image();
      im.src = framePath(action, i);
    }
  }

  function play(action) {
    preload(action);
    current = action;
    frame = 0;
    img.src = framePath(action, 0);
  }

  // 一次性动作：播完回 idle
  function playOnce(action) {
    if (dragging) return; // 拖拽中不打扰
    oneShotActive = true;
    play(action);
  }

  // 主循环：12fps 换帧
  setInterval(() => {
    frame++;
    if (frame >= FRAME_COUNT) {
      if (LOOP_ACTIONS.has(current)) {
        frame = 0;
      } else {
        // 一次性动作播完
        oneShotActive = false;
        play(dragging ? 'drag' : 'idle');
        return;
      }
    }
    img.src = framePath(current, frame);
  }, FPS_MS);

  // ---- 拖拽：位移交给主进程（它跟踪全局光标），这里只负责状态与动画 ----
  let mouseDown = false;
  img.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;
    mouseDown = true;
    window.whale.dragStart();
  });
  window.addEventListener('mousemove', () => {
    if (mouseDown) window.whale.dragMove();
  });
  window.addEventListener('mouseup', () => {
    if (!mouseDown) return;
    mouseDown = false;
    window.whale.dragEnd(); // 主进程会回发 pet-click-result
  });

  // 主进程判定超过 5px → 真正的拖动
  window.whale.onDragging((v) => {
    dragging = v;
    if (v) {
      play('drag');
    } else if (!oneShotActive) {
      play('idle');
    }
  });

  // 单击（未超过 5px）→ 开关气泡；区分双击
  let clickTimer = null;
  window.whale.onClickResult((isClick) => {
    if (!isClick) return;
    if (clickTimer) {
      // 双击：随机播 happy/shy/angry
      clearTimeout(clickTimer);
      clickTimer = null;
      playOnce(DBLCLICK_ACTIONS[Math.floor(Math.random() * DBLCLICK_ACTIONS.length)]);
    } else {
      clickTimer = setTimeout(() => {
        clickTimer = null;
        window.whale.toggleBubble();
      }, 260);
    }
  });

  // 右键菜单
  img.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    window.whale.openContextMenu();
  });

  // 主进程点名播动作（聊天状态联动：look/happy/angry 等）
  window.whale.onPlay((action) => {
    if (!action) return;
    if (action === 'idle') {
      oneShotActive = false;
      if (!dragging) play('idle');
    } else {
      playOnce(action);
    }
  });

  // 随机小动作：每 25~60 秒一次
  function scheduleAmbient() {
    const delay = 25000 + Math.random() * 35000;
    setTimeout(() => {
      if (!dragging && !oneShotActive) {
        playOnce(ONE_SHOT[Math.floor(Math.random() * ONE_SHOT.length)]);
      }
      scheduleAmbient();
    }, delay);
  }
  scheduleAmbient();

  // 预热常用动作
  preload('idle');
  preload('drag');
})();
