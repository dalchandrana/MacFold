/**
 * Mac Fold — Apple Silicon Hardware Compatibility Inspector
 * Checks model compatibility with HID Lid Angle Sensor (Page 0x20, Usage 0x8A)
 */

(function () {
  'use strict';

  const models = [
    {
      id: 'mbp-14-16-apple-silicon',
      name: 'MacBook Pro 14" & 16"',
      chip: 'M1 Pro/Max, M2 Pro/Max, M3 Pro/Max, M4 Pro/Max',
      supported: true,
      badge: 'Fully Supported',
      details:
        'Hardware lid angle sensor detected via HID Page 0x20 / Usage 0x8A. Liquid Retina XDR ProMotion displays render effects at up to 120Hz with native Metal 3 shaders.',
    },
    {
      id: 'mba-m2-m3-m4',
      name: 'MacBook Air 13" & 15"',
      chip: 'Apple M2, M3, M4 or newer',
      supported: true,
      badge: 'Fully Supported',
      details:
        'Equipped with modern unibody lid angle sensor. Real-time 30Hz polling delivers immediate physical lid response across all six effects.',
    },
    {
      id: 'mba-m1',
      name: 'MacBook Air (2020)',
      chip: 'Apple M1',
      supported: false,
      badge: 'Manual Replay Only',
      details:
        'The original M1 MacBook Air chassis does not expose the 0x8A HID lid angle sensor report. Mac Fold runs in Replay and manual preview mode.',
    },
    {
      id: 'mbp-13-m1-m2',
      name: 'MacBook Pro 13" (Touch Bar)',
      chip: 'Apple M1 or M2',
      supported: false,
      badge: 'Manual Replay Only',
      details:
        'The legacy 13-inch chassis lacks the modern hinge angle hardware sensor. Effects can still be experienced via keyboard shortcuts and manual sliders.',
    },
    {
      id: 'desktop-mac',
      name: 'Mac Studio, mini, Pro & iMac',
      chip: 'All Apple Silicon',
      supported: false,
      badge: 'Manual Preview Only',
      details:
        'Desktop Mac models do not feature a physical lid. The Mac Fold menu bar companion and manual test triggers remain accessible.',
    },
  ];

  const grid = document.getElementById('compat-grid');
  const resultBox = document.getElementById('compat-result');

  if (!grid || !resultBox) return;

  function renderModels() {
    grid.innerHTML = '';
    models.forEach((model, index) => {
      const chip = document.createElement('button');
      chip.type = 'button';
      chip.className = `compat-chip ${index === 0 ? 'active' : ''}`;
      chip.dataset.id = model.id;
      chip.innerHTML = `
        <span>${model.name}</span>
        <span class="chip-sub">${model.chip}</span>
      `;
      chip.addEventListener('click', () => selectModel(model, chip));
      grid.appendChild(chip);
    });

    // Select default
    selectModel(models[0]);
  }

  function selectModel(model, clickedChip) {
    if (clickedChip) {
      document.querySelectorAll('.compat-chip').forEach((c) => c.classList.remove('active'));
      clickedChip.classList.add('active');
    }

    resultBox.innerHTML = `
      <div class="compat-status-icon ${model.supported ? 'supported' : 'unsupported'}">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          ${
            model.supported
              ? '<polyline points="20 6 9 17 4 12"></polyline>'
              : '<circle cx="12" cy="12" r="10"></circle><line x1="12" y1="8" x2="12" y2="12"></line><line x1="12" y1="16" x2="12.01" y2="16"></line>'
          }
        </svg>
      </div>
      <div class="compat-result-text">
        <h4>${model.name} — <span style="color: ${model.supported ? 'var(--apple-green)' : 'var(--apple-yellow)'}">${model.badge}</span></h4>
        <p>${model.details}</p>
      </div>
    `;
  }

  renderModels();
})();
