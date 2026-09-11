/**
 * Mac Fold — Interactive Apple Hardware & Shader Simulator
 * Simulates MacBook lid sensor IOHID reading & Metal 3.0 fragment effects in real time.
 * Author: Dalchand Rana (@dalchandrana)
 */

(function () {
  'use strict';

  // State
  let currentAngle = 115; // default angle
  let currentEffect = 'duo'; // duo, ghost, roll, shutter, flex, iris
  let isLooping = false;
  let loopDirection = -0.5;
  let animFrameId = null;
  let stillnessTimer = null;
  let isStillnessCleared = false;

  // DOM Elements
  const slider = document.getElementById('lid-angle-slider');
  const angleDisplay = document.getElementById('angle-display');
  const lidAssembly = document.getElementById('macbook-lid');
  const canvas = document.getElementById('simulator-canvas');
  const ctx = canvas ? canvas.getContext('2d') : null;
  const effectTabs = document.querySelectorAll('.effect-tab');
  const presetBtns = document.querySelectorAll('.preset-btn');
  const telemetryPill = document.getElementById('telemetry-angle');
  const telemetryGpu = document.getElementById('telemetry-gpu');
  const stillnessBadge = document.getElementById('stillness-badge');

  if (!canvas || !ctx) return;

  // Resize canvas for sharp Retina rendering
  function resizeCanvas() {
    const rect = canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 2;
    canvas.width = rect.width * dpr;
    canvas.height = rect.height * dpr;
    ctx.scale(dpr, dpr);
    renderCurrentState();
  }

  window.addEventListener('resize', resizeCanvas);

  // Set Lid Angle
  function setAngle(angle, triggerEvent = true) {
    currentAngle = Math.max(15, Math.min(135, angle));

    if (slider && triggerEvent) {
      slider.value = currentAngle;
    }

    if (angleDisplay) {
      angleDisplay.textContent = `${Math.round(currentAngle)}°`;
    }

    if (telemetryPill) {
      telemetryPill.textContent = `Lid ${Math.round(currentAngle)}°`;
    }

    if (telemetryGpu) {
      // Real GPU benchmark range from DEVELOPMENT.md: 1.94ms - 2.30ms
      const ms = (1.95 + Math.sin(currentAngle * 0.05) * 0.2).toFixed(2);
      telemetryGpu.textContent = `${ms} ms (Metal 3)`;
    }

    // Physical 3D Tilt Transformation on the MacBook Lid
    if (lidAssembly) {
      // 120° is full open (0deg tilt in perspective)
      // 15° is almost fully closed
      const tiltDeg = (120 - currentAngle) * 0.48;
      lidAssembly.style.transform = `perspective(1200px) rotateX(${tiltDeg}deg)`;

      // Specular shadow changes with angle
      const shadowIntensity = Math.min(0.85, 0.4 + (120 - currentAngle) / 140);
      lidAssembly.style.boxShadow = `0 ${10 + (120 - currentAngle) * 0.15}px ${30 + (120 - currentAngle) * 0.2}px rgba(0, 0, 0, ${shadowIntensity})`;
    }

    // Reset stillness timer on movement
    resetStillnessTimer();

    // Render active shader effect onto the virtual display
    renderCurrentState();
  }

  // Stillness Detection (Simulating LidStillness.swift 2-second clearing)
  function resetStillnessTimer() {
    if (stillnessBadge) {
      stillnessBadge.style.opacity = '0';
      stillnessBadge.textContent = 'Active';
    }
    isStillnessCleared = false;

    clearTimeout(stillnessTimer);
    stillnessTimer = setTimeout(() => {
      isStillnessCleared = true;
      if (stillnessBadge) {
        stillnessBadge.style.opacity = '1';
        stillnessBadge.textContent = 'Stillness Cleared (Screen Restored)';
      }
      renderCurrentState();
    }, 2000);
  }

  // Render Engine: Draws macOS Desktop & simulates each Metal effect
  function renderCurrentState() {
    const rect = canvas.getBoundingClientRect();
    const w = rect.width;
    const h = rect.height;

    ctx.clearRect(0, 0, w, h);

    // If stillness cleared the effect, restore clean normal desktop
    const foldFactor = isStillnessCleared
      ? 0
      : Math.max(0, Math.min(1, (110 - currentAngle) / 95));

    // Base macOS Desktop Background (Apple Sonoma / Sequoia Style Graphic Gradient)
    const grad = ctx.createLinearGradient(0, 0, w, h);
    grad.addColorStop(0, '#1b1429');
    grad.addColorStop(0.35, '#3b1d54');
    grad.addColorStop(0.65, '#5c225a');
    grad.addColorStop(1, '#1e1124');
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, w, h);

    // Ambient wallpaper orb glow
    const orbGrad = ctx.createRadialGradient(w * 0.5, h * 0.4, 10, w * 0.5, h * 0.4, w * 0.4);
    orbGrad.addColorStop(0, 'rgba(255, 107, 24, 0.25)');
    orbGrad.addColorStop(0.5, 'rgba(191, 90, 242, 0.15)');
    orbGrad.addColorStop(1, 'transparent');
    ctx.fillStyle = orbGrad;
    ctx.fillRect(0, 0, w, h);

    // Draw macOS Desktop UI (Menu Bar, Windows, Dock)
    drawDesktopUI(ctx, w, h);

    // Apply Active Effect Shader Simulation
    if (foldFactor > 0.01) {
      ctx.save();
      switch (currentEffect) {
        case 'duo':
          renderDuoEffect(ctx, w, h, foldFactor);
          break;
        case 'ghost':
          renderGhostEffect(ctx, w, h, foldFactor);
          break;
        case 'roll':
          renderRollEffect(ctx, w, h, foldFactor);
          break;
        case 'shutter':
          renderShutterEffect(ctx, w, h, foldFactor);
          break;
        case 'flex':
          renderFlexEffect(ctx, w, h, foldFactor);
          break;
        case 'iris':
          renderIrisEffect(ctx, w, h, foldFactor);
          break;
      }
      ctx.restore();
    }
  }

  // Helper: Draw Simulated macOS Desktop UI
  function drawDesktopUI(ctx, w, h) {
    // macOS Menu Bar
    ctx.fillStyle = 'rgba(255, 255, 255, 0.12)';
    ctx.fillRect(0, 0, w, 22);

    // Apple Logo & Menu Bar items
    ctx.fillStyle = 'rgba(255, 255, 255, 0.85)';
    ctx.font = '10px -apple-system, sans-serif';
    ctx.fillText('  Finder  File  Edit  View  Go  Window  Help', 12, 15);

    // Right Menu Bar (Clock & Mac Fold icon)
    ctx.fillStyle = '#ff6b18';
    ctx.beginPath();
    ctx.arc(w - 70, 11, 4, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = 'rgba(255, 255, 255, 0.75)';
    ctx.fillText('9:41 AM', w - 55, 15);

    // Floating macOS App Window 1 (Code Editor)
    const win1X = w * 0.08;
    const win1Y = h * 0.18;
    const win1W = w * 0.52;
    const win1H = h * 0.58;

    // Window shadow & body
    ctx.fillStyle = 'rgba(18, 18, 22, 0.78)';
    roundRect(ctx, win1X, win1Y, win1W, win1H, 8, true, false);

    // Window Title Bar
    ctx.fillStyle = 'rgba(32, 32, 38, 0.9)';
    roundRect(ctx, win1X, win1Y, win1W, 24, { tl: 8, tr: 8, bl: 0, br: 0 }, true, false);

    // Traffic Lights
    ctx.fillStyle = '#ff5f56';
    ctx.beginPath(); ctx.arc(win1X + 12, win1Y + 12, 3.5, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = '#ffbd2e';
    ctx.beginPath(); ctx.arc(win1X + 22, win1Y + 12, 3.5, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = '#27c93f';
    ctx.beginPath(); ctx.arc(win1X + 32, win1Y + 12, 3.5, 0, Math.PI * 2); ctx.fill();

    // Window Code Lines
    ctx.fillStyle = 'rgba(255, 255, 255, 0.3)';
    ctx.fillRect(win1X + 16, win1Y + 40, win1W * 0.45, 6);
    ctx.fillRect(win1X + 16, win1Y + 54, win1W * 0.65, 6);
    ctx.fillStyle = '#ff6b18';
    ctx.fillRect(win1X + 16, win1Y + 68, win1W * 0.35, 6);
    ctx.fillStyle = 'rgba(41, 151, 255, 0.8)';
    ctx.fillRect(win1X + 16, win1Y + 82, win1W * 0.55, 6);
    ctx.fillStyle = 'rgba(255, 255, 255, 0.2)';
    ctx.fillRect(win1X + 16, win1Y + 96, win1W * 0.7, 6);

    // Floating App Window 2 (Mac Fold Native Controls Window)
    const win2X = w * 0.58;
    const win2Y = h * 0.24;
    const win2W = w * 0.36;
    const win2H = h * 0.54;

    ctx.fillStyle = 'rgba(28, 28, 34, 0.92)';
    roundRect(ctx, win2X, win2Y, win2W, win2H, 10, true, false);

    // Traffic lights
    ctx.fillStyle = '#ff5f56';
    ctx.beginPath(); ctx.arc(win2X + 12, win2Y + 12, 3.5, 0, Math.PI * 2); ctx.fill();

    // Mac Fold UI preview inside window
    ctx.fillStyle = '#ffffff';
    ctx.font = 'bold 11px -apple-system, sans-serif';
    ctx.fillText('Mac Fold', win2X + 26, win2Y + 16);

    ctx.fillStyle = 'rgba(255, 107, 24, 0.2)';
    roundRect(ctx, win2X + 14, win2Y + 34, win2W - 28, 20, 4, true, false);
    ctx.fillStyle = '#ff8533';
    ctx.font = '9px -apple-system, sans-serif';
    ctx.fillText(`Lid Angle: ${Math.round(currentAngle)}°`, win2X + 22, win2Y + 47);

    // Switch toggles inside window
    ctx.fillStyle = 'rgba(255, 255, 255, 0.08)';
    roundRect(ctx, win2X + 14, win2Y + 66, win2W - 28, 16, 4, true, false);
    ctx.fillStyle = '#30d158';
    ctx.beginPath(); ctx.arc(win2X + win2W - 24, win2Y + 74, 5, 0, Math.PI * 2); ctx.fill();

    // macOS Dock at Bottom
    const dockW = w * 0.48;
    const dockH = 28;
    const dockX = (w - dockW) / 2;
    const dockY = h - 34;

    ctx.fillStyle = 'rgba(255, 255, 255, 0.18)';
    roundRect(ctx, dockX, dockY, dockW, dockH, 14, true, false);

    // App icons in Dock
    const iconColors = ['#2997ff', '#ff6b18', '#30d158', '#ffd60a', '#bf5af2', '#ff375f'];
    iconColors.forEach((col, i) => {
      ctx.fillStyle = col;
      roundRect(ctx, dockX + 14 + i * (dockW / 7), dockY + 5, 18, 18, 5, true, false);
    });
  }

  // 1. DUO EFFECT: Hinge swell, softness blur bloom, and gradual disappearance
  function renderDuoEffect(ctx, w, h, f) {
    const hingeY = h;
    const collapseHeight = h * f;

    // Gradient fade from hinge upward
    const duoGrad = ctx.createLinearGradient(0, hingeY, 0, hingeY - collapseHeight);
    duoGrad.addColorStop(0, 'rgba(0, 0, 0, 0.98)');
    duoGrad.addColorStop(0.4, 'rgba(10, 10, 15, 0.85)');
    duoGrad.addColorStop(1, 'transparent');

    ctx.fillStyle = duoGrad;
    ctx.fillRect(0, hingeY - collapseHeight, w, collapseHeight);

    // Swell blur bloom along the folding line
    ctx.fillStyle = `rgba(255, 107, 24, ${0.15 * (1 - f)})`;
    ctx.fillRect(0, hingeY - collapseHeight, w, 8);
  }

  // 2. GHOST EFFECT: Fixed resting plane compensation with progressive defocus
  function renderGhostEffect(ctx, w, h, f) {
    // Optical blur overlay
    ctx.fillStyle = `rgba(15, 15, 20, ${f * 0.88})`;
    ctx.fillRect(0, 0, w, h);

    // Counter-rotation grid representing perspective compensation
    ctx.strokeStyle = `rgba(255, 255, 255, ${0.12 * f})`;
    ctx.lineWidth = 1;
    for (let y = 0; y < h; y += 24) {
      const offset = (h - y) * f * 0.3;
      ctx.beginPath();
      ctx.moveTo(0, y + offset);
      ctx.lineTo(w, y + offset);
      ctx.stroke();
    }
  }

  // 3. ROLL EFFECT: Pixel sheet curling into a cylindrical roll traveling to hinge
  function renderRollEffect(ctx, w, h, f) {
    const rollY = h * (1 - f);
    const rollRadius = 24 + f * 12;

    // Black void revealed above the roll
    ctx.fillStyle = '#000000';
    ctx.fillRect(0, 0, w, rollY);

    // Cylindrical curved roll highlight & shadow
    const rollGrad = ctx.createLinearGradient(0, rollY - rollRadius, 0, rollY + rollRadius);
    rollGrad.addColorStop(0, 'rgba(0, 0, 0, 0.9)');
    rollGrad.addColorStop(0.35, 'rgba(255, 255, 255, 0.45)'); // specular highlight
    rollGrad.addColorStop(0.7, 'rgba(40, 40, 48, 0.9)');
    rollGrad.addColorStop(1, 'rgba(0, 0, 0, 0.95)');

    ctx.fillStyle = rollGrad;
    ctx.fillRect(0, rollY - rollRadius, w, rollRadius * 2);

    // Drop shadow beneath roll
    ctx.fillStyle = 'rgba(0, 0, 0, 0.6)';
    ctx.fillRect(0, rollY + rollRadius, w, 20);
  }

  // 4. SHUTTER EFFECT: 4 rigid telescoping panels sliding into hinge
  function renderShutterEffect(ctx, w, h, f) {
    const panels = 4;
    const panelH = h / panels;

    for (let i = 0; i < panels; i++) {
      const slideDistance = (panels - i) * (f * panelH * 0.8);
      const y = i * panelH + slideDistance;

      // Drop shadow for panel overlap
      ctx.fillStyle = 'rgba(0, 0, 0, 0.7)';
      ctx.fillRect(0, y - 6, w, 8);

      // Darkening gradient as panels retract
      ctx.fillStyle = `rgba(0, 0, 0, ${f * 0.7})`;
      ctx.fillRect(0, y, w, panelH);
    }
  }

  // 5. FLEX EFFECT: Continuous curved bowing under mechanical tension
  function renderFlexEffect(ctx, w, h, f) {
    const bowDepth = f * 70;
    const midY = h * 0.6;

    // Bowing curvature shadow
    ctx.beginPath();
    ctx.moveTo(0, midY - bowDepth);
    ctx.quadraticCurveTo(w / 2, midY + bowDepth * 1.5, w, midY - bowDepth);
    ctx.lineTo(w, h);
    ctx.lineTo(0, h);
    ctx.closePath();

    const flexGrad = ctx.createLinearGradient(0, midY - bowDepth, 0, h);
    flexGrad.addColorStop(0, 'rgba(0, 0, 0, 0.1)');
    flexGrad.addColorStop(0.5, `rgba(0, 0, 0, ${f * 0.75})`);
    flexGrad.addColorStop(1, 'rgba(0, 0, 0, 0.95)');

    ctx.fillStyle = flexGrad;
    ctx.fill();
  }

  // 6. IRIS EFFECT: 8 precision blades closing an aperture above the hinge
  function renderIrisEffect(ctx, w, h, f) {
    const cx = w / 2;
    const cy = h * 0.65;
    const maxR = Math.max(w, h);
    const radius = Math.max(0, maxR * (1 - f * 1.2));
    const blades = 8;
    const angleStep = (Math.PI * 2) / blades;
    const rotation = f * 0.6;

    ctx.save();
    ctx.translate(cx, cy);
    ctx.rotate(rotation);

    for (let i = 0; i < blades; i++) {
      ctx.rotate(angleStep);
      ctx.beginPath();
      ctx.moveTo(0, -radius);
      ctx.lineTo(maxR, -radius - 80);
      ctx.lineTo(maxR, radius + 200);
      ctx.lineTo(0, radius + 200);
      ctx.closePath();

      ctx.fillStyle = 'rgba(10, 10, 14, 0.94)';
      ctx.strokeStyle = 'rgba(255, 255, 255, 0.15)';
      ctx.lineWidth = 1;
      ctx.fill();
      ctx.stroke();
    }
    ctx.restore();
  }

  // Helper: Round Rectangle path
  function roundRect(ctx, x, y, width, height, radius, fill, stroke) {
    if (typeof radius === 'number') {
      radius = { tl: radius, tr: radius, br: radius, bl: radius };
    } else {
      radius = Object.assign({ tl: 0, tr: 0, br: 0, bl: 0 }, radius);
    }
    ctx.beginPath();
    ctx.moveTo(x + radius.tl, y);
    ctx.lineTo(x + width - radius.tr, y);
    ctx.quadraticCurveTo(x + width, y, x + width, y + radius.tr);
    ctx.lineTo(x + width, y + height - radius.br);
    ctx.quadraticCurveTo(x + width, y + height, x + width - radius.br, y + height);
    ctx.lineTo(x + radius.bl, y + height);
    ctx.quadraticCurveTo(x, y + height, x, y + height - radius.bl);
    ctx.lineTo(x, y + radius.tl);
    ctx.quadraticCurveTo(x, y, x + radius.tl, y);
    ctx.closePath();
    if (fill) ctx.fill();
    if (stroke) ctx.stroke();
  }

  // Continuous Replay Animation Loop
  function toggleReplay() {
    isLooping = !isLooping;
    const replayBtn = document.getElementById('btn-replay-loop');
    if (replayBtn) {
      replayBtn.classList.toggle('active', isLooping);
      replayBtn.textContent = isLooping ? 'Pause Loop' : 'Replay Loop';
    }

    if (isLooping) {
      runReplayStep();
    } else {
      cancelAnimationFrame(animFrameId);
    }
  }

  function runReplayStep() {
    if (!isLooping) return;

    currentAngle += loopDirection;
    if (currentAngle <= 25) {
      currentAngle = 25;
      loopDirection = 0.6; // reverse direction to open
    } else if (currentAngle >= 120) {
      currentAngle = 120;
      loopDirection = -0.6; // reverse direction to close
    }

    setAngle(currentAngle, true);
    animFrameId = requestAnimationFrame(runReplayStep);
  }

  // Event Listeners
  if (slider) {
    slider.addEventListener('input', (e) => {
      if (isLooping) toggleReplay();
      setAngle(parseFloat(e.target.value), false);
    });
  }

  // Effect Switcher Tabs
  effectTabs.forEach((tab) => {
    tab.addEventListener('click', () => {
      effectTabs.forEach((t) => t.classList.remove('active'));
      tab.classList.add('active');
      currentEffect = tab.dataset.effect || 'duo';
      renderCurrentState();
    });
  });

  // Angle Presets
  presetBtns.forEach((btn) => {
    btn.addEventListener('click', () => {
      if (btn.id === 'btn-replay-loop') {
        toggleReplay();
        return;
      }
      if (isLooping) toggleReplay();
      const targetAngle = parseFloat(btn.dataset.angle);
      if (!isNaN(targetAngle)) {
        presetBtns.forEach((b) => b.classList.remove('active'));
        btn.classList.add('active');
        setAngle(targetAngle, true);
      }
    });
  });

  // Expose global API for external triggers (e.g. clicking effect cards in grid)
  window.MacFoldSimulator = {
    setEffect: (effectName) => {
      currentEffect = effectName;
      effectTabs.forEach((tab) => {
        tab.classList.toggle('active', tab.dataset.effect === effectName);
      });
      renderCurrentState();
    },
    setAngle: (angle) => setAngle(angle, true),
  };

  // Initialize
  setTimeout(() => {
    resizeCanvas();
    setAngle(115, true);
  }, 50);
})();
