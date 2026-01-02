const $ = (sel) => document.querySelector(sel);

const state = {
  jobId: '',
  gseaCore: null, // loaded from gsea_core_genes.json
  selectedPathway: null, // {ID, Description, ...}
  workflowStep: 0, // 0=submit, 1=waiting, 2=gsea, 3=downstream
};

// #region agent log (debug-session helpers)
const __dbgRunId = (window.__rnaSeqDbgRunId ||= `run-${Math.random().toString(16).slice(2)}`);
function __dbg(hypothesisId, location, message, data) {
  fetch('http://127.0.0.1:7242/ingest/f5a316e9-b6a8-4c5b-98ab-77cb40ba3b8d', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      sessionId: 'debug-session',
      runId: __dbgRunId,
      hypothesisId,
      location,
      message,
      data,
      timestamp: Date.now(),
    }),
  }).catch(() => {});
}
// #endregion

// 保存状态到 localStorage
function saveState() {
  try {
    localStorage.setItem('rna_seq_state', JSON.stringify({
      jobId: state.jobId,
      selectedPathway: state.selectedPathway,
      workflowStep: state.workflowStep,
    }));
  } catch (e) {
    console.warn('无法保存状态到 localStorage:', e);
  }
}

// 从 localStorage 恢复状态
function loadState() {
  try {
    const saved = localStorage.getItem('rna_seq_state');
    if (saved) {
      const data = JSON.parse(saved);
      state.jobId = data.jobId || '';
      state.selectedPathway = data.selectedPathway || null;
      state.workflowStep = data.workflowStep || 0;
      setCurrentJobId(state.jobId);
    }
  } catch (e) {
    console.warn('无法从 localStorage 恢复状态:', e);
  }
}

function setCurrentJobId(jobId) {
  state.jobId = jobId || '';
  const el = $('#currentJobId');
  if (el) el.textContent = state.jobId || '--';
  const input = $('#jobIdInput');
  if (input) input.value = state.jobId || '';
  saveState();
}

function fmtTime(t) {
  if (!t) return '--';
  try {
    return new Date(t).toLocaleString();
  } catch {
    return String(t);
  }
}

function detectDelimiter(line) {
  // crude: prefer tab if contains \t, else comma
  if (line.includes('\t')) return '\t';
  if (line.includes(',')) return ',';
  return '\t';
}

async function loadGenesets() {
  const sp = $('#species')?.value;
  if (!sp) return;
  const resp = await fetch(`/api/genesets?species=${encodeURIComponent(sp)}`);
  if (!resp.ok) return;
  const data = await resp.json();

  const sel = $('#gmtFile');
  const current = sel.value;
  sel.innerHTML = '';

  const opt0 = document.createElement('option');
  opt0.value = '';
  opt0.textContent = '(默认)';
  sel.appendChild(opt0);

  for (const f of data.files || []) {
    const opt = document.createElement('option');
    opt.value = f;
    opt.textContent = f;
    sel.appendChild(opt);
  }

  // restore
  if ([...sel.options].some(o => o.value === current)) sel.value = current;
}

async function parseMetadataFile(file) {
  const text = await file.text();
  const lines = text.split(/\r?\n/).filter(Boolean);
  if (lines.length < 2) throw new Error('元数据文件为空或行数不足');

  const delim = detectDelimiter(lines[0]);
  const headers = lines[0].split(delim).map(s => s.trim());
  // Shiny 里第一列是样本名，因此可选 design_var = 其余列
  const cols = headers.slice(1);

  const designSel = $('#designVar');
  designSel.innerHTML = '';

  const opt = document.createElement('option');
  opt.value = '';
  opt.textContent = '(请选择)';
  designSel.appendChild(opt);

  for (const c of cols) {
    const o = document.createElement('option');
    o.value = c;
    o.textContent = c;
    designSel.appendChild(o);
  }

  // build value map for each col
  const colValues = new Map();
  for (const c of cols) colValues.set(c, new Set());

  for (let i = 1; i < lines.length; i++) {
    const parts = lines[i].split(delim);
    for (let j = 1; j < headers.length; j++) {
      const c = headers[j];
      if (!colValues.has(c)) continue;
      const v = (parts[j] ?? '').trim();
      if (v) colValues.get(c).add(v);
    }
  }

  function updateContrasts() {
    const dv = designSel.value;
    const values = dv ? Array.from(colValues.get(dv) || []) : [];

    const numSel = $('#contrastNum');
    const denSel = $('#contrastDenom');
    numSel.innerHTML = '';
    denSel.innerHTML = '';

    const mkOpt = (v) => {
      const o = document.createElement('option');
      o.value = v;
      o.textContent = v;
      return o;
    };

    const optN = document.createElement('option');
    optN.value = '';
    optN.textContent = '(请选择)';
    numSel.appendChild(optN);

    const optD = document.createElement('option');
    optD.value = '';
    optD.textContent = '(请选择)';
    denSel.appendChild(optD);

    for (const v of values) {
      numSel.appendChild(mkOpt(v));
      denSel.appendChild(mkOpt(v));
    }
  }

  designSel.onchange = updateContrasts;
  updateContrasts();
}

let pollTimer = null;

function setJobId(jobId) {
  setCurrentJobId(jobId);
}

function stopPolling() {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
    // #region agent log
    __dbg('G', 'frontend/app.js:stopPolling', 'stopped', {});
    // #endregion
  }
}

