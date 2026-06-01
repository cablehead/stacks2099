// <key-buffer> web component: visualizes in-flight keystrokes.
//
// On each keydown we translate the event to its pty byte sequence, append a
// "ghost" entry to the buffer, and POST /pty/input?sid=...; when the POST
// resolves (HTTP-level ack of write_input), we remove that entry. On
// localhost the buffer is invisible because POSTs return in ~1ms. Over a
// laggy link you see jjhlk appear at the start of typing and drain as the
// network catches up.
//
// Approach 1 from the design discussion: drain on POST ack, not on
// projection-frame echo. Programs that consume keys without echoing (vim
// normal mode etc) still drain correctly because the POST itself acks.
//
// Props down, events up: this component only reads `sid` from its attribute
// and POSTs to /pty/input. It doesn't manage the projection.

/** Map a KeyboardEvent into the bytes a pty expects to receive.
 *  Returns null for keys we can't sensibly translate (pure modifiers,
 *  unhandled function keys, etc), so the caller can skip them.
 *  Returns { bytes: Uint8Array | string, display: string }. */
function keyEventToInput(ev) {
  // Pure modifier press: nothing to send.
  if (['Shift', 'Control', 'Alt', 'Meta', 'CapsLock'].includes(ev.key)) {
    return null;
  }

  // Named special keys -> escape sequences. xterm/vt100 semantics where they
  // disagree; bash + readline grok this set.
  const SPECIAL = {
    Enter: { bytes: '\r', display: 'RET' },
    Tab: { bytes: '\t', display: 'TAB' },
    Backspace: { bytes: '\x7f', display: 'BS' },
    Escape: { bytes: '\x1b', display: 'ESC' },
    ArrowUp: { bytes: '\x1b[A', display: 'UP' },
    ArrowDown: { bytes: '\x1b[B', display: 'DN' },
    ArrowRight: { bytes: '\x1b[C', display: 'R' },
    ArrowLeft: { bytes: '\x1b[D', display: 'L' },
    Home: { bytes: '\x1b[H', display: 'HM' },
    End: { bytes: '\x1b[F', display: 'END' },
    PageUp: { bytes: '\x1b[5~', display: 'PgU' },
    PageDown: { bytes: '\x1b[6~', display: 'PgD' },
    Delete: { bytes: '\x1b[3~', display: 'DEL' },
    Insert: { bytes: '\x1b[2~', display: 'INS' },
  };
  if (SPECIAL[ev.key]) return SPECIAL[ev.key];

  // Single-char key: handle Ctrl/Alt combos, then send the literal.
  if (ev.key.length === 1) {
    const ch = ev.key;
    if (ev.ctrlKey && !ev.altKey && !ev.metaKey) {
      // Ctrl+letter -> 0x01..0x1a; Ctrl+@ -> NUL; Ctrl+[\]^_ -> their codes
      const lower = ch.toLowerCase();
      if (lower >= 'a' && lower <= 'z') {
        const code = lower.charCodeAt(0) - 0x60;
        return { bytes: String.fromCharCode(code), display: '^' + lower.toUpperCase() };
      }
      const PUNCT = { '@': 0, '[': 27, '\\': 28, ']': 29, '^': 30, '_': 31, ' ': 0 };
      if (ch in PUNCT) {
        return { bytes: String.fromCharCode(PUNCT[ch]), display: '^' + ch };
      }
    }
    if (ev.altKey && !ev.ctrlKey && !ev.metaKey) {
      // Option/AltGr is a character-compose modifier on most non-US layouts:
      // the OS already produced a printable glyph (Danish Option+I -> "|",
      // Option+BracketRight -> "~"), delivered as ev.key. A composed glyph is
      // never a plain ASCII letter, so send any non-letter altKey character
      // literally. A true Alt+letter chord (ev.key is the code's own letter)
      // stays Meta-prefixed (ESC + char, bash readline convention) for TUIs.
      const codeLetter = /^Key([A-Z])$/.exec(ev.code)?.[1]?.toLowerCase();
      const isAltLetterChord = codeLetter && ch.toLowerCase() === codeLetter;
      if (!isAltLetterChord) {
        return { bytes: ch, display: ch };
      }
      return { bytes: '\x1b' + ch, display: 'M-' + ch };
    }
    if (ev.metaKey) {
      // Don't fight the OS for Cmd-anything; let the browser handle it
      // (Cmd-V paste lands as separate input events).
      return null;
    }
    return { bytes: ch, display: ch };
  }

  // Anything else (F1-F12, etc): not handled in first cut. Drop silently.
  return null;
}

/** True when keystrokes belong to a form field / editable region rather
 *  than the terminal (so we leave them alone). */
function isEditableTarget(t) {
  if (!t || !t.tagName) return false;
  const tag = t.tagName;
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || t.isContentEditable === true;
}

class KeyBuffer extends HTMLElement {
  static observedAttributes = ['sid', 'enabled'];

