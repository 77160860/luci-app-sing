'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require uci';

function method(name, params, timeout) {
  return rpc.declare({
    object: 'luci.sing-box',
    method: name,
    params: params || [],
    expect: { '': {} },
    timeout: timeout || 30000,
  });
}

const api = {
  status: method('status'),
  read: method('read'),
  logs: method('logs'),
  cache: method('cache'),
  save: method('save', ['content', 'revision']),
  check: method('check', ['content']),
  action: method('action', ['name', 'revision']),
  autostart: method('autostart', ['enabled']),
  updateCore: method('update_core', ['url'], 60000),
};

const messages = {
  apply_failed: '配置已保存，但服务未能启动，请检查日志并修改配置',
  operation_interrupted: '操作已中断，请检查配置和服务状态',
  config_path_invalid: 'sing-box.main.conffile 必须是绝对路径',
  workdir_invalid: 'sing-box.main.workdir 必须是绝对路径',
  config_not_regular: '配置路径不是普通文件',
  config_symlink: '不支持符号链接配置文件',
  service_missing: '缺少 sing-box 可执行文件或启动脚本',
  config_missing: '没有已保存的配置',
  config_too_large: '配置大小超过 64 KiB',
  check_failed: '配置校验失败（退出码 %s）',
  check_prepare_failed: '无法准备临时校验文件',
  operation_running: '正在执行：%s',
  check_passed: '配置文件通过 sing-box 校验',
  config_applied: '配置已应用，服务运行中。',
  start_failed: '服务未能启动，请检查日志',
  service_running: '服务正在运行',
  stop_failed: '服务未能停止',
  service_stopped: '服务已停止',
  action_unknown: '未知操作',
  directories_failed: '无法初始化面板目录',
  logs_failed: '无法读取系统日志（logread 失败或超时）',
  request_invalid: '请求无效',
  content_invalid: '配置内容必须是字符串',
  operation_busy: '另一项操作正在执行',
  config_save_failed: '无法保存配置文件',
  config_saved: '配置文件已保存；服务未重启',
  config_changed: '配置文件已改变，请重新加载后再保存或应用',
  operation_queued: '操作已加入队列',
  enabled_invalid: 'enabled 必须是布尔值',
  autostart_updated: '开机启动设置已更新',
  autostart_failed: '无法更改开机启动设置',
  method_unknown: '未知方法',
  core_updated: '核心更新成功，服务已重启',
  download_failed: '核心下载失败，请检查下载地址和网络连通性',
  url_invalid: '下载地址无效，请填写正确的 URL',
  service_status_failed: '无法确认服务进程状态，操作已中止',
  cache_disabled: '已保存配置未启用缓存文件，无需清理',
  cache_missing: '缓存文件不存在，无需清理',
  cache_config_invalid: '无法读取有效配置，不能确定缓存文件',
  cache_workdir_unsafe: '仅支持无符号链接的专用工作目录：/etc/sing-box、/usr/share/sing-box、/var/lib/sing-box、/tmp/sing-box',
  cache_path_unsafe: '缓存路径不安全：必须是工作目录内的普通文件，不能是配置文件、链接或挂载路径',
  cache_inspect_failed: '无法读取缓存文件或挂载信息，请检查系统工具和文件访问权限',
  cache_changed: '配置或缓存文件已改变，请重新打开确认窗口',
  cache_remove_failed: '清理缓存失败，服务保持停止',
  cache_start_failed: '缓存已清理，但服务未能启动，请检查日志；旧缓存未备份',
  cache_reset: '缓存已清理，服务保持停止',
  cache_reset_start: '缓存已清理，服务已重新启动',
};

const actions = {
  validate: '校验',
  apply: '应用',
  start: '启动',
  stop: '停止',
  restart: '重启',
  cache_reset: '清理缓存',
  cache_reset_start: '清理缓存并启动',
};

// 提示条配色跟随触发它的按钮
const toneColors = {
  apply: '#16a34a',
  warning: '#d97706',
  negative: '#dc2626',
  action: '#2563eb',
  neutral: '#6b7280',
  reset: '#6b7280',
};

function message(result) {
  const value = result.code === 'operation_running' ? actions[result.argument] : result.argument;
  return Object.prototype.hasOwnProperty.call(messages, result.code)
    ? messages[result.code].replace('%s', () => (value == null ? '' : String(value)))
    : result.message || '后端返回无效响应';
}

function checked(result) {
  if (!result || !result.ok) throw new Error(result ? (result.details || message(result)) : '后端返回无效响应');
  return result;
}