function showImageModal(src, alt) {
  const modal = document.createElement('div');
  modal.className = 'image-modal';
  const safeAlt = String(alt || 'image');
  modal.innerHTML = `
    <div class="modal-overlay" onclick="this.parentElement.remove()">
      <div class="modal-image-container" onclick="event.stopPropagation()">
        <img id="modalImg" src="${src}" alt="${safeAlt}" style="max-width: 90vw; max-height: 90vh; border-radius: 12px;" />
        <div style="margin-top: 0.75rem; padding: 0.75rem; border: 1px solid rgba(255,255,255,0.08); border-radius: 12px;">
          <div style="font-weight: 600; margin-bottom: 0.5rem;">导出设置</div>
          <div class="row" style="gap: 0.75rem; align-items: end;">
            <label style="min-width: 140px;">
              <span>宽度 (px)</span>
              <input type="number" id="exportW" min="1" step="1" placeholder="自动" />
            </label>
            <label style="min-width: 140px;">
              <span>高度 (px)</span>
              <input type="number" id="exportH" min="1" step="1" placeholder="自动" />
            </label>
            <label style="min-width: 150px;">
              <span>清晰度倍率</span>
              <input type="number" id="exportScale" min="1" max="4" step="1" value="1" />
              <small class="hint">1=原尺寸，2/3/4=更清晰（更大像素）</small>
            </label>
            <label class="check" style="margin-bottom: 0.25rem;">
              <input type="checkbox" id="keepRatio" checked />
              保持比例
            </label>
          </div>
          <div class="row" style="gap: 0.75rem; align-items: end; margin-top: 0.75rem;">
            <label style="min-width: 180px;">
              <span>导出格式</span>
              <select id="exportFmt">
                <option value="png">PNG（无损）</option>
                <option value="jpeg">JPEG（可调质量）</option>
              </select>
            </label>
            <label style="min-width: 220px;">
              <span>JPEG 质量</span>
              <input type="number" id="exportQ" min="0.1" max="1" step="0.05" value="0.92" />
              <small class="hint">仅对 JPEG 生效</small>
            </label>
            <button class="button" id="exportBtn">导出图片</button>
          </div>
          <div id="exportStatus" style="margin-top: 0.5rem; font-size: 0.9em;"></div>
        </div>
        <div style="margin-top: 1rem;">
          <a href="${src}" download class="button" style="margin-right: 0.5rem;">💾 下载图片</a>
          <button class="button secondary" id="downloadPdfBtn" style="margin-right: 0.5rem;">保存为 PDF</button>
          <button class="button secondary" onclick="this.closest('.image-modal').remove()">关闭</button>
        </div>
      </div>
    </div>
  `;
  document.body.appendChild(modal);

  function parseBaseName(name) {
    const n = String(name || 'image');
    return n.replace(/\.[A-Za-z0-9]+$/, '') || 'image';
  }

  async function loadImage(url) {
    // same-origin; fetch -> blob avoids some caching/cors issues
    const resp = await fetch(url);
    if (!resp.ok) throw new Error(`下载图片失败: ${resp.status}`);
    const blob = await resp.blob();
    const objUrl = URL.createObjectURL(blob);
    try {
      const img = new Image();
      img.decoding = 'async';
      const p = new Promise((resolve, reject) => {
        img.onload = () => resolve(img);
        img.onerror = () => reject(new Error('图片解码失败'));
      });
      img.src = objUrl;
      return await p;
    } finally {
      URL.revokeObjectURL(objUrl);
    }
  }

  function downloadBlob(blob, filename) {
    const u = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = u;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(u), 1000);
  }

  const modalImg = modal.querySelector('#modalImg');
  const wInput = modal.querySelector('#exportW');
  const hInput = modal.querySelector('#exportH');
  const keepRatio = modal.querySelector('#keepRatio');
  const scaleInput = modal.querySelector('#exportScale');
  const fmtSel = modal.querySelector('#exportFmt');
  const qInput = modal.querySelector('#exportQ');
  const statusEl = modal.querySelector('#exportStatus');

  // 初始化默认宽高为图片原始尺寸（加载完成后）
  if (modalImg) {
    modalImg.addEventListener('load', () => {
      // 只在首次为空时填充，避免覆盖用户输入
      if (wInput && !wInput.value) wInput.value = String(modalImg.naturalWidth || '');
      if (hInput && !hInput.value) hInput.value = String(modalImg.naturalHeight || '');
    }, { once: true });
  }

  function syncByRatio(changed) {
    if (!keepRatio?.checked) return;
    const w = Number(wInput?.value || 0);
    const h = Number(hInput?.value || 0);
    const nw = modalImg?.naturalWidth || 0;
    const nh = modalImg?.naturalHeight || 0;
    if (!nw || !nh) return;
    const r = nh / nw;
    if (changed === 'w' && w > 0 && hInput) hInput.value = String(Math.max(1, Math.round(w * r)));
    if (changed === 'h' && h > 0 && wInput) wInput.value = String(Math.max(1, Math.round(h / r)));
  }
  wInput?.addEventListener('input', () => syncByRatio('w'));
  hInput?.addEventListener('input', () => syncByRatio('h'));

  const exportBtn = modal.querySelector('#exportBtn');
  if (exportBtn) {
    exportBtn.addEventListener('click', async () => {
      try {
        if (statusEl) statusEl.textContent = '⏳ 正在导出...';
        const scale = Math.min(4, Math.max(1, Number(scaleInput?.value || 1) || 1));
        const fmt = String(fmtSel?.value || 'png');
        const q = Math.min(1, Math.max(0.1, Number(qInput?.value || 0.92) || 0.92));

        const img = await loadImage(src);
        let outW = Number(wInput?.value || 0) || img.naturalWidth;
        let outH = Number(hInput?.value || 0) || img.naturalHeight;
        outW = Math.max(1, Math.round(outW * scale));
        outH = Math.max(1, Math.round(outH * scale));

        // #region agent log
        __dbg('I', 'frontend/app.js:showImageModal', 'export_clicked', { src, alt: safeAlt, fmt, q, outW, outH, scale });
        // #endregion

        const canvas = document.createElement('canvas');
        canvas.width = outW;
        canvas.height = outH;
        const ctx = canvas.getContext('2d');
        if (!ctx) throw new Error('无法创建 canvas');
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = 'high';
        ctx.drawImage(img, 0, 0, outW, outH);

        const mime = fmt === 'jpeg' ? 'image/jpeg' : 'image/png';
        const blob = await new Promise((resolve) => {
          canvas.toBlob((b) => resolve(b), mime, fmt === 'jpeg' ? q : undefined);
        });
        if (!blob) throw new Error('导出失败（toBlob 返回空）');

        const base = parseBaseName(safeAlt);
        const ext = fmt === 'jpeg' ? 'jpg' : 'png';
        const fname = `${base}_${outW}x${outH}_x${scale}.${ext}`;
        downloadBlob(blob, fname);
        if (statusEl) statusEl.textContent = `✓ 已导出：${fname}`;
      } catch (e) {
        if (statusEl) statusEl.textContent = `✗ 导出失败：${e?.message || String(e)}`;
      }
    });
  }

  // 保存为 PDF：使用浏览器原生“打印 → 另存为 PDF”
  const btn = modal.querySelector('#downloadPdfBtn');
  if (btn) {
    btn.addEventListener('click', () => {
      // #region agent log
      __dbg('E', 'frontend/app.js:showImageModal', 'pdf_print_clicked', { src, alt });
      // #endregion

      const w = window.open('', '_blank');
      if (!w) {
        alert('浏览器阻止了弹窗。请允许弹窗后重试。');
        return;
      }
      w.document.open();
      w.document.write(`<!doctype html>
<html><head><meta charset="utf-8" />
<title>${safeAlt}</title>
<style>
  @page { margin: 10mm; }
  html, body { height: 100%; }
  body { margin: 0; display:flex; align-items:center; justify-content:center; }
  img { max-width: 100%; max-height: 100%; }
</style>
</head><body>
  <img id="pdfImg" src="${src}" alt="${safeAlt}" />
</body></html>`);
      w.document.close();

      const img = w.document.getElementById('pdfImg');
      if (img) {
        img.onload = () => {
          w.focus();
          w.print();
        };
      } else {
        w.focus();
        w.print();
      }
    });
  }
}

function renderOutputs(jobId, outputs) {
  const ul = $('#outputs');
  ul.innerHTML = '';

  const previews = $('#previews');
  previews.innerHTML = '';

  for (const item of outputs || []) {
    const li = document.createElement('li');
    const a = document.createElement('a');
    a.href = item.url;
    a.textContent = `${item.name} (${Math.round((item.size_bytes || 0) / 1024)} KB)`;
    a.target = '_blank';
    li.appendChild(a);
    ul.appendChild(li);

    if (item.name.toLowerCase().endsWith('.png')) {
      // 创建带文件名显示的图片容器
      const wrapper = document.createElement('div');
      wrapper.className = 'preview-item';
      wrapper.setAttribute('data-filename', item.name);
      
      const img = document.createElement('img');
      img.src = item.url;
      img.alt = item.name;
      img.loading = 'lazy';
      img.addEventListener('click', () => showImageModal(item.url, item.name));
      
      wrapper.appendChild(img);
      previews.appendChild(wrapper);
    }
  }

  const zip = $('#downloadZip');
  zip.href = `/api/jobs/${encodeURIComponent(jobId)}/download`;
  zip.style.display = 'inline-flex';

  const log = $('#viewLog');
  log.href = `/api/jobs/${encodeURIComponent(jobId)}/log`;
  log.target = '_blank';
  log.style.display = 'inline-flex';
}

