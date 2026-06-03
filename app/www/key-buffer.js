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
// Props down, events up: this component only reads `pty` (the pty session id)
// from its attribute and POSTs to /pty/input. It doesn't manage the projection.

/** Map a KeyboardEvent into the bytes a pty expects to receive.
 *  Returns null for keys we can't sensibly translate (pure modifiers,
 *  unhandled function keys, etc), so the caller can skip them.
 *  Returns { bytes: Uint8Array | string, display: string }. */
function keyEventToInput(ev) {
  // Pure modifier press: nothing to send.
  if (["Shift", "Control", "Alt", "Meta", "CapsLock"].includes(ev.key)) {
    return null;
  }

  // Named special keys -> escape sequences. xterm/vt100 semantics where they
  // disagree; bash + readline grok this set. Two CSI shapes: cursor/edit keys
  // ending in a letter (CSI <final>, or CSI 1 ; <mod> <final> when modified),
  // and the "tilde" keys (CSI <n> ~, or CSI <n> ; <mod> ~ when modified).
  const CSI_LETTER = {
    ArrowUp: { final: "A", display: "UP" },
    ArrowDown: { final: "B", display: "DN" },
    ArrowRight: { final: "C", display: "R" },
    ArrowLeft: { final: "D", display: "L" },
    Home: { final: "H", display: "HM" },
    End: { final: "F", display: "END" },
  };
  const CSI_TILDE = {
    PageUp: { n: 5, display: "PgU" },
    PageDown: { n: 6, display: "PgD" },
    Delete: { n: 3, display: "DEL" },
    Insert: { n: 2, display: "INS" },
  };
  // xterm modifier parameter: 1 + shift + 2*alt + 4*ctrl + 8*meta. 1 means
  // "no modifiers" -- in which case we omit the parameter entirely (bare CSI).
  const xtermMod = () =>
    1 + (ev.shiftKey ? 1 : 0) + (ev.altKey ? 2 : 0) + (ev.ctrlKey ? 4 : 0) +
    (ev.metaKey ? 8 : 0);
  const modDisplay = () =>
    (ev.metaKey ? "M-" : "") + (ev.ctrlKey ? "^" : "") +
    (ev.altKey ? "A-" : "") + (ev.shiftKey ? "S-" : "");

  if (CSI_LETTER[ev.key]) {
    const { final, display } = CSI_LETTER[ev.key];
    const m = xtermMod();
    const bytes = m === 1 ? `\x1b[${final}` : `\x1b[1;${m}${final}`;
    return { bytes, display: modDisplay() + display };
  }
  if (CSI_TILDE[ev.key]) {
    const { n, display } = CSI_TILDE[ev.key];
    const m = xtermMod();
    const bytes = m === 1 ? `\x1b[${n}~` : `\x1b[${n};${m}~`;
    return { bytes, display: modDisplay() + display };
  }

  // Enter/Tab/Backspace/Escape: bare control bytes. Modified Backspace is
  // useful (Alt+BS = delete word, Ctrl+W-ish), so encode it; the others have no
  // standard modified form here, so send the plain byte.
  if (ev.key === "Backspace") {
    if (ev.altKey && !ev.ctrlKey && !ev.metaKey) {
      return { bytes: "\x1b\x7f", display: "A-BS" }; // Meta-DEL: delete word
    }
    if (ev.ctrlKey && !ev.altKey && !ev.metaKey) {
      return { bytes: "\x17", display: "^W" }; // delete word back
    }
    return { bytes: "\x7f", display: "BS" };
  }
  const PLAIN = {
    Enter: { bytes: "\r", display: "RET" },
    Tab: { bytes: "\t", display: "TAB" },
    Escape: { bytes: "\x1b", display: "ESC" },
  };
  if (PLAIN[ev.key]) return PLAIN[ev.key];

  // Single-char key: handle Ctrl/Alt combos, then send the literal.
  if (ev.key.length === 1) {
    const ch = ev.key;
    if (ev.ctrlKey && !ev.altKey && !ev.metaKey) {
      // Ctrl+letter -> 0x01..0x1a; Ctrl+@ -> NUL; Ctrl+[\]^_ -> their codes
      const lower = ch.toLowerCase();
      if (lower >= "a" && lower <= "z") {
        const code = lower.charCodeAt(0) - 0x60;
        return {
          bytes: String.fromCharCode(code),
          display: "^" + lower.toUpperCase(),
        };
      }
      const PUNCT = {
        "@": 0,
        "[": 27,
        "\\": 28,
        "]": 29,
        "^": 30,
        "_": 31,
        " ": 0,
      };
      if (ch in PUNCT) {
        return { bytes: String.fromCharCode(PUNCT[ch]), display: "^" + ch };
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
      return { bytes: "\x1b" + ch, display: "M-" + ch };
    }
    if (ev.metaKey) {
      // Cmd+letter has no terminal byte -- it's an OS/browser shortcut (copy,
      // paste, reload). Leave it to them. (Cmd+arrow/Backspace etc. are encoded
      // above as modified CSI sequences and never reach here.)
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
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" ||
    t.isContentEditable === true;
}

class KeyBuffer extends HTMLElement {
  static observedAttributes = ["pty", "enabled"];

  constructor() {
    super();
    this._pty = "";
    // Enabled by default; the sessions surface gates this on focus mode so
    // keystrokes only reach the pty when a terminal is focused. Single-pane
    // never sets the attribute, so it stays enabled.
    this._enabled = true;
    this._pending = []; // [{id, display}]
    this._nextId = 1;
    // True between compositionstart/end. While composing (dead keys, IME) the
    // OS builds a character in the focused hidden input; keydowns in that window
    // are provisional, so we ignore them and send the finished string on
    // compositionend instead.
    this._composing = false;
    this._onKey = this._onKey.bind(this);
    this._onCompStart = () => {
      this._composing = true;
    };
    this._onCompEnd = (ev) => {
      this._composing = false;
      const data = ev.data || this._input.value;
      this._input.value = "";
      if (data && this._enabled && this._pty) this._send(data, data);
    };
  }

  connectedCallback() {
    this._onPaste = this._onPaste.bind(this);
    this._onCopy = this._onCopy.bind(this);
    // A hidden, focusable textarea: when a terminal is focused we park DOM
    // focus here so the OS routes composition (macOS Option+e e -> "e-acute",
    // dead keys, IME) into a real input element. Without a real input there is
    // no composition session and dead keys collapse to their base letter.
    // Offscreen via opacity (not display:none, which can't hold focus).
    const inp = document.createElement("textarea");
    inp.setAttribute("aria-hidden", "true");
    inp.tabIndex = -1;
    inp.autocapitalize = "off";
    inp.autocomplete = "off";
    inp.spellcheck = false;
    inp.style.cssText =
      "position:fixed;top:0;left:0;width:1px;height:1px;opacity:0;padding:0;border:0;outline:0;resize:none;overflow:hidden;z-index:-1;";
    inp.addEventListener("compositionstart", this._onCompStart);
    inp.addEventListener("compositionend", this._onCompEnd);
    this._input = inp;
    this.appendChild(inp);
    // Ghost keystrokes render into their own container so _render never
    // disturbs the hidden input sitting beside it.
    this._ghosts = document.createElement("span");
    this.appendChild(this._ghosts);
    // keydown stays on window: it still fires while the hidden input is focused
    // (events bubble up), the capture-phase app keymap runs ahead of it, and
    // composing keydowns carry ev.isComposing so we can skip them.
    window.addEventListener("keydown", this._onKey);
    window.addEventListener("paste", this._onPaste);
    document.addEventListener("copy", this._onCopy);
    this._render();
  }

  disconnectedCallback() {
    window.removeEventListener("keydown", this._onKey);
    window.removeEventListener("paste", this._onPaste);
    document.removeEventListener("copy", this._onCopy);
  }

  // Park DOM focus on the hidden input (terminal focus) so the OS composes
  // into it. Deferred so it lands after any morph/layout settles. Skip while
  // the user has an active text selection: focusing the input would collapse
  // it, so a click that selects grid text would immediately deselect. Typing
  // re-parks focus via _onKey, so composition still resumes when they type.
  focusInput() {
    requestAnimationFrame(() => {
      const sel = window.getSelection();
      if (sel && !sel.isCollapsed) return;
      try {
        this._input?.focus();
      } catch { /* gone */ }
    });
  }

  // One path to the pty: queue a ghost entry, POST the bytes, drop on ack.
  _send(bytes, display) {
    const id = this._nextId++;
    this._pending.push({ id, display });
    this._render();
    fetch("/pty/input?sid=" + encodeURIComponent(this._pty), {
      method: "POST",
      headers: { "content-type": "application/octet-stream" },
      body: bytes,
    })
      .then(() => this._drop(id))
      .catch(() => this._drop(id));
  }

  _onCopy(ev) {
    // Cells are padded with spaces to fill the row, so a naive copy hauls
    // trailing whitespace along. Strip it per line before handing to the
    // clipboard. Mirrors what ghostty/alacritty do on select-and-copy.
    const sel = window.getSelection();
    if (!sel) return;
    const text = sel.toString();
    if (text.length === 0) return;
    const trimmed = text.split("\n").map((l) => l.replace(/[ \t]+$/, "")).join(
      "\n",
    );
    if (trimmed === text) return;
    ev.clipboardData?.setData("text/plain", trimmed);
    ev.preventDefault();
  }

  _onPaste(ev) {
    if (!this._enabled || !this._pty) return;
    const text = ev.clipboardData?.getData("text");
    if (!text) return;
    ev.preventDefault();

    // Pasted text goes through as a single chunk. The pty sees it the same
    // way it would see hand-typed bytes; reedline's bracketed-paste mode
    // would normally wrap with ESC[200~/ESC[201~, but most programs handle
    // a plain chunk fine and bash/nu both accept it.
    const preview = text.length > 12 ? text.slice(0, 9) + "..." : text;
    this._send(text, "PASTE(" + preview.replace(/\s+/g, " ") + ")");
  }

  attributeChangedCallback(name, _old, value) {
    if (name === "pty") {
      this._pty = value || "";
    } else if (name === "enabled") {
      // Absent attribute -> enabled. Present -> enabled unless "false".
      this._enabled = value !== "false";
      if (!this._enabled && this._pending.length) {
        this._pending = [];
        this._render();
      }
    }
  }

  _onKey(ev) {
    if (!this._enabled || !this._pty) return;
    // A composing keydown (ev.isComposing, or the IME's keyCode 229) is part of
    // building a character in the hidden input. Ignore it -- compositionend
    // sends the finished string. Without this, the dead key's keydown would be
    // forwarded raw and the accent lost.
    if (ev.isComposing || ev.keyCode === 229 || this._composing) return;
    // Don't hijack keys meant for a real form field (e.g. the rename modal
    // input). Our own hidden input is the pty's capture surface, not a form
    // field, so it does NOT count here.
    if (ev.target !== this._input && isEditableTarget(ev.target)) return;
    // App-level shortcuts (e.g. the sessions Alt+T/J/K keymap) intercept in
    // the capture phase and stopImmediatePropagation, so they never reach
    // this bubble-phase listener. Nothing to special-case here.
    // Ctrl+C on a non-empty selection copies, doesn't interrupt. Mirrors
    // every terminal emulator's "selection beats SIGINT" rule. Cmd+C on
    // macOS is handled by the browser itself, so we don't touch it here.
    if (ev.ctrlKey && !ev.altKey && !ev.metaKey && ev.key === "c") {
      const sel = window.getSelection().toString();
      if (sel) {
        navigator.clipboard.writeText(sel).catch(() => {});
        ev.preventDefault();
        return;
      }
    }
    const tr = keyEventToInput(ev);
    if (!tr) return;
    // Only now -- once we know this is a key we forward to the pty (real
    // typing, not Cmd/Ctrl shortcuts, which keyEventToInput drops to null) --
    // re-park focus on the hidden input. It may have blurred because the user
    // clicked the grid to select text; typing means they're done selecting, so
    // the browser clears the selection as usual. Crucially we DON'T do this for
    // Cmd+C and friends, which must leave the selection intact for the copy.
    if (this._input && document.activeElement !== this._input) {
      this._input.focus();
    }
    // Let the browser handle browser-level shortcuts (Cmd-R, Ctrl-Shift-I,
    // etc) but swallow anything we're forwarding to the pty so it doesn't
    // also trigger e.g. browser quick-find on '/'. Clear any stray character
    // the keypress may have placed in the hidden input.
    ev.preventDefault();
    if (this._input) this._input.value = "";
    this._send(tr.bytes, tr.display);
  }

  _drop(id) {
    const before = this._pending.length;
    this._pending = this._pending.filter((p) => p.id !== id);
    if (this._pending.length !== before) this._render();
  }

  _render() {
    if (!this._ghosts) return;
    if (this._pending.length === 0) {
      this._ghosts.replaceChildren();
      return;
    }
    const frag = document.createDocumentFragment();
    for (const p of this._pending) {
      const span = document.createElement("span");
      span.className = "ghost";
      span.textContent = p.display;
      frag.appendChild(span);
    }
    this._ghosts.replaceChildren(frag);
  }
}

customElements.define("key-buffer", KeyBuffer);
