// <diff-clip> -- a vanilla custom element wrapping @pierre/diffs (diffs.com).
//
// @pierre/diffs ships an imperative class API, not a declarative tag. This is
// the thin standards-compliant wrapper that gives us a real custom element.
//
// Two modes:
//
//   single-file: old/new text via attributes or properties
//     <diff-clip filename="x.ts"><script data-diff="old">..</script>
//                                <script data-diff="new">..</script></diff-clip>
//
//   multi-file: a whole-repo unified patch (the live repo-diff clip)
//     <diff-clip multi-file><script data-diff="patch">..git diff..</script></diff-clip>
//
// In multi-file mode the patch is parsed with parsePatchFiles into N file
// diffs, each rendered by its own FileDiff instance keyed by path. A
// MutationObserver watches the <script data-diff> child, so when the server
// morphs in a fresh patch over /sse the SAME instances re-render in place --
// scroll preserved, like a live terminal grid. The library renders into its
// own <diffs-container> shadow root, so page CSS does not bleed in.
//
// "@pierre/diffs" is resolved by an import map in the host page. The import is
// lazy: the bundle only loads when a diff clip is actually mounted.

let _libPromise;
function loadLib() {
  return (_libPromise ??= import("@pierre/diffs").then((m) => ({
    FileDiff: m.FileDiff,
    parsePatchFiles: m.parsePatchFiles,
  })));
}

const DEFAULT_THEME = { dark: "pierre-dark", light: "pierre-light" };

class DiffClip extends HTMLElement {
  static observedAttributes = [
    "diff-style",
    "theme",
    "filename",
    "old-name",
    "new-name",
    "lang",
    "no-header",
    "old",
    "new",
    "multi-file",
    // The server bumps `rev` (the patch content hash) on every change. datastar
    // morphs the light DOM (the <script data-diff> + rev attr); the changed rev
    // triggers a re-render into our shadow root, which idiomorph never touches.
    "rev",
  ];

  constructor() {
    super();
    // Render into a shadow root: the rendered diffs live here, invisible to
    // idiomorph (which only morphs light DOM). That lets the server morph the
    // whole <diff-clip> element freely, and removes any self-mutation feedback
    // loop -- the light DOM is just data (the <script data-diff> + attrs).
    this._root = this.attachShadow({ mode: "open" });
    const style = document.createElement("style");
    style.textContent = ".diff-file{display:block}.diff-file+.diff-file{margin-top:8px}";
    this._root.appendChild(style);
    this._mount = document.createElement("div");
    this._root.appendChild(this._mount);

    this._instance = null; // single-file: one FileDiff
    this._byPath = new Map(); // multi-file: path -> {wrap, instance}
    this._oldFile = null;
    this._newFile = null;
    this._oldText = null;
    this._newText = null;
    this._patch = null;
    this._scheduled = false;
    this._firstRender = true;
    this._lastSig = null;
  }

  // -- property API (server-driven / programmatic) -------------------------

  set oldFile(v) {
    this._oldFile = v;
    this._schedule();
  }
  set newFile(v) {
    this._newFile = v;
    this._schedule();
  }
  set oldText(v) {
    this._oldText = v;
    this._schedule();
  }
  set newText(v) {
    this._newText = v;
    this._schedule();
  }
  set patch(v) {
    this._patch = v;
    this._schedule();
  }
  /** The single-file FileDiff instance, or the path->instance map (multi). */
  get instance() {
    return this._multi() ? this._byPath : this._instance;
  }

  // -- lifecycle -----------------------------------------------------------

  connectedCallback() {
    this._schedule();
  }
  disconnectedCallback() {
    this._instance?.cleanUp();
    this._instance = null;
    for (const { instance } of this._byPath.values()) instance.cleanUp();
    this._byPath.clear();
    this._firstRender = true;
    this._lastSig = null;
  }
  attributeChangedCallback() {
    this._schedule();
  }

  // -- content resolution --------------------------------------------------

  _multi() {
    return this.hasAttribute("multi-file") || this._patch != null ||
      this.querySelector('script[data-diff="patch"]') != null;
  }
  _filename() {
    return this.getAttribute("filename") || "clip";
  }
  _patchText() {
    if (this._patch != null) return this._patch;
    if (this.hasAttribute("patch")) return this.getAttribute("patch");
    const el = this.querySelector('script[data-diff="patch"]');
    return el ? el.textContent : null;
  }
  _resolve(side) {
    const fileProp = side === "old" ? this._oldFile : this._newFile;
    if (fileProp) return fileProp;
    const textProp = side === "old" ? this._oldText : this._newText;
    const child = this.querySelector(`script[data-diff="${side}"]`);
    const contents = textProp ??
      this.getAttribute(side) ??
      (child ? child.textContent : null);
    if (contents == null) return null;
    return {
      name: this.getAttribute(`${side}-name`) || this._filename(),
      contents,
      lang: this.getAttribute("lang") || undefined,
    };
  }