async function fetchStatus(jobId) {
  const resp = await fetch(`/api/jobs/${encodeURIComponent(jobId)}`);
  // #region agent log
  __dbg('B', 'frontend/app.js:fetchStatus', 'fetch_status_response', { jobId, ok: resp.ok, status: resp.status });
  // #endregion
  if (!resp.ok) throw new Error(`查询失败: ${resp.status}`);
  const data = await resp.json();
  // #region agent log
  __dbg('B', 'frontend/app.js:fetchStatus', 'fetch_status_payload', {
    jobId,
    state: data?.state,
    outputsCount: Array.isArray(data?.outputs) ? data.outputs.length : null,
    outputsHasGseaCsv: Array.isArray(data?.outputs) ? data.outputs.some(o => o?.name === 'gsea_results.csv') : null,
    outputsHasGseaCore: Array.isArray(data?.outputs) ? data.outputs.some(o => o?.name === 'gsea_core_genes.json') : null,
  });
  // #endregion
  return data;
}

async function updateStatus(jobId) {
  const st = await fetchStatus(jobId);
  $('#jobState').textContent = st.state || '--';
  $('#jobMsg').textContent = st.message || '--';
  $('#jobCreated').textContent = fmtTime(st.created_at);
  $('#jobStarted').textContent = fmtTime(st.started_at);
  $('#jobFinished').textContent = fmtTime(st.finished_at);

  renderOutputs(jobId, st.outputs || []);

  // 添加下一步引导
  const nextStepsEl = $('#nextSteps');
  if (nextStepsEl && st.state === 'success') {
    const hasGsea = (st.outputs || []).some(o => o.name === 'gsea_results.csv');
    const hasDESeq2 = (st.outputs || []).some(o => o.name === 'deseq2_results.csv');
    
    if (hasGsea || hasDESeq2) {
      let hints = '<div class="alert alert-info" style="margin-top: 1rem;"><strong>🎉 分析完成！下一步建议：</strong><ul style="margin: 0.5rem 0; padding-left: 1.5rem;">';
      if (hasGsea) {
        hints += '<li>前往 <a href="#/gsea" style="font-weight:bold;text-decoration:underline;">GSEA 页面</a> 查看富集通路并生成单通路详细图</li>';
        hints += '<li>选择感兴趣的通路后，去 <a href="#/heatmap" style="font-weight:bold;text-decoration:underline;">热图页面</a> 可视化核心基因表达</li>';
      }
      if (hasDESeq2) {
        hints += '<li>前往 <a href="#/volcano" style="font-weight:bold;text-decoration:underline;">火山图页面</a> 生成增强版火山图（TopN 标注 + 自定义基因）</li>';
      }
      hints += '</ul></div>';
      nextStepsEl.innerHTML = hints;
    }
  } else if (nextStepsEl) {
    nextStepsEl.innerHTML = '';
  }

  const jobState = st.state;
  if (jobState === 'success' || jobState === 'error') {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
  }
}

function startPolling(jobId) {
  if (pollTimer) clearInterval(pollTimer);
  pollTimer = setInterval(() => updateStatus(jobId).catch(console.error), 2000);
  updateStatus(jobId).catch(console.error);
}

function renderSubmitView() {
  $('#view').innerHTML = `
    <div class="card">
      <h2>提交任务</h2>
      <form id="jobForm">
        <div class="row">
          <label>
            <span>计数矩阵 (CSV/TXT/TSV)</span>
            <input type="file" name="count_file" id="countFile" accept=".csv,.txt,.tsv" required />
            <div id="countFileInfo" class="file-info"></div>
          </label>
          <label>
            <span>元数据 (CSV/TXT/TSV)</span>
            <input type="file" name="metadata_file" id="metaFile" accept=".csv,.txt,.tsv" required />
            <div id="metaFileInfo" class="file-info"></div>
          </label>
        </div>

        <div class="row">
          <label>
            <span>物种</span>
            <select name="species" id="species">
              <option value="human" selected>human</option>
              <option value="mouse">mouse</option>
            </select>
          </label>
          <label>
            <span>MSigDB GMT 文件（本地）</span>
            <select name="gmt_file" id="gmtFile">
              <option value="">(默认)</option>
            </select>
          </label>
          <label>
            <span>
              最小计数阈值
              <span class="tooltip-icon" title="过滤低表达基因：至少一个样本的计数值需要 ≥ 此阈值。降低此值可保留更多基因，但可能增加噪音">ⓘ</span>
            </span>
            <input type="number" name="min_count_filter" value="10" min="0" max="100000" />
            <small class="hint">推荐：10（默认）</small>
          </label>
        </div>

        <div class="row">
          <label>
            <span>design_var（来自元数据列）</span>
            <select name="design_var" id="designVar" required>
              <option value="">(请先选择元数据文件)</option>
            </select>
          </label>
          <label>
            <span>处理组 (contrast_num)</span>
            <select name="contrast_num" id="contrastNum" required>
              <option value="">(先选 design_var)</option>
            </select>
          </label>
          <label>
            <span>对照组 (contrast_denom)</span>
            <select name="contrast_denom" id="contrastDenom" required>
              <option value="">(先选 design_var)</option>
            </select>
          </label>
        </div>

        <div class="row">
          <label>
            <span>
              padj 阈值 
              <span class="tooltip-icon" title="校正后的 p 值阈值，用于筛选显著差异基因。常用值：0.05（标准）或 0.01（严格）">ⓘ</span>
            </span>
            <input type="number" name="padj_threshold" value="0.05" min="0" max="1" step="0.001" />
            <small class="hint">推荐：0.05（标准）或 0.01（严格）</small>
          </label>
          <label>
            <span>
              log2FC 阈值
              <span class="tooltip-icon" title="差异倍数阈值（log2转换后）。log2(2)=1 表示 2倍差异，log2(3)≈1.58 表示 3倍差异">ⓘ</span>
            </span>
            <input type="number" name="lfc_threshold" value="1" min="0" max="50" step="0.1" />
            <small class="hint">推荐：1（2倍）或 1.5（约3倍）</small>
          </label>
        </div>

        <div class="row">
          <label class="check"><input type="checkbox" name="run_pca" checked /> 运行 PCA</label>
          <label class="check"><input type="checkbox" name="run_deseq2" checked /> 运行 DESeq2</label>
          <label class="check"><input type="checkbox" name="run_gsea" checked /> 运行 GSEA</label>
          <label class="check"><input type="checkbox" name="run_gsva" /> 运行 GSVA</label>
          <label class="check"><input type="checkbox" name="run_tf" /> 运行 TF(decoupleR)</label>
          <label class="check"><input type="checkbox" name="run_heatmap" /> 生成热图（自定义/TopDEG）</label>
        </div>

        <label>
          <span>热图基因（可选，每行一个；为空则使用 Top DEGs）</span>
          <textarea name="heatmap_genes" rows="5" placeholder="TP53\nBRCA1\nEGFR"></textarea>
        </label>

        <div class="row actions">
          <button type="submit" id="submitBtn">提交任务</button>
          <button type="button" id="resetBtn" class="secondary">清空</button>
        </div>

        <p class="hint">提交后会返回 job_id；后续页面会复用该 job 的输出进行派生绘图（不重跑 DESeq2/GSEA）。</p>
      </form>
    </div>
  `;

  // 文件验证函数
  function validateFile(file, maxSizeMB = 100) {
    const validExts = ['.csv', '.txt', '.tsv'];
    const ext = file.name.substring(file.name.lastIndexOf('.')).toLowerCase();
    
    if (!validExts.includes(ext)) {
      return { valid: false, error: `不支持的文件格式！请上传 ${validExts.join(', ')} 文件` };
    }
    
    const maxSize = maxSizeMB * 1024 * 1024;
    if (file.size > maxSize) {
      return { valid: false, error: `文件过大！最大支持 ${maxSizeMB}MB（当前：${(file.size / 1024 / 1024).toFixed(1)}MB）` };
    }
    
    return { valid: true };
  }

  function showFileInfo(elementId, file) {
    const el = $(elementId);
    if (!el) return;
    const sizeKB = (file.size / 1024).toFixed(1);
    const sizeMB = (file.size / 1024 / 1024).toFixed(2);
    const sizeText = file.size < 1024 * 1024 ? `${sizeKB} KB` : `${sizeMB} MB`;
    el.innerHTML = `<span style="color: var(--success); font-size: 12px;">✓ ${file.name} (${sizeText})</span>`;
  }

  function showFileError(elementId, error) {
    const el = $(elementId);
    if (!el) return;
    el.innerHTML = `<span style="color: var(--danger); font-size: 12px;">✗ ${error}</span>`;
  }

  $('#species').addEventListener('change', () => loadGenesets().catch(console.error));
  
  $('#countFile').addEventListener('change', (e) => {
    const f = e.target.files?.[0];
    if (!f) {
      $('#countFileInfo').innerHTML = '';
      return;
    }
    const result = validateFile(f);
    if (result.valid) {
      showFileInfo('#countFileInfo', f);
    } else {
      showFileError('#countFileInfo', result.error);
      e.target.value = '';
    }
  });
  
  $('#metaFile').addEventListener('change', (e) => {
    const f = e.target.files?.[0];
    if (!f) {
      $('#metaFileInfo').innerHTML = '';
      return;
    }
    const result = validateFile(f);
    if (result.valid) {
      showFileInfo('#metaFileInfo', f);
      parseMetadataFile(f).catch(err => {
        showFileError('#metaFileInfo', err.message || String(err));
      });
    } else {
      showFileError('#metaFileInfo', result.error);
      e.target.value = '';
    }
  });
  $('#resetBtn').addEventListener('click', () => {
    $('#jobForm').reset();
    $('#designVar').innerHTML = '<option value="">(请先选择元数据文件)</option>';
    $('#contrastNum').innerHTML = '<option value="">(先选 design_var)</option>';
    $('#contrastDenom').innerHTML = '<option value="">(先选 design_var)</option>';
  });
  $('#jobForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const form = e.target;
    const fd = new FormData(form);
    for (const name of ['run_pca','run_deseq2','run_gsea','run_gsva','run_tf','run_heatmap']) {
      fd.set(name, form.querySelector(`input[name="${name}"]`).checked ? 'true' : 'false');
    }
    $('#submitBtn').disabled = true;
    $('#submitBtn').textContent = '提交中...';
    try {
      const resp = await fetch('/api/jobs', { method: 'POST', body: fd });
      const data = await resp.json();
      if (!resp.ok) throw new Error(data.detail || `提交失败: ${resp.status}`);
      const jobId = data.job_id;
      setCurrentJobId(jobId);
      state.workflowStep = 1;
      saveState();
      // 显示成功提示
      if (confirm(`✓ 任务已提交！\n\nJob ID: ${jobId}\n\n点击"确定"查看任务状态和结果`)) {
        window.location.hash = '#/jobs';
      }
    } catch (err) {
      alert('❌ 提交失败：' + (err.message || String(err)));
    } finally {
      $('#submitBtn').disabled = false;
      $('#submitBtn').textContent = '提交任务';
    }
  });

  loadGenesets().catch(console.error);
}