  constructor() {
    super();
    this._sid = '';
    // Enabled by default; the sessions surface gates this on focus mode so
    // keystrokes only reach the pty when a terminal is focused. Single-pane
    // never sets the attribute, so it stays enabled.
    this._enabled = true;
    this._pending = []; // [{id, display}]
    this._nextId = 1;
    this._onKey = this._onKey.bind(this);
  }

  connectedCallback() {
    this._onPaste = this._onPaste.bind(this);
    this._onCopy = this._onCopy.bind(this);
    window.addEventListener('keydown', this._onKey);
    window.addEventListener('paste', this._onPaste);
    document.addEventListener('copy', this._onCopy);
    this._render();
  }

  disconnectedCallback() {
    window.removeEventListener('keydown', this._onKey);
    window.removeEventListener('paste', this._onPaste);
    document.removeEventListener('copy', this._onCopy);
  }

  _onCopy(ev) {
    // Cells are padded with spaces to fill the row, so a naive copy hauls
    // trailing whitespace along. Strip it per line before handing to the
    // clipboard. Mirrors what ghostty/alacritty do on select-and-copy.
    const sel = window.getSelection();
    if (!sel) return;
    const text = sel.toString();
    if (text.length === 0) return;
    const trimmed = text.split('\n').map((l) => l.replace(/[ \t]+$/, '')).join('\n');
    if (trimmed === text) return;
    ev.clipboardData?.setData('text/plain', trimmed);
    ev.preventDefault();
  }

  _onPaste(ev) {
    if (!this._enabled || !this._sid) return;
    const text = ev.clipboardData?.getData('text');
    if (!text) return;
    ev.preventDefault();

    // Pasted text goes through as a single chunk. The pty sees it the same
    // way it would see hand-typed bytes; reedline's bracketed-paste mode
    // would normally wrap with ESC[200~/ESC[201~, but most programs handle
    // a plain chunk fine and bash/nu both accept it.
    const id = this._nextId++;
    const preview = text.length > 12 ? text.slice(0, 9) + '...' : text;
    this._pending.push({ id, display: 'PASTE(' + preview.replace(/\s+/g, ' ') + ')' });
    this._render();

    fetch('/pty/input?sid=' + encodeURIComponent(this._sid), {
      method: 'POST',
      headers: { 'content-type': 'application/octet-stream' },
      body: text,
    })
      .then(() => this._drop(id))
      .catch(() => this._drop(id));
  }

  attributeChangedCallback(name, _old, value) {
    if (name === 'sid') {
      this._sid = value || '';
    } else if (name === 'enabled') {
      // Absent attribute -> enabled. Present -> enabled unless "false".
      this._enabled = value !== 'false';
      if (!this._enabled && this._pending.length) {
        this._pending = [];
        this._render();
      }
    }
  }

  _onKey(ev) {
    if (!this._enabled || !this._sid) return;
    // Don't hijack keys meant for an editable element (e.g. the sessions
    // rename modal input). The pty only owns keystrokes typed at the page
    // itself, not into a form field.
    if (isEditableTarget(ev.target)) return;
    // App-level shortcuts (e.g. the sessions Alt+T/J/K keymap) intercept in
    // the capture phase and stopImmediatePropagation, so they never reach
    // this bubble-phase listener. Nothing to special-case here.
    // Ctrl+C on a non-empty selection copies, doesn't interrupt. Mirrors
    // every terminal emulator's "selection beats SIGINT" rule. Cmd+C on
    // macOS is handled by the browser itself, so we don't touch it here.
    if (ev.ctrlKey && !ev.altKey && !ev.metaKey && ev.key === 'c') {
      const sel = window.getSelection().toString();
      if (sel) {
        navigator.clipboard.writeText(sel).catch(() => {});
        ev.preventDefault();
        return;
      }
    }
    const tr = keyEventToInput(ev);
    if (!tr) return;
    // Let the browser handle browser-level shortcuts (Cmd-R, Ctrl-Shift-I,
    // etc) but swallow anything we're forwarding to the pty so it doesn't
    // also trigger e.g. browser quick-find on '/'.
    ev.preventDefault();

    const id = this._nextId++;
    this._pending.push({ id, display: tr.display });
    this._render();

    fetch('/pty/input?sid=' + encodeURIComponent(this._sid), {
      method: 'POST',
      headers: { 'content-type': 'application/octet-stream' },
      body: tr.bytes,
    })
      .then(() => this._drop(id))
      .catch(() => this._drop(id));
  }

  _drop(id) {
    const before = this._pending.length;
    this._pending = this._pending.filter((p) => p.id !== id);
    if (this._pending.length !== before) this._render();
  }

  _render() {
    if (this._pending.length === 0) {
      this.replaceChildren();
      return;
    }
    const frag = document.createDocumentFragment();
    for (const p of this._pending) {
      const span = document.createElement('span');
      span.className = 'ghost';
      span.textContent = p.display;
      frag.appendChild(span);
    }
    this.replaceChildren(frag);
  }
}

customElements.define('key-buffer', KeyBuffer);