function field(title, node) {
  return E('div', { class: 'cbi-value' }, [
    E('div', { class: 'cbi-value-title' }, title),
    E('div', { class: 'cbi-value-field' }, node),
  ]);
}

return view.extend({
  handleSaveApply: null,
  handleSave: null,
  handleReset: null,

  load() {
    return Promise.all([
      api.status().then(checked),
      api.read(),
      uci.load('sing-box'),
    ]);
  },

  notify(text, error, details, tone) {
    if (this.notification) this.notification.remove();
    const content = E('div', {}, [E('p', {}, text)]);
    if (details) content.appendChild(E('pre', { class: 'sing-box-output' }, details));
    const node = error
      ? ui.addNotification(null, content, 'error')
      : ui.addTimeLimitedNotification(null, content, 5000, 'info');
    const color = toneColors[tone || this.tone] || (error ? toneColors.negative : toneColors.action);
    if (node && node.style) {
      node.style.setProperty('border-left', '4px solid ' + color, 'important');
      node.style.setProperty('background-color', color + '22', 'important');
    }
    this.notification = node;
  },

  updateControls() {
    const busy = !!(this.localBusy || this.status.busy);
    this.buttons.forEach(({ node, write, config }) => {
      node.disabled = busy || (write && !this.writable) || (config && !this.loaded);
    });
    this.boot.disabled = busy || !this.writable;
    this.editor.readOnly = busy || !this.writable || !this.loaded;
  },

  async run(fn, write, tone) {
    if (this.localBusy || this.status.busy || (write && !this.writable)) return;
    this.tone = tone;
    this.localBusy = true;
    this.updateControls();
    let result;
    try {
      result = await fn();
    } catch (error) {
      this.notify(error.message, true);
    } finally {
      this.localBusy = false;
      try {
        await this.refresh();
      } catch (error) {
        this.notify(error.message, true);
      }
      this.updateControls();
    }
    return result;
  },

  button(label, fn, style, write = true, config = false) {
    const node = E(
      'button',
      {
        type: 'button',
        class: 'cbi-button cbi-button-' + (style || 'action'),
        click: () => this.run(fn, write, style || 'action'),
      },
      label,
    );
    this.buttons.push({ node, write, config });
    return node;
  },

  updateDirty() {
    let text, color;
    if (!this.loaded) {
      text = '配置读取失败，请修复后重载。';
      color = toneColors.negative;
    } else if (this.status.revision && this.status.revision !== this.revision) {
      text = messages.config_changed;
      color = toneColors.warning;
    } else if (this.editor.value !== this.savedText) {
      text = '有未保存的修改，请校验配置后保存并应用!';
      color = toneColors.warning;
    } else {
      text = '编辑器内容与配置文件一致。';
      color = toneColors.apply;
    }
    this.dirty.textContent = text;
    this.dirty.style.setProperty('color', color, 'important');
    this.dirty.style.setProperty('font-weight', '700', 'important');
  },

  setConfig(result) {
    checked(result);
    this.savedText = result.content || '';
    this.editor.value = this.savedText;
    this.revision = result.revision;
    this.loaded = true;
    this.updateDirty();
  },

  content() {
    if (!this.loaded) throw new Error('请先重载配置');
    if (new Blob([this.editor.value]).size > 65536) throw new Error(messages.config_too_large);
    return this.editor.value;
  },

  async queue(name, revision) {
    checked(await api.action(name, revision || ''));
    this.status.busy = true;
    this.lastJob = null;
  },

  async showCacheReset() {
    this.notify('正在清理缓存并重启服务，请稍候...');
    const plan = await api.cache();
    if (!plan || !plan.ok) {
      throw new Error(plan ? message(plan) : '后端返回无效响应');
    }
    await this.queue('cache_reset_start', plan.token);
  },

  async save() {
    const content = this.content();
    const result = checked(await api.save(content, this.revision));
    this.savedText = content;
    this.revision = result.revision;
    this.status.revision = result.revision;
    this.updateDirty();
    await this.queue('apply', result.revision);
    this.showTab('overview');
  },

  showTab(name) {
    const group = this.panes;
    if (!group) return;
    const menu = group.previousElementSibling;
    if (menu && menu.classList && menu.classList.contains('cbi-tabmenu')) {
      menu.querySelectorAll('[data-tab]').forEach(tab => {
        tab.classList.remove('cbi-tab');
        tab.classList.remove('cbi-tab-disabled');
        tab.classList.add(tab.getAttribute('data-tab') === name ? 'cbi-tab' : 'cbi-tab-disabled');
      });
    }
    Array.prototype.forEach.call(group.childNodes, pane => {
      if (!pane.getAttribute || pane.getAttribute('data-tab') == null) return;
      const active = pane.getAttribute('data-tab') === name;
      pane.setAttribute('data-tab-active', active ? 'true' : 'false');
      if (active) pane.dispatchEvent(new CustomEvent('cbi-tab-active', { detail: { tab: name } }));
    });
  },

  setCheckNotice(text, error, details, timeout) {
    const notice = this.checkNotice;
    if (!notice) return;
    if (this.checkNoticeTimer) {
      clearTimeout(this.checkNoticeTimer);
      this.checkNoticeTimer = null;
    }
    const color = toneColors[this.tone] || (error ? toneColors.negative : toneColors.action);
    notice.textContent = '';
    notice.appendChild(E('p', { style: 'margin:0' }, text));
    if (details) notice.appendChild(E('pre', { class: 'sing-box-output' }, details));
    notice.style.setProperty('border-left', '4px solid ' + color, 'important');
    notice.style.setProperty('background-color', color + '22', 'important');
    notice.hidden = false;
    if (timeout) {
      this.checkNoticeTimer = setTimeout(() => {
        notice.hidden = true;
        this.checkNoticeTimer = null;
      }, timeout);
    }
  },

  updateStatus(status) {
    this.status = status;
    this.runtime.textContent = status.running ? '运行中 · PID ' + status.pid : '已停止';
    this.version.textContent = status.version || '未检测到内核';
    this.path.textContent = status.config || '未配置';
    if (!this.localBusy) {
      this.boot.checked = !!status.autostart;
      if (this.bootText) this.bootText.textContent = this.boot.checked ? '已开启' : '未开启';
    }
    this.problem.textContent = status.error_code ? message({ code: status.error_code }) : status.error || '';
    this.problem.hidden = !this.problem.textContent;
    if (status.job && status.job !== this.lastJob) {
      this.lastJob = status.job;
      try {
        const job = JSON.parse(status.job);
        if (job.state === 'error' || job.state === 'success') {
          if (this.pendingCheck) {
            this.pendingCheck = false;
            this.setCheckNotice(message(job), job.state === 'error', job.details, 5000);
          } else {
            this.notify(message(job), job.state === 'error', job.details);
          }
        }
      } catch {
        this.notify('无法解析后台操作状态', true);
      }
    }
    this.updateDirty();
    this.updateControls();
  },

  async refresh() {
    this.updateStatus(checked(await api.status()));
  },

  async refreshLogs() {
    if (this.loadingLogs) return;
    this.loadingLogs = true;
    try {
      const result = checked(await api.logs());
      this.logHint.textContent =
        result.mode === 'file'
          ? '日志写入文件：' + result.output + '。下方仅显示系统日志。'
          : result.mode === 'disabled'
            ? '运行日志已关闭，下方可能是历史日志。'
            : result.log_stderr === false
              ? 'log_stderr 已关闭，日志收集取决于设备启动脚本。'
              : '';
      // oxlint-disable-next-line no-control-regex -- Strip ANSI color codes from system logs.
      const ansi = /(?:\x1b\[|\x9b)[0-9;:]*m/g;
      this.logs.value = (result.content || '').replace(ansi, '') || '暂无 sing-box 系统日志。';
      this.logUpdated.textContent = '更新于 ' + new Date().toLocaleTimeString('zh-CN');
    } catch (error) {
      this.logHint.textContent = '日志刷新失败：' + error.message;
    } finally {
      this.loadingLogs = false;
    }
  },

  render(data) {
    this.writable = L.hasViewPermission() === true;
    this.status = data[0];
    this.buttons = [];
    this.loaded = false;
    this.localBusy = false;
    this.runtime = E('strong');
    this.version = E('span');
    this.path = E('code');
    this.problem = E('p', { class: 'cbi-section-descr', role: 'alert', hidden: true });
    this.dirty = E('div', { class: 'cbi-section-descr sing-box-dirty', 'aria-live': 'polite' });
    this.checkNotice = E('div', { class: 'sing-box-check-notice', role: 'status', 'aria-live': 'polite', hidden: true });
    this.editor = E('textarea', {
      class: 'cbi-input-textarea',
      rows: 24,
      spellcheck: 'false',
      'aria-label': 'sing-box JSON 配置',
      input: () => this.updateDirty(),
    });
    const checkbox = new ui.Checkbox('0', { id: 'sing-box-autostart' }).render();
    this.boot = checkbox.querySelector('input[type="checkbox"]');
    this.boot.setAttribute('aria-label', '开机启动');
    this.bootText = E('span', { style: 'margin-left: 8px;' }, this.boot.checked ? '已开启' : '未开启');
    checkbox.appendChild(this.bootText);
    this.boot.addEventListener('change', () => {
      const enabled = this.boot.checked;
      this.bootText.textContent = enabled ? '已开启' : '未开启';
      this.run(async () => {
        checked(await api.autostart(enabled));
        this.notify(messages.autostart_updated);
      }, true);
    });

    const overview = E('div', { 'data-tab': 'overview', 'data-tab-title': '概览' }, [
      field('运行状态', this.runtime),
      field('内核版本', this.version),
      field('配置文件', this.path),
      field('开机启动', checkbox),
      field(
        '服务操作',
        E('div', { class: 'sing-box-actions' }, [
          this.button('启动', () => this.queue('start'), 'apply'),
          this.button('重启', () => this.queue('restart'), 'warning'),
          this.button('停止', () => this.queue('stop'), 'negative'),
          this.button('更新', async () => {
            const inputEl = document.getElementById('custom-download-url');
            const url = (inputEl && inputEl.value.trim()) || uci.get('sing-box', 'main', 'download_url');
            if (!url) return alert('请先在配置页输入下载地址链接后重试');
            this.notify('正在更新配置，请稍候...');
            try {
              uci.set('sing-box', 'main', 'download_url', url);
              await uci.save();
              await uci.apply();
            } catch (e) {
              console.warn('UCI 保存失败:', e);
            }
            const r = await fetch(url);
            if (!r.ok) throw new Error('网络响应异常: ' + r.statusText);
            const txt = await r.text();
            this.editor.value = txt;
            this.updateDirty();
            await this.save();
          }, 'neutral'),
        ]),
      ),
      field('维护服务', [
        E('div', { class: 'sing-box-actions' }, [
          this.button('清理缓存', () => this.showCacheReset(), 'negative'),
          this.button('更新核心', async () => {
            const inputEl = document.getElementById('custom-core-url');
            const url = (inputEl && inputEl.value.trim()) || uci.get('sing-box', 'main', 'core_url');
            if (!url) return alert('请先前往「配置」标签页填写下载核心地址');
            this.notify('正在后台下载并更新核心，请稍候...');
            const res = checked(await api.updateCore(url));
            this.notify(res.details || messages.core_updated);
          }, 'warning'),
          this.button('打开面板', () => {
            let port = '9090';
            let secret = '';
            try {
              const cfg = JSON.parse(this.editor.value || '{}');
              const apiCfg = cfg && cfg.experimental && cfg.experimental.clash_api;
              if (apiCfg && apiCfg.external_controller) {
                const parts = apiCfg.external_controller.split(':');
                port = parts[parts.length - 1] || '9090';
              }
              if (apiCfg && apiCfg.secret) {
                secret = apiCfg.secret;
              }
            } catch (e) {
              /* JSON 解析失败时使用默认端口 9090 */
            }
            const host = location.hostname;
            const hash = `#/proxies${secret ? `?host=${host}&port=${port}&secret=${encodeURIComponent(secret)}` : ''}`;
            window.open(`${location.protocol}//${host}:${port}/ui/${hash}`, '_blank');
          }, 'action'),
        ]),
        E('div', { class: 'cbi-value-description' }, '清理cache数据库 · 更新sing-box核心 · 打开Web控制面板'),
      ]),
    ]);

    const config = E('div', { 'data-tab': 'config', 'data-tab-title': '配置' }, [
      field('下载核心地址', E('div', {}, [
        E('input', {
          type: 'text',
          class: 'cbi-input-text',
          placeholder: 'https://gh-proxy.org/github.com/77160860/proxy/releases/download/singbox/sing-box-arm64',
          id: 'custom-core-url',
          value: uci.get('sing-box', 'main', 'core_url') || ''
        }),
        this.button('下载核心', async () => {
          const url = document.getElementById('custom-core-url').value.trim();
          if (!url) return alert('请填写核心下载地址');
          this.notify('正在下载核心，请稍候...');
          try {
            uci.set('sing-box', 'main', 'core_url', url);
            await uci.save();
            await uci.apply();
          } catch (e) {
            console.warn('UCI 保存失败:', e);
          }
          const res = checked(await api.updateCore(url));
          this.notify(res.details || messages.core_updated);
        }, 'warning')
      ])),
      field('下载配置文件', E('div', {}, [
        E('input', {
          type: 'text',
          class: 'cbi-input-text',
          placeholder: 'https://cdn.jsdelivr.net/gh/77160860/proxy@main/reF1nd-linux.json',
          id: 'custom-download-url',
          value: uci.get('sing-box', 'main', 'download_url') || ''
        }),
        this.button('下载配置', async () => {
          const url = document.getElementById('custom-download-url').value.trim();
          if (!url) return alert('请填写配置下载地址');
          this.notify('正在拉取配置文件...');
          try {
            uci.set('sing-box', 'main', 'download_url', url);
            await uci.save();
            await uci.apply();
          } catch (e) {
            console.warn('UCI 保存失败:', e);
          }
          try {
            const r = await fetch(url);
            if (!r.ok) throw new Error('网络响应异常: ' + r.statusText);
            const txt = await r.text();
            this.editor.value = txt;
            this.updateDirty();
            this.notify('配置文件拉取成功，请确认后点击下方「保存并应用」');
          } catch (e) {
            this.notify('下载错误: ' + e.message, true);
          }
        }, 'neutral')
      ])),
      field('上传配置文件', E('div', {}, [
        E('input', { type: 'file', class: 'cbi-input-file', id: 'upload-config-file' }),
        E('button', {
          type: 'button',
          class: 'cbi-button cbi-button-action',
          click: () => {
            const input = document.getElementById('upload-config-file');
            if (!input.files.length) return alert('请选择文件');
            const file = input.files[0];
            const reader = new FileReader();
            reader.onload = e => {
              this.editor.value = e.target.result;
              this.updateDirty();
              this.notify('配置文件已导入编辑器，请确认后保存并应用', false, null, 'action');
            };
            reader.onerror = () => alert('读取文件失败');
            reader.readAsText(file);
          }
        }, '上传配置')
      ])),

      E(
        'div',
        { class: 'cbi-section-descr' },
        '直接编辑 JSON。校验不保存；保存并应用会先写入文件，校验通过后重启服务。',
      ),
      this.dirty,
      this.checkNotice,
      this.editor,
      E('div', { class: 'cbi-page-actions sing-box-actions' }, [
        this.button(
          '重载配置',
          async () => {
            if (this.loaded && this.editor.value !== this.savedText && !window.confirm('放弃未保存的修改并重载配置？'))
              return;
            this.setConfig(await api.read());
          },
          'reset',
          false,
        ),
        this.button(
          '校验配置',
          async () => {
            this.setCheckNotice('正在校验配置，请稍候...', false);
            try {
              checked(await api.check(this.content()));
              this.pendingCheck = true;
              this.status.busy = true;
              this.lastJob = null;
            } catch (e) {
              this.pendingCheck = false;
              this.setCheckNotice(e.message, true, null, 5000);
            }
          },
          'warning',
          true,
          true,
        ),
        this.button(
          '格式化配置',
          () => {
            this.editor.value = JSON.stringify(JSON.parse(this.content()), null, 2) + '\n';
            this.updateDirty();
          },
          'neutral',
          true,
          true,
        ),
        this.button('保存并应用', () => this.save(), 'apply', true, true),
      ]),
    ]);

    this.logHint = E('div', { class: 'cbi-section-descr', role: 'status' });
    this.logUpdated = E('div', { class: 'cbi-section-descr' });
    this.logs = E('textarea', {
      class: 'cbi-input-textarea',
      rows: 20,
      readonly: '',
      'aria-label': 'sing-box 系统日志',
    });
    const logs = E('div', { 'data-tab': 'logs', 'data-tab-title': '日志' }, [this.logHint, this.logUpdated, this.logs]);
    logs.addEventListener('cbi-tab-active', () => this.refreshLogs());

    const panes = E('div', {}, [overview, config, logs]);
    this.panes = panes;
    const root = E('div', { class: 'cbi-map', id: 'sing-box-panel' }, [
      E('link', { rel: 'stylesheet', href: L.resource('view/sing-box/panel.css') }),
      E('h2', {}, 'Sing'),
      E('p', { class: 'cbi-map-descr' }, this.writable ? '配置与服务管理' : '当前账号仅有查看权限。'),
      this.problem,
      E('div', { class: 'cbi-section' }, [panes]),
    ]);

    ui.tabs.initTabGroup(panes.childNodes);
    try {
      this.setConfig(data[1]);
    } catch (error) {
      this.notify(error.message, true);
    }
    try {
      if (this.status.job && JSON.parse(this.status.job).state === 'success') this.lastJob = this.status.job;
    } catch {
      /* updateStatus reports malformed task data. */
    }
    this.updateStatus(this.status);
    poll.add(async () => {
      try {
        await this.refresh();
      } catch (error) {
        this.problem.textContent = '状态刷新失败：' + error.message;
        this.problem.hidden = false;
      }
      if (logs.getAttribute('data-tab-active') === 'true') await this.refreshLogs();
    }, 2);
    return root;
  },
});