function renderJobsView() {
  $('#view').innerHTML = `
    <div class="card">
      <h2>任务 & 结果</h2>
      <div class="row">
        <label class="grow">
          <span>Job ID</span>
          <input type="text" id="jobIdInput" placeholder="粘贴 job_id" />
        </label>
        <button id="loadJobBtn" class="secondary">查询</button>
      </div>

      <div id="statusBox" class="status">
        <div><b>状态</b>：<span id="jobState">--</span></div>
        <div><b>信息</b>：<span id="jobMsg">--</span></div>
        <div><b>创建</b>：<span id="jobCreated">--</span></div>
        <div><b>开始</b>：<span id="jobStarted">--</span></div>
        <div><b>结束</b>：<span id="jobFinished">--</span></div>
        <div class="row actions">
          <a id="downloadZip" class="button" href="#" style="display:none;">下载结果 ZIP</a>
          <a id="viewLog" class="button secondary" href="#" style="display:none;">查看日志</a>
        </div>
      </div>

      <div id="nextSteps"></div>

      <h3>输出文件</h3>
      <ul id="outputs"></ul>

      <h3>图片预览</h3>
      <div id="previews" class="previews"></div>
    </div>
  `;

  if (state.jobId) $('#jobIdInput').value = state.jobId;
  $('#loadJobBtn').addEventListener('click', () => {
    const jobId = $('#jobIdInput').value.trim();
    if (!jobId) return;
    setCurrentJobId(jobId);
    startPolling(jobId);
  });
  if (state.jobId) startPolling(state.jobId);
}

async function loadGseaCore(jobId) {
  const st = await fetchStatus(jobId);
  const item = (st.outputs || []).find(o => o.name === 'gsea_core_genes.json');
  // #region agent log
  __dbg('C', 'frontend/app.js:loadGseaCore', 'resolve_core_item', {
    jobId,
    outputsCount: Array.isArray(st.outputs) ? st.outputs.length : null,
    found: !!item,
    url: item?.url || null,
  });
  // #endregion
  if (!item) throw new Error('该 job 没有 gsea_core_genes.json（请确保主任务运行了 GSEA 且成功）');
  const resp = await fetch(item.url);
  if (!resp.ok) throw new Error('无法下载 gsea_core_genes.json');
  state.gseaCore = await resp.json();
  return state.gseaCore;
}

// 检查job是否有指定的输出文件
async function checkJobOutput(jobId, filename) {
  try {
    const st = await fetchStatus(jobId);
    const item = (st.outputs || []).find(o => o.name === filename);
    return !!item;
  } catch (e) {
    return false;
  }
}

// 显示文件检查状态
function updateFileCheckStatus(elementId, hasFile, filename) {
  const el = $(elementId);
  if (!el) return;
  if (hasFile) {
    el.textContent = `✓ 已找到 ${filename}`;
    el.className = 'text-success';
  } else {
    el.textContent = `✗ 未找到 ${filename}（请确保父任务已完成 DESeq2 分析）`;
    el.className = 'text-danger';
  }
}