  _options() {
    const themeAttr = this.getAttribute("theme");
    let theme = DEFAULT_THEME;
    if (themeAttr && themeAttr !== "auto") {
      theme = themeAttr.includes(",")
        ? {
          dark: themeAttr.split(",")[0].trim(),
          light: themeAttr.split(",")[1].trim(),
        }
        : themeAttr;
    }
    return {
      theme,
      diffStyle: this.getAttribute("diff-style") === "unified"
        ? "unified"
        : "split",
      disableFileHeader: this.hasAttribute("no-header"),
      enableLineSelection: true,
      onLineSelected: (range) =>
        this.dispatchEvent(
          new CustomEvent("line-select", { detail: range, bubbles: true }),
        ),
    };
  }

  // -- render --------------------------------------------------------------

  _schedule() {
    if (this._scheduled) return;
    this._scheduled = true;
    queueMicrotask(() => this._render());
  }

  // A signature of everything that affects the rendered output: options plus
  // the resolved content. The MutationObserver fires on our OWN render
  // mutations (appended wrappers, injected shadow content); without this guard
  // each render would schedule another -> infinite loop -> hang. Re-rendering
  // only when the signature actually changed makes self-induced mutations
  // no-ops, and dedupes server pushes of an identical patch.
  _sig() {
    const opt = JSON.stringify({
      ds: this.getAttribute("diff-style"),
      th: this.getAttribute("theme"),
      nh: this.hasAttribute("no-header"),
      fn: this.getAttribute("filename"),
      rev: this.getAttribute("rev"),
    });
    if (this._multi()) return "M|" + opt + "|" + (this._patchText() ?? "");
    return "S|" + opt + "|" +
      JSON.stringify([this._resolve("old"), this._resolve("new")]);
  }

  async _render() {
    this._scheduled = false;
    if (!this.isConnected) return;
    const sig = this._sig();
    if (sig === this._lastSig) return; // no-op: our own mutation or a dupe
    const lib = await loadLib();
    if (!this.isConnected) return; // unmounted while the bundle loaded
    if (this._sig() !== sig) return; // content changed again mid-load; a later
    // scheduled render will handle the newest signature
    this._lastSig = sig; // set before mutating, so reentrant observer calls no-op
    if (this._multi()) {
      this._renderMulti(lib);
    } else {
      this._renderSingle(lib);
    }
    this._firstRender = false;
  }

  _renderSingle({ FileDiff }) {
    const oldFile = this._resolve("old");
    const newFile = this._resolve("new");
    if (!oldFile || !newFile) return;
    if (!this._instance) this._instance = new FileDiff(this._options());
    else this._instance.setOptions(this._options());
    this._instance.render({
      oldFile,
      newFile,
      containerWrapper: this._mount,
      forceRender: !this._firstRender,
    });
  }

  // Parse the unified patch, reconcile FileDiff instances by path: reuse for
  // files still present (render with new fileDiff -> in-place update), create
  // for new files, cleanUp + remove for gone files. Wrappers stay in patch
  // order.
  _renderMulti({ FileDiff, parsePatchFiles }) {
    const text = this._patchText();
    if (text == null) return;
    let files = [];
    try {
      files = parsePatchFiles(text).flatMap((p) => p.files);
    } catch (e) {
      console.error("diff-clip: patch parse failed", e);
      return;
    }
    const opts = this._options();
    const seen = new Set();
    for (const fileDiff of files) {
      const key = fileDiff.name;
      seen.add(key);
      let entry = this._byPath.get(key);
      if (!entry) {
        const wrap = document.createElement("div");
        wrap.className = "diff-file";
        this._mount.appendChild(wrap);
        entry = { wrap, instance: new FileDiff(opts) };
        this._byPath.set(key, entry);
      } else {
        entry.instance.setOptions(opts);
        this._mount.appendChild(entry.wrap); // re-append to enforce patch order
      }
      entry.instance.render({
        fileDiff,
        containerWrapper: entry.wrap,
        forceRender: true,
      });
    }
    // Drop files no longer in the patch.
    for (const [key, entry] of [...this._byPath]) {
      if (seen.has(key)) continue;
      entry.instance.cleanUp();
      entry.wrap.remove();
      this._byPath.delete(key);
    }
  }
}

customElements.define("diff-clip", DiffClip);

export { DiffClip };
