// <diff-clip> -- a vanilla custom element wrapping @pierre/diffs (diffs.com).
//
// @pierre/diffs ships an imperative class API (`new FileDiff(opts)` then
// `instance.render({oldFile, newFile, containerWrapper})`), not a declarative
// tag. This is the thin standards-compliant wrapper that gives us a real
// custom element we can drop into the clip renderer:
//
//   <diff-clip filename="example.ts" diff-style="split">
//     <script type="text/plain" data-diff="old">old source...</script>
//     <script type="text/plain" data-diff="new">new source...</script>
//   </diff-clip>
//
// Content can also be set as properties (oldText/newText or oldFile/newFile)
// for the server-driven path. The library renders into its own <diffs-container>
// shadow root, so page CSS does not bleed into the diff.
//
// The "@pierre/diffs" specifier is resolved by an import map in the host page
// (a CDN now, a vendored copy later). The import is lazy: the ~Shiki-sized
// bundle only loads when a diff clip is actually mounted.

let _fileDiffPromise;
function loadFileDiff() {
  return (_fileDiffPromise ??= import("@pierre/diffs").then((m) => m.FileDiff));
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
  ];

  constructor() {
    super();
    this._instance = null;
    // Property-set content takes precedence over attributes/children. Records
    // are {name, contents, lang?}; *Text are bare strings paired with filename.
    this._oldFile = null;
    this._newFile = null;
    this._oldText = null;
    this._newText = null;
    this._scheduled = false;
    this._firstRender = true;
  }

  // -- property API (server-driven / programmatic path) --------------------

  set oldFile(v) {
    this._oldFile = v;
    this._schedule();
  }
  get oldFile() {
    return this._resolve("old");
  }
  set newFile(v) {
    this._newFile = v;
    this._schedule();
  }
  get newFile() {
    return this._resolve("new");
  }
  set oldText(v) {
    this._oldText = v;
    this._schedule();
  }
  set newText(v) {
    this._newText = v;
    this._schedule();
  }
  /** The underlying FileDiff instance, once rendered (or null). */
  get instance() {
    return this._instance;
  }

  // -- lifecycle -----------------------------------------------------------

  connectedCallback() {
    this._schedule();
  }
  disconnectedCallback() {
    this._instance?.cleanUp();
    this._instance = null;
    this._firstRender = true;
  }
  attributeChangedCallback() {
    this._schedule();
  }

  // -- content resolution --------------------------------------------------

  _filename() {
    return this.getAttribute("filename") || "clip";
  }

  // A side's text, in precedence order: property record -> property string
  // -> attribute -> child <script data-diff="old|new">.
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
        ? { dark: themeAttr.split(",")[0].trim(), light: themeAttr.split(",")[1].trim() }
        : themeAttr;
    }
    return {
      theme,
      diffStyle: this.getAttribute("diff-style") === "unified" ? "unified" : "split",
      disableFileHeader: this.hasAttribute("no-header"),
      enableLineSelection: true,
      onLineSelected: (range) =>
        this.dispatchEvent(
          new CustomEvent("line-select", { detail: range, bubbles: true }),
        ),
      onPostRender: (_node, _instance, phase) => {
        if (phase === "mount") {
          this.dispatchEvent(new CustomEvent("diff-render", { bubbles: true }));
        }
      },
    };
  }

  // -- render --------------------------------------------------------------

  // Coalesce bursts of attribute/property writes into one render next microtask.
  _schedule() {
    if (this._scheduled) return;
    this._scheduled = true;
    queueMicrotask(() => this._render());
  }

  async _render() {
    this._scheduled = false;
    if (!this.isConnected) return;
    const oldFile = this._resolve("old");
    const newFile = this._resolve("new");
    if (!oldFile || !newFile) return;

    const FileDiff = await loadFileDiff();
    if (!this.isConnected) return; // unmounted while the bundle loaded

    if (!this._instance) {
      this._instance = new FileDiff(this._options());
    } else {
      this._instance.setOptions(this._options());
    }
    // forceRender so live option toggles (split<->unified, theme) repaint even
    // when the file contents are unchanged.
    this._instance.render({
      oldFile,
      newFile,
      containerWrapper: this,
      forceRender: !this._firstRender,
    });
    this._firstRender = false;
  }
}

customElements.define("diff-clip", DiffClip);

export { DiffClip };