function renderGseaView() {
  // #region agent log
  __dbg('A', 'frontend/app.js:renderGseaView', 'enter', { stateJobId: state.jobId || '', hash: window.location.hash || '' });
  // #endregion
  $('#view').innerHTML = `
    <div class="card">
      <h2>GSEA：通路富集结果</h2>
      <p class="hint">点击表格行选择通路后，本页会就地生成该通路的单通路详细 GSEA 图（plotthis::GSEAPlot），同时你也可以去热图页生成热图。</p>
      <div class="row">
        <label class="grow">
          <span>Job ID（需要包含 gsea_results.csv / gsea_core_genes.json）</span>
          <input type="text" id="jobIdInput" placeholder="粘贴 job_id" />
        </label>
        <button id="loadGseaBtn" class="secondary">加载通路</button>
      </div>
      <div id="gseaFileCheckStatus" style="margin: 0.5rem 0; font-size: 0.9em;"></div>
      <div id="selectedPathwayInfo" style="margin: 0.5rem 0;"></div>
      <div id="gseaTableWrap"></div>
      <hr />
      <h3>GSEA 可视化（Dotplot / Barplot）</h3>
      <div class="row" style="margin-bottom: 1rem;">
        <button id="switchToDotplot" class="secondary">Dotplot</button>
        <button id="switchToBarplot" class="secondary">Barplot</button>
      </div>
      <div id="gseaPlotPreview" style="margin-top: 1rem;"></div>
      <hr />
      <h3>单通路详细图（GSEAPlot）</h3>
      <div id="gseaSingleStatus" style="margin: 0.5rem 0;"></div>
      <div id="gseaSinglePreview" style="margin-top: 1rem;"></div>
    </div>
  `;

  if (state.jobId) $('#jobIdInput').value = state.jobId;

  let gseaAutoLoaded = false;
  let gseaWaitTimer = null;
  function stopGseaWait() {
    if (gseaWaitTimer) {
      clearInterval(gseaWaitTimer);
      gseaWaitTimer = null;
      // #region agent log
      __dbg('F', 'frontend/app.js:renderGseaView', 'wait_stopped', {});
      // #endregion
    }
  }

  function startGseaWait(jobId) {
    stopGseaWait();
    if (!jobId) return;
    $('#gseaFileCheckStatus').textContent = '⏳ 正在等待 GSEA 输出文件生成（会自动刷新）...';
    $('#gseaFileCheckStatus').className = 'text-info';
    // #region agent log
    __dbg('F', 'frontend/app.js:renderGseaView', 'wait_started', { jobId });
    // #endregion
    let tries = 0;
    gseaWaitTimer = setInterval(async () => {
      tries += 1;
      try {
        const st = await fetchStatus(jobId);
        const hasGseaResults = Array.isArray(st.outputs) ? st.outputs.some(o => o?.name === 'gsea_results.csv') : false;
        const hasCoreGenes = Array.isArray(st.outputs) ? st.outputs.some(o => o?.name === 'gsea_core_genes.json') : false;
        // #region agent log
        __dbg('F', 'frontend/app.js:renderGseaView/wait', 'tick', { jobId, tries, state: st?.state, hasGseaResults, hasCoreGenes });
        // #endregion
        if (hasGseaResults && hasCoreGenes) {
          stopGseaWait();
          if (!gseaAutoLoaded) {
            gseaAutoLoaded = true;
            loadAndRender().catch(err => {
              // #region agent log
              __dbg('D', 'frontend/app.js:renderGseaView/wait', 'auto_load_failed', { message: err?.message || String(err) });
              // #endregion
              console.error(err);
            });
          }
        } else {
          // 任务失败时也停止等待，避免无穷轮询
          if (st?.state === 'error') stopGseaWait();
          // 10分钟超时（约 300 次）
          if (tries > 300) stopGseaWait();
        }
      } catch (e) {
        // #region agent log
        __dbg('F', 'frontend/app.js:renderGseaView/wait', 'tick_failed', { jobId, tries, message: e?.message || String(e) });
        // #endregion
        if (tries > 20) stopGseaWait();
      }
    }, 2000);
  }

  // 检查GSEA文件
  async function checkGseaFiles() {
    const jobId = $('#jobIdInput').value.trim();
    if (!jobId) {
      $('#gseaFileCheckStatus').textContent = '';
      stopGseaWait();
      return false;
    }
    const hasGseaResults = await checkJobOutput(jobId, 'gsea_results.csv');
    const hasCoreGenes = await checkJobOutput(jobId, 'gsea_core_genes.json');
    // #region agent log
    __dbg('B', 'frontend/app.js:renderGseaView/checkGseaFiles', 'check_files', { jobId, hasGseaResults, hasCoreGenes });
    // #endregion
    if (hasGseaResults && hasCoreGenes) {
      updateFileCheckStatus('gseaFileCheckStatus', true, 'gsea_results.csv 和 gsea_core_genes.json');
      stopGseaWait();
      return true;
    } else {
      $('#gseaFileCheckStatus').textContent = '✗ 未找到 gsea_results.csv 或 gsea_core_genes.json（请确保父任务已完成 GSEA 分析）';
      $('#gseaFileCheckStatus').className = 'text-danger';
      // 自动等待（尤其是用户在任务还没跑完时提前进入本页）
      startGseaWait(jobId);
      return false;
    }
  }

  // 当输入框变化时检查
  $('#jobIdInput').addEventListener('input', () => {
    checkGseaFiles().then(hasFiles => {
      if (hasFiles && !gseaAutoLoaded) {
        gseaAutoLoaded = true;
        loadAndRender().catch(err => alert(err.message || String(err)));
      }
    }).catch(console.error);
  });

  // 如果已有jobId，自动检查
  if (state.jobId) {
    checkGseaFiles().catch(console.error);
  }

  async function loadAndRender() {
    const jobId = $('#jobIdInput').value.trim();
    if (!jobId) {
      alert('请输入 Job ID');
      return;
    }
    // #region agent log
    __dbg('A', 'frontend/app.js:renderGseaView/loadAndRender', 'start', { jobId });
    // #endregion
    
    // 先检查文件
    const hasFiles = await checkGseaFiles();
    if (!hasFiles) {
      alert('该 job 缺少必要的 GSEA 输出文件。请确保父任务已完成 GSEA 分析。');
      return;
    }

    setCurrentJobId(jobId);
    const core = await loadGseaCore(jobId);
    // #region agent log
    __dbg('D', 'frontend/app.js:renderGseaView/loadAndRender', 'core_loaded', {
      jobId,
      coreLen: Array.isArray(core) ? core.length : null,
      firstKeys: Array.isArray(core) && core[0] ? Object.keys(core[0]) : null,
    });
    // #endregion
    // render simple table
    const rows = core.map((r, idx) => `
      <tr data-idx="${idx}" style="cursor: pointer;">
        <td class="mono">${r.ID ?? ''}</td>
        <td>${r.Description ?? ''}</td>
        <td>${r.NES ?? ''}</td>
        <td>${r['p.adjust'] ?? ''}</td>
        <td>${(r.core_genes || []).length}</td>
      </tr>
    `).join('');

    $('#gseaTableWrap').innerHTML = `
      <table class="table">
        <thead><tr><th>ID</th><th>Description</th><th>NES</th><th>p.adjust</th><th>#core</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    `;

    // 行点击：只选择，不触发派生任务
    for (const tr of $('#gseaTableWrap').querySelectorAll('tbody tr')) {
      tr.addEventListener('click', () => {
        // 清除之前的选中样式
        for (const t of $('#gseaTableWrap').querySelectorAll('tbody tr')) {
          t.style.backgroundColor = '';
          t.style.boxShadow = '';
        }
        tr.style.backgroundColor = 'rgba(255, 0, 255, 0.15)';
        tr.style.boxShadow = 'inset 0 0 20px rgba(255, 0, 255, 0.1)';
        
        const idx = Number(tr.getAttribute('data-idx'));
        const row = core[idx];
        state.selectedPathway = row;
        saveState();
        
        // 显示选中信息并提供跳转按钮
        $('#selectedPathwayInfo').innerHTML = `
          <div class="alert alert-success">
            <strong>✓ 已选择通路：</strong>${row.Description || row.ID}<br>
            <strong>核心基因数：</strong>${(row.core_genes || []).length}<br>
            <strong>💡 下一步：</strong>
            <button id="gotoHeatmap" class="button" style="margin-top: 0.5rem;">去热图页生成热图 →</button>
            或查看下方的<strong>单通路详细图</strong>
          </div>
        `;
        
        $('#gotoHeatmap').addEventListener('click', () => {
          window.location.hash = '#/heatmap';
        });

        // 生成并预览单通路详细 GSEA 图（就地，不创建新 job）
        generateSingleGseaPlot(jobId, row).catch(err => {
          $('#gseaSingleStatus').innerHTML = `<p class="text-danger">单通路图生成失败：${err.message || String(err)}</p>`;
        });
      });
    }
    
    // 加载 GSEA 图片（dotplot / barplot）
    loadGseaPlots(jobId);
  }

  async function generateSingleGseaPlot(jobId, pathwayRow) {
    $('#gseaSingleStatus').innerHTML = '<p class="text-info">正在生成单通路详细图…</p>';
    $('#gseaSinglePreview').innerHTML = '';

    const fd = new FormData();
    if (pathwayRow.ID) fd.set('pathway_id', pathwayRow.ID);
    if (pathwayRow.Description) fd.set('pathway_description', pathwayRow.Description);

    const resp = await fetch(`/api/jobs/${encodeURIComponent(jobId)}/gsea_single_plot_inplace`, {
      method: 'POST',
      body: fd,
    });
    const data = await resp.json();
    if (!resp.ok) throw new Error(data.detail || '单通路图生成请求失败');

    // 轮询 extra.gsea_single_plot
    let attempts = 0;
    const poll = async () => {
      if (attempts++ > 40) {
        $('#gseaSingleStatus').innerHTML = '<p class="text-warning">生成超时，请稍后刷新或查看任务&结果页输出。</p>';
        return;
      }
      const st = await fetchStatus(jobId);
      const act = st.extra?.gsea_single_plot;
      if (act?.state === 'success') {
        const outName = act.output || '';
        $('#gseaSingleStatus').innerHTML = `<p class="text-success">${act.message || '单通路图生成完成'}</p>`;
        if (outName) {
          const url = `/api/jobs/${encodeURIComponent(jobId)}/outputs/${encodeURIComponent(outName)}?t=${Date.now()}`;
          const img = document.createElement('img');
          img.src = url;
          img.alt = 'GSEA single pathway';
          img.style.maxWidth = '100%';
          img.style.height = 'auto';
          img.style.cursor = 'zoom-in';
          img.addEventListener('click', () => showImageModal(url, 'GSEA single pathway'));
          $('#gseaSinglePreview').innerHTML = '';
          $('#gseaSinglePreview').appendChild(img);
        } else {
          $('#gseaSinglePreview').innerHTML = '<p class="text-warning">未返回输出文件名，请到任务&结果页查看。</p>';
        }
        return;
      }
      if (act?.state === 'error') {
        $('#gseaSingleStatus').innerHTML = `<p class="text-danger">${act.message || '单通路图生成失败'}</p>`;
        return;
      }
      setTimeout(poll, 1500);
    };
    setTimeout(poll, 1200);
  }
  
  // GSEA 图片显示状态
  let currentGseaPlot = 'dotplot';
  let gseaPlotsInitialized = false;

  // 显示 GSEA 图片（dotplot 或 barplot）
  function showGseaPlot(jobId, plotType) {
    const url = `/api/jobs/${encodeURIComponent(jobId)}/outputs/gsea_${plotType}.png?t=${Date.now()}`;
    const img = document.createElement('img');
    img.src = url;
    img.alt = `GSEA ${plotType}`;
    img.style.maxWidth = '100%';
    img.style.height = 'auto';
    img.style.cursor = 'zoom-in';
    img.addEventListener('click', () => showImageModal(url, `GSEA ${plotType}`));
    img.onerror = () => {
      $('#gseaPlotPreview').innerHTML = `<p class="text-warning">暂无 ${plotType} 图片，请先运行 GSEA 分析或点击"加载通路"</p>`;
    };
    $('#gseaPlotPreview').innerHTML = '';
    $('#gseaPlotPreview').appendChild(img);
  }

  // 初始化 GSEA 图片切换按钮（只绑定一次）
  function initGseaPlotButtons(jobId) {
    if (gseaPlotsInitialized) return;
    gseaPlotsInitialized = true;
    
    $('#switchToDotplot').addEventListener('click', () => {
      currentGseaPlot = 'dotplot';
      const jid = $('#jobIdInput').value.trim();
      if (jid) showGseaPlot(jid, 'dotplot');
    });
    
    $('#switchToBarplot').addEventListener('click', () => {
      currentGseaPlot = 'barplot';
      const jid = $('#jobIdInput').value.trim();
      if (jid) showGseaPlot(jid, 'barplot');
    });
  }

  // 加载 GSEA 图片
  function loadGseaPlots(jobId) {
    initGseaPlotButtons(jobId);
    showGseaPlot(jobId, currentGseaPlot);
  }

  // 加载已有的单通路图
  async function loadExistingSinglePlot(jobId) {
    try {
      const st = await fetchStatus(jobId);
      const act = st.extra?.gsea_single_plot;
      if (act?.state === 'success' && act?.output) {
        const url = `/api/jobs/${encodeURIComponent(jobId)}/outputs/${encodeURIComponent(act.output)}?t=${Date.now()}`;
        const img = document.createElement('img');
        img.src = url;
        img.alt = 'GSEA single pathway';
        img.style.maxWidth = '100%';
        img.style.height = 'auto';
        img.style.cursor = 'zoom-in';
        img.addEventListener('click', () => showImageModal(url, 'GSEA single pathway'));
        $('#gseaSingleStatus').innerHTML = `<p class="text-success">✓ 已有单通路图（${act.pathway_description || act.pathway_id || ''}）</p>`;
        $('#gseaSinglePreview').innerHTML = '';
        $('#gseaSinglePreview').appendChild(img);
      }
    } catch (e) {
      console.warn('加载已有单通路图失败:', e);
    }
  }

  // 绑定加载按钮事件
  $('#loadGseaBtn').addEventListener('click', () => loadAndRender().catch(err => alert(err.message || String(err))));
  
  // 初始化按钮绑定
  initGseaPlotButtons();
  
  // 页面加载时自动显示已有的图片
  if (state.jobId) {
    // 立即显示图片（不等待）
    loadGseaPlots(state.jobId);
    loadExistingSinglePlot(state.jobId).catch(console.error);
    
    // 然后检查并加载通路表格
    setTimeout(() => {
      // #region agent log
      __dbg('A', 'frontend/app.js:renderGseaView', 'auto_load_timer_fired', {
        stateJobId: state.jobId || '',
        inputJobId: $('#jobIdInput')?.value?.trim?.() || '',
      });
      // #endregion
      checkGseaFiles().then(hasFiles => {
        if (hasFiles) {
          loadAndRender().catch(err => {
            // #region agent log
            __dbg('D', 'frontend/app.js:renderGseaView', 'auto_load_failed', { message: err?.message || String(err) });
            // #endregion
            console.error(err);
          });
        }
      }).catch(err => {
        // #region agent log
        __dbg('D', 'frontend/app.js:renderGseaView', 'checkGseaFiles_failed', { message: err?.message || String(err) });
        // #endregion
        console.error(err);
      });
    }, 100);
  }
}

function renderHeatmapView() {
  $('#view').innerHTML = `
    <div class="card">
      <h2>热图：从 GSEA 通路生成</h2>
      <p class="hint">基于 GSEA 页面选择的通路，在当前 job 下就地生成/覆盖 heatmap.png（不创建新 job）。</p>
      <div class="row">
        <label class="grow">
          <span>Job ID（当前分析任务）</span>
          <input type="text" id="heatmapJobId" placeholder="粘贴 job_id" />
        </label>
        <button id="loadExistingHeatmap" class="secondary">加载已有热图</button>
      </div>
      <div id="heatmapSelectedPathway" style="margin: 0.5rem 0;"></div>
      <div class="row">
        <button id="generateHeatmap" class="button">生成热图</button>
      </div>
      <div id="heatmapStatus" style="margin: 0.5rem 0;"></div>
      <h3>热图预览</h3>
      <div id="heatmapPreview" style="margin-top: 1rem;"></div>
    </div>
  `;
  
  if (state.jobId) $('#heatmapJobId').value = state.jobId;
  
  // 显示当前选中的通路
  if (state.selectedPathway) {
    $('#heatmapSelectedPathway').innerHTML = `
      <div class="alert alert-info">
        <strong>当前选中通路：</strong>${state.selectedPathway.Description || state.selectedPathway.ID}<br>
        <strong>核心基因数：</strong>${(state.selectedPathway.core_genes || []).length}
      </div>
    `;
  } else {
    $('#heatmapSelectedPathway').innerHTML = `
      <div class="alert alert-warning">
        尚未选择通路。请先到 <a href="#/gsea">GSEA 页面</a> 选择一个通路。
      </div>
    `;
  }

  // 加载已有热图函数
  async function loadExistingHeatmap() {
    const jobId = $('#heatmapJobId').value.trim();
    if (!jobId) return;
    
    const hasHeatmap = await checkJobOutput(jobId, 'heatmap.png');
    if (hasHeatmap) {
      const imgUrl = `/api/jobs/${encodeURIComponent(jobId)}/outputs/heatmap.png?t=${Date.now()}`;
      const img = document.createElement('img');
      img.src = imgUrl;
      img.alt = 'Heatmap';
      img.style.maxWidth = '100%';
      img.style.height = 'auto';
      img.style.cursor = 'zoom-in';
      img.addEventListener('click', () => showImageModal(imgUrl, 'Heatmap'));
      img.onerror = () => {
        $('#heatmapPreview').innerHTML = '<p class="text-warning">加载热图失败</p>';
      };
      $('#heatmapStatus').innerHTML = '<p class="text-success">✓ 已找到热图文件</p>';
      $('#heatmapPreview').innerHTML = '';
      $('#heatmapPreview').appendChild(img);
    } else {
      $('#heatmapStatus').innerHTML = '<p class="text-info">暂无热图，请先生成</p>';
      $('#heatmapPreview').innerHTML = '';
    }
  }

  // 点击加载按钮
  $('#loadExistingHeatmap').addEventListener('click', () => {
    loadExistingHeatmap().catch(err => {
      $('#heatmapStatus').innerHTML = `<p class="text-danger">加载失败: ${err.message}</p>`;
    });
  });

  // 如果已有 jobId，自动加载已有热图
  if (state.jobId) {
    setTimeout(() => loadExistingHeatmap().catch(console.error), 100);
  }
  
  $('#generateHeatmap').addEventListener('click', async () => {
    const jobId = $('#heatmapJobId').value.trim();
    if (!jobId) {
      alert('请输入 Job ID');
      return;
    }
    
    if (!state.selectedPathway) {
      alert('请先到 GSEA 页面选择一个通路');
      return;
    }
    
    $('#generateHeatmap').disabled = true;
    $('#generateHeatmap').textContent = '生成中...';
    $('#heatmapStatus').innerHTML = '<p class="text-info">正在生成热图，请稍候...</p>';
    
    try {
      const fd = new FormData();
      if (state.selectedPathway.ID) fd.set('pathway_id', state.selectedPathway.ID);
      if (state.selectedPathway.Description) fd.set('pathway_description', state.selectedPathway.Description);
      
      const resp = await fetch(`/api/jobs/${encodeURIComponent(jobId)}/heatmap_from_gsea_inplace`, {
        method: 'POST',
        body: fd
      });
      
      const data = await resp.json();
      if (!resp.ok) throw new Error(data.detail || '生成失败');
      
      $('#heatmapStatus').innerHTML = '<p class="text-success">热图生成中，正在等待...</p>';
      
      // 轮询查看状态（检查 status.json 的 extra.heatmap_from_gsea）
      let attempts = 0;
      const checkStatus = async () => {
        if (attempts++ > 30) {
          $('#heatmapStatus').innerHTML = '<p class="text-warning">超时，请到任务&结果页查看</p>';
          return;
        }
        
        const st = await fetchStatus(jobId);
        const hm = st.extra?.heatmap_from_gsea;
        
        if (hm && hm.state === 'success') {
          $('#heatmapStatus').innerHTML = `<p class="text-success">${hm.message || '热图生成成功'}</p>`;
          // 显示预览
          const imgUrl = `/api/jobs/${encodeURIComponent(jobId)}/outputs/heatmap.png?t=${Date.now()}`;
          const img = document.createElement('img');
          img.src = imgUrl;
          img.alt = 'Heatmap';
          img.style.maxWidth = '100%';
          img.style.height = 'auto';
          img.style.cursor = 'zoom-in';
          img.addEventListener('click', () => showImageModal(imgUrl, 'Heatmap'));
          $('#heatmapPreview').innerHTML = '';
          $('#heatmapPreview').appendChild(img);
        } else if (hm && hm.state === 'error') {
          $('#heatmapStatus').innerHTML = `<p class="text-danger">错误：${hm.message || '生成失败'}</p>`;
        } else {
          setTimeout(checkStatus, 2000);
        }
      };
      
      setTimeout(checkStatus, 2000);
      
    } catch (e) {
      $('#heatmapStatus').innerHTML = `<p class="text-danger">错误：${e.message || String(e)}</p>`;
    } finally {
      $('#generateHeatmap').disabled = false;
      $('#generateHeatmap').textContent = '生成热图';
    }
  });
}


function renderVolcanoView() {
  $('#view').innerHTML = `
    <div class="card">
      <h2>火山图增强（就地生成）</h2>
      <p class="hint">基于当前 job 的 deseq2_results.csv 重新出图：TopN 标注 + 可选标记基因集。输出写回同一 job 的 output/（不创建新 job）。</p>
      <div class="row">
        <label class="grow">
          <span>Job ID（需要包含 deseq2_results.csv）</span>
          <input type="text" id="parentJobId" placeholder="粘贴 job_id" />
        </label>
        <button id="loadExistingVolcano" class="secondary">加载已有火山图</button>
      </div>
      <div id="fileCheckStatus" style="margin: 0.5rem 0; font-size: 0.9em;"></div>
      <div class="row">
        <label>
          <span>Top N 标注</span>
          <input type="number" id="topN" value="10" min="0" max="200" />
        </label>
        <label class="grow">
          <span>标记基因（可选，逗号/空格/换行分隔）</span>
          <input type="text" id="markGenes" placeholder="TP53,BRCA1,EGFR" />
        </label>
      </div>
      <div class="row">
        <button id="runVolcanoBtn">生成火山图</button>
        <button id="importCoreBtn" class="secondary">从已选 GSEA 通路导入 core genes</button>
      </div>
      <div id="volcanoInplaceStatus" style="margin: 0.5rem 0;"></div>
      <h3>火山图预览</h3>
      <div id="volcanoInplacePreview" style="margin-top: 1rem;"></div>
    </div>
  `;
  if (state.jobId) $('#parentJobId').value = state.jobId;

  // 加载已有火山图函数
  async function loadExistingVolcano() {
    const jobId = $('#parentJobId').value.trim();
    if (!jobId) return;
    
    // 优先检查 volcano_custom.png，其次检查 volcano_plot.png
    let imgName = null;
    if (await checkJobOutput(jobId, 'volcano_custom.png')) {
      imgName = 'volcano_custom.png';
    } else if (await checkJobOutput(jobId, 'volcano_plot.png')) {
      imgName = 'volcano_plot.png';
    }
    
    if (imgName) {
      const imgUrl = `/api/jobs/${encodeURIComponent(jobId)}/outputs/${imgName}?t=${Date.now()}`;
      const img = document.createElement('img');
      img.src = imgUrl;
      img.alt = 'Volcano plot';
      img.style.maxWidth = '100%';
      img.style.height = 'auto';
      img.style.cursor = 'zoom-in';
      img.addEventListener('click', () => showImageModal(imgUrl, 'Volcano plot'));
      img.onerror = () => {
        $('#volcanoInplacePreview').innerHTML = '<p class="text-warning">加载火山图失败</p>';
      };
      $('#volcanoInplaceStatus').innerHTML = `<p class="text-success">✓ 已找到火山图 (${imgName})</p>`;
      $('#volcanoInplacePreview').innerHTML = '';
      $('#volcanoInplacePreview').appendChild(img);
    } else {
      $('#volcanoInplaceStatus').innerHTML = '<p class="text-info">暂无火山图，请先生成</p>';
      $('#volcanoInplacePreview').innerHTML = '';
    }
  }

  // 点击加载按钮
  $('#loadExistingVolcano').addEventListener('click', () => {
    loadExistingVolcano().catch(err => {
      $('#volcanoInplaceStatus').innerHTML = `<p class="text-danger">加载失败: ${err.message}</p>`;
    });
  });

  // 如果已有 jobId，自动加载已有火山图
  if (state.jobId) {
    setTimeout(() => loadExistingVolcano().catch(console.error), 100);
  }

  // 检查文件函数
  async function checkParentJob() {
    const parent = $('#parentJobId').value.trim();
    if (!parent) {
      $('#fileCheckStatus').textContent = '';
      return false;
    }
    const hasFile = await checkJobOutput(parent, 'deseq2_results.csv');
    updateFileCheckStatus('fileCheckStatus', hasFile, 'deseq2_results.csv');
    return hasFile;
  }

  // 当输入框变化时检查
  $('#parentJobId').addEventListener('input', () => {
    checkParentJob().catch(console.error);
  });

  // 如果已有jobId，自动检查
  if (state.jobId) {
    checkParentJob().catch(console.error);
  }

  $('#importCoreBtn').addEventListener('click', () => {
    if (!state.selectedPathway || !state.selectedPathway.core_genes) {
      alert('尚未在 GSEA 页面选择通路');
      return;
    }
    $('#markGenes').value = (state.selectedPathway.core_genes || []).join(',');
  });

  $('#runVolcanoBtn').addEventListener('click', async () => {
    const jobId = $('#parentJobId').value.trim();
    if (!jobId) {
      alert('请输入 Job ID');
      return;
    }
    
    // 先检查文件是否存在
    const hasFile = await checkJobOutput(jobId, 'deseq2_results.csv');
    if (!hasFile) {
      alert('该 job 缺少 deseq2_results.csv 文件。请确保该任务已完成 DESeq2 分析。');
      return;
    }

    const fd = new FormData();
    fd.set('top_n', String(Number($('#topN').value || 10)));
    fd.set('mark_genes', $('#markGenes').value || '');
    
    $('#runVolcanoBtn').disabled = true;
    $('#runVolcanoBtn').textContent = '提交中...';
    
    try {
      $('#volcanoInplaceStatus').innerHTML = '<p class="text-info">正在生成火山图…</p>';
      $('#volcanoInplacePreview').innerHTML = '';

      const resp = await fetch(`/api/jobs/${encodeURIComponent(jobId)}/volcano_inplace`, { method: 'POST', body: fd });
      const data = await resp.json();
      if (!resp.ok) {
        alert(data.detail || '生成火山图失败');
        return;
      }

      // 轮询 extra.volcano_inplace
      let attempts = 0;
      const poll = async () => {
        if (attempts++ > 40) {
          $('#volcanoInplaceStatus').innerHTML = '<p class="text-warning">生成超时，请到任务&结果页查看输出。</p>';
          return;
        }
        const st = await fetchStatus(jobId);
        const act = st.extra?.volcano_inplace;
        if (act?.state === 'success') {
          $('#volcanoInplaceStatus').innerHTML = `<p class="text-success">${act.message || '火山图生成完成'}（输出已写入同一 job）</p>`;
          const imgUrl = `/api/jobs/${encodeURIComponent(jobId)}/outputs/volcano_custom.png?t=${Date.now()}`;
          const img = document.createElement('img');
          img.src = imgUrl;
          img.alt = 'Volcano custom';
          img.style.maxWidth = '100%';
          img.style.height = 'auto';
          img.style.cursor = 'zoom-in';
          img.addEventListener('click', () => showImageModal(imgUrl, 'Volcano custom'));
          $('#volcanoInplacePreview').innerHTML = '';
          $('#volcanoInplacePreview').appendChild(img);
          return;
        }
        if (act?.state === 'error') {
          $('#volcanoInplaceStatus').innerHTML = `<p class="text-danger">${act.message || '火山图生成失败'}</p>`;
          return;
        }
        setTimeout(poll, 1500);
      };
      setTimeout(poll, 1200);
    } catch (e) {
      alert(e.message || String(e));
    } finally {
      $('#runVolcanoBtn').disabled = false;
      $('#runVolcanoBtn').textContent = '生成火山图';
    }
  });
}

function setActiveNav(route) {
  for (const a of document.querySelectorAll('.navItem')) {
    a.classList.toggle('active', a.getAttribute('data-route') === route);
  }
}

function route() {
  const hash = window.location.hash || '#/submit';
  const routePath = hash.replace(/^#/, '') || '/submit';
  // 离开“任务&结果”页时停止轮询，避免在其它页面持续更新不存在的 DOM
  if (routePath !== '/jobs') stopPolling();
  setActiveNav(routePath);
  if (routePath === '/submit') return renderSubmitView();
  if (routePath === '/jobs') return renderJobsView();
  if (routePath === '/gsea') return renderGseaView();
  if (routePath === '/heatmap') return renderHeatmapView();
  if (routePath === '/volcano') return renderVolcanoView();
  return renderSubmitView();
}

// 初始化：加载保存的状态
loadState();

// 复制 Job ID 功能
function setupCopyButton() {
  const btn = document.querySelector('#copyJobIdBtn');
  if (btn) {
    btn.addEventListener('click', async () => {
      if (!state.jobId) {
        alert('当前没有活动的 Job ID');
        return;
      }
      try {
        await navigator.clipboard.writeText(state.jobId);
        const oldText = btn.textContent;
        btn.textContent = '✓ 已复制';
        btn.style.background = 'linear-gradient(135deg, rgba(22,163,74,0.95), rgba(34,197,94,0.9))';
        setTimeout(() => {
          btn.textContent = oldText;
          btn.style.background = '';
        }, 1500);
      } catch (e) {
        // 降级方案：使用旧方法
        const input = document.createElement('input');
        input.value = state.jobId;
        document.body.appendChild(input);
        input.select();
        document.execCommand('copy');
        document.body.removeChild(input);
        const oldText = btn.textContent;
        btn.textContent = '✓ 已复制';
        setTimeout(() => btn.textContent = oldText, 1500);
      }
    });
  }
}

// DOM 加载完成后设置
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', setupCopyButton);
} else {
  setupCopyButton();
}

window.addEventListener('hashchange', route);
route();
