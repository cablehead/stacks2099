//! `pty` commands for http-nu: open/write/resize/view/close.
//!
//! Two backends:
//! - exec: fork+exec an external command via portable-pty
//! - embedded: fork the http-nu process, run nu's REPL in the child against
//!   a clone of the current EngineState. No external `nu` binary needed;
//!   the in-browser REPL has access to http-nu's custom commands.
//!
//! Sessions live in a process-wide map keyed by sid. The canonical screen
//! state lives in a server-side `wezterm_term::Terminal` per sid. Clients
//! subscribe via `pty view` and receive HTML grid snapshots over SSE,
//! morphed in place by Datastar.

use std::collections::HashMap;
use std::fmt::Write as _;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use nu_engine::command_prelude::*;
use nu_protocol::{
    record, shell_error::generic::GenericError, ByteStream, ByteStreamType, Category, PipelineData,
    ShellError, Signature, Span, SyntaxShape, Type, Value,
};
use portable_pty::{native_pty_system, Child as PortableChild, CommandBuilder, MasterPty, PtySize};
use wezterm_surface::hyperlink::Rule;
use wezterm_term::{
    color::{ColorAttribute, ColorPalette},
    CellAttributes, Intensity, Line, StableRowIndex, Terminal, TerminalConfiguration, TerminalSize,
    Underline,
};

use crate::bus::Bus;

// --- wezterm-term plumbing --------------------------------------------------

/// Lines of scrollback retained per pty session, server-side. Kept in sync
/// with the browser-side `scrollback:` option on `new Terminal({...})` via
/// the `$HTTP_NU.pty_scrollback_lines` const (see `engine::set_http_nu_const`),
/// which `sessions.html` templates into its constructor call. Changing this
/// number changes both sides at once.
pub const SCROLLBACK_LINES: usize = 3000;

/// Minimal TerminalConfiguration impl. Overrides only what we care about:
/// the color palette (required to render SGR), and `scrollback_size` so the
/// server-side history matches what the browser is willing to display.
#[derive(Debug, Default)]
struct MinimalConfig;

impl TerminalConfiguration for MinimalConfig {
    fn color_palette(&self) -> ColorPalette {
        ColorPalette::default()
    }

    fn scrollback_size(&self) -> usize {
        SCROLLBACK_LINES
    }
}

/// Writer wrapper that delegates through the same Arc<Mutex<...>> the rest of
/// the session uses. wezterm-term's auto-replies (DA1/DA2/DSR) always go
/// straight to the pty slave, since the browser is no longer a VT emulator
/// in projection mode -- it only renders the screen state we send it.
struct SharedWriter {
    inner: Arc<Mutex<Box<dyn Write + Send>>>,
}

impl Write for SharedWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.inner.lock().unwrap().write(buf)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.lock().unwrap().flush()
    }
}

/// Cheap structural equality on the attribute bits we render. CellAttributes
/// implements PartialEq, which compares all bits (including hyperlinks and
/// image refs we don't care about), so use a narrower check.
fn attrs_equiv(a: &CellAttributes, b: &CellAttributes) -> bool {
    a.attribute_bits_equal(b)
        && a.foreground() == b.foreground()
        && a.background() == b.background()
}

/// Map any palette index to xterm's canonical RGB.
/// 0..=15 is the standard 16-color palette (matches term.css `.f0..f15`),
/// 16..=231 is the 6x6x6 color cube, 232..=255 is the 24-step grayscale.
/// Used directly when emitting reverse-video cells (where we can't use the
/// `.fN`/`.bN` classes because the swap forces inline styles), and for
/// 256-color cells in the normal path.
fn palette_to_rgb(i: u8) -> (u8, u8, u8) {
    const PALETTE_16: [(u8, u8, u8); 16] = [
        (0x00, 0x00, 0x00),
        (0xcd, 0x00, 0x00),
        (0x00, 0xcd, 0x00),
        (0xcd, 0xcd, 0x00),
        (0x1e, 0x90, 0xff),
        (0xcd, 0x00, 0xcd),
        (0x00, 0xcd, 0xcd),
        (0xe5, 0xe5, 0xe5),
        (0x4d, 0x4d, 0x4d),
        (0xff, 0x54, 0x54),
        (0x54, 0xff, 0x54),
        (0xff, 0xff, 0x54),
        (0x54, 0x54, 0xff),
        (0xff, 0x54, 0xff),
        (0x54, 0xff, 0xff),
        (0xff, 0xff, 0xff),
    ];
    if i < 16 {
        return PALETTE_16[i as usize];
    }
    if i < 232 {
        let n = i - 16;
        let r = (n / 36) % 6;
        let g = (n / 6) % 6;
        let b = n % 6;
        let to_v = |c: u8| if c == 0 { 0 } else { 55 + c * 40 };
        return (to_v(r), to_v(g), to_v(b));
    }
    let l = 8u16 + (i as u16 - 232) * 10;
    let l = l.min(255) as u8;
    (l, l, l)
}

/// Append a CSS color declaration for `prop` (color / background) into
/// `out`, handling all four ColorAttribute variants. `default_var` is the
/// CSS variable name (e.g. "--term-fg") to use when the attribute is
/// Default; pass an empty string to skip emission entirely for the default
/// case (which is what the non-reverse path wants -- it relies on CSS
/// inheritance from the body).
fn append_color_inline(out: &mut String, prop: &str, c: ColorAttribute, default_var: &str) {
    match c {
        ColorAttribute::Default => {
            if !default_var.is_empty() {
                let _ = write!(out, "{prop}:var({default_var});");
            }
        }
        ColorAttribute::PaletteIndex(i) => {
            let (r, g, b) = palette_to_rgb(i);
            let _ = write!(out, "{prop}:#{r:02x}{g:02x}{b:02x};");
        }
        ColorAttribute::TrueColorWithDefaultFallback(rgb)
        | ColorAttribute::TrueColorWithPaletteFallback(rgb, _) => {
            let r = (rgb.0 * 255.0).round() as u8;
            let g = (rgb.1 * 255.0).round() as u8;
            let b = (rgb.2 * 255.0).round() as u8;
            let _ = write!(out, "{prop}:#{r:02x}{g:02x}{b:02x};");
        }
    }
}

/// Append CSS class fragments + inline style for a cell attribute set.
/// Bold/italic/underline/reverse/strikethrough become single-char classes.
/// Palette indices 0..16 become `f0`..`f15` / `b0`..`b15` so users can
/// theme the canonical 16 via CSS. Anything else (palette 16..=255,
/// truecolor) goes inline as `style="color:#rrggbb;..."`. Most TUIs lean
/// on the 16 palette, so the class-based path covers the common case and
/// brotli eats the repetition of the inline-style fallbacks.
fn cell_class_and_style(attrs: &CellAttributes) -> (String, String) {
    let mut classes = String::new();
    let mut style = String::new();

    match attrs.intensity() {
        Intensity::Bold => classes.push_str(" sb"),
        Intensity::Half => classes.push_str(" sd"),
        Intensity::Normal => {}
    }
    if attrs.italic() {
        classes.push_str(" si");
    }
    match attrs.underline() {
        Underline::None => {}
        _ => classes.push_str(" su"),
    }
    if attrs.invisible() {
        classes.push_str(" sx");
    }
    if attrs.strikethrough() {
        classes.push_str(" ss");
    }

    if attrs.reverse() {
        // Reverse video: swap foreground and background. Classes can't be
        // used here because the swap forces both color and background to be
        // explicit -- a `.f1` class would otherwise set color to red even
        // though we want the original background as the new foreground.
        // Default fg/bg map to CSS variables so the theme stays in charge.
        append_color_inline(&mut style, "color", attrs.background(), "--term-bg");
        append_color_inline(&mut style, "background", attrs.foreground(), "--term-fg");
    } else {
        // Normal path: classes for the 16-palette (themable via CSS),
        // inline RGB for 256-color and truecolor.
        match attrs.foreground() {
            ColorAttribute::Default => {}
            ColorAttribute::PaletteIndex(i) if i < 16 => {
                let _ = write!(classes, " f{i}");
            }
            other => append_color_inline(&mut style, "color", other, ""),
        }
        match attrs.background() {
            ColorAttribute::Default => {}
            ColorAttribute::PaletteIndex(i) if i < 16 => {
                let _ = write!(classes, " b{i}");
            }
            other => append_color_inline(&mut style, "background", other, ""),
        }
    }

    (classes, style)
}

/// Escape a string for use inside HTML text. Just the four characters that
/// matter inside `<span>...</span>` plus quote in case it ever leaks.
fn html_escape(s: &str, out: &mut String) {
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(ch),
        }
    }
}

/// URL detection rules for bare (non-OSC-8) text. Same patterns wezterm's
/// own default set is built from (wezterm-surface): an explicit-scheme URL
/// and a bare email mapped to `mailto:`. Compiled once. The renderer feeds
/// these to `Line::scan_and_create_hyperlinks` so a printed URL becomes a
/// clickable link even when the program didn't emit an OSC 8 escape.
fn hyperlink_rules() -> &'static [Rule] {
    static RULES: OnceLock<Vec<Rule>> = OnceLock::new();
    RULES
        .get_or_init(|| {
            vec![
                Rule::new(r"\b\w+://(?:[\w.-]+)\.[a-z]{2,15}\S*\b", "$0").unwrap(),
                Rule::new(r"\b\w+@[\w-]+(\.[\w-]+)+\b", "mailto:$0").unwrap(),
            ]
        })
        .as_slice()
}

/// Attach implicit-hyperlink attributes for any text matching `hyperlink_rules`
/// to the logical lines whose stable id changed since `since`. wezterm groups
/// wrapped physical rows into one logical line (and `apply_hyperlink_rules`
/// writes the attribute back onto each physical row's cells), so a URL that
/// wraps across the right edge is linked across the rows it spans. Returns the
/// current seqno to pass as `since` next time; per-line scanned bits mean only
/// genuinely-changed lines re-scan. Runs on the live screen in the reader
/// thread, so the per-frame `pty view` clones inherit the attributes for free.
fn scan_hyperlinks(term: &mut Terminal, since: usize) -> usize {
    let seqno = term.current_seqno();
    let screen = term.screen_mut();
    let base = screen.phys_to_stable_row_index(0);
    let total = screen.scrollback_rows() as StableRowIndex;
    if total == 0 {
        return seqno;
    }
    let changed = screen.get_changed_stable_rows(base..base + total, since);
    if let (Some(&lo), Some(&hi)) = (changed.first(), changed.last()) {
        screen.for_each_logical_line_in_stable_range_mut(lo..hi + 1, |_, lines| {
            Line::apply_hyperlink_rules(hyperlink_rules(), lines);
            true
        });
    }
    seqno
}

/// Return the URI to use as an `href`, or None if its scheme isn't one we'll
/// make clickable. OSC 8 can carry any scheme (including `javascript:` and
/// `data:`), so gate every link through this allowlist before it reaches the
/// DOM. Our implicit rules only ever emit http/https/mailto anyway.
fn safe_href(uri: &str) -> Option<&str> {
    let u = uri.trim();
    let ok = ["http://", "https://", "mailto:"]
        .iter()
        .any(|p| u.len() >= p.len() && u.as_bytes()[..p.len()].eq_ignore_ascii_case(p.as_bytes()));
    ok.then_some(u)
}

/// True when a cell's glyph can't be trusted to advance exactly its column
/// width in the browser font, so it must be pinned in a fixed-width box.
/// Plain single-scalar text in the loaded monospace face advances 1ch; a wide
/// glyph (width 2: CJK, emoji) or a multi-scalar grapheme (emoji ZWJ
/// sequence, base+combining marks) may render at some other width and shove
/// the rest of the row. Single-scalar box-drawing/Latin glyphs stay bare:
/// the pinned monospace face covers them at uniform advance.
fn cell_needs_box(glyph: &str, width: usize) -> bool {
    width != 1 || glyph.chars().count() > 1
}

/// Render one row's HTML into `out` as
/// `<div class="row" id="{target}-r-{stable}">...</div>`. Cells are
/// run-length encoded into `<span class="...">` runs sharing the same
/// attribute set; default-attr runs are emitted bare to save bytes.
///
/// The id is scoped to the grid target so multiple panes' rows can't
/// collide on the same id -- which would otherwise let a diff patch's
/// default-outer `document.getElementById` match the wrong pane's row and
/// bleed content across terminals. Used by both the full-frame render
/// (first SSE patch) and the per-row diff emit (subsequent patches).
fn render_row_into(
    out: &mut String,
    target: &str,
    line: &wezterm_term::Line,
    cols: usize,
    stable: StableRowIndex,
    default_attrs: &CellAttributes,
) {
    let _ = write!(out, "<div class=\"row\" id=\"{target}-r-{stable}\">");

    // One token per column, built by streaming `visible_cells` left to right.
    // Real gaps (and the line's trailing remainder) fill with default spaces;
    // a wide cell's continuation column is skipped by advancing `expected`
    // past its width, so no pad space ever leaks into it.
    struct Tok {
        text: String,
        attrs: CellAttributes,
        boxed: bool,
        width: usize,
        href: Option<String>,
    }
    let space = |attrs: &CellAttributes| Tok {
        text: " ".to_string(),
        attrs: attrs.clone(),
        boxed: false,
        width: 1,
        href: None,
    };
    let mut toks: Vec<Tok> = Vec::with_capacity(cols);
    let mut expected = 0usize;
    for cell_ref in line.visible_cells() {
        let col = cell_ref.cell_index();
        if col >= cols {
            break;
        }
        // A column already covered by a preceding wide cell's span (its
        // continuation column) would only reach here if visible_cells ever
        // yielded it; skip it so we never double-emit or misalign.
        if col < expected {
            continue;
        }
        while expected < col {
            toks.push(space(default_attrs));
            expected += 1;
        }
        let width = cell_ref.width().max(1);
        let s = cell_ref.str();
        let glyph = if s.is_empty() {
            " ".to_string()
        } else {
            s.to_string()
        };
        let href = cell_ref
            .attrs()
            .hyperlink()
            .and_then(|h| safe_href(h.uri()))
            .map(str::to_string);
        toks.push(Tok {
            boxed: cell_needs_box(&glyph, width),
            text: glyph,
            attrs: cell_ref.attrs().clone(),
            width,
            href,
        });
        expected = col + width;
    }
    while expected < cols {
        toks.push(space(default_attrs));
        expected += 1;
    }

    // Run-length merge: adjacent tokens sharing visual attrs AND link target
    // collapse under one wrapper -- an `<a>` when linked, a `<span>` when
    // styled, else bare text. Inside a run, trusted cells contribute bare
    // escaped text while untrusted (wide / multi-scalar) cells nest a
    // fixed-width `.wc` box so the font can't shift the row; color and
    // decoration reach the box through CSS inheritance.
    let mut i = 0;
    while i < toks.len() {
        let a = &toks[i];
        let mut j = i + 1;
        while j < toks.len() && attrs_equiv(&a.attrs, &toks[j].attrs) && a.href == toks[j].href {
            j += 1;
        }
        let (classes, style) = cell_class_and_style(&a.attrs);
        let linked = a.href.is_some();
        let styled = !classes.is_empty() || !style.is_empty();

        if linked {
            out.push_str("<a class=\"c");
            out.push_str(&classes);
            out.push('"');
            if !style.is_empty() {
                let _ = write!(out, " style=\"{style}\"");
            }
            out.push_str(" href=\"");
            html_escape(a.href.as_deref().unwrap(), out);
            out.push_str("\" target=\"_blank\" rel=\"noopener noreferrer\">");
        } else if styled {
            out.push_str("<span class=\"c");
            out.push_str(&classes);
            out.push('"');
            if !style.is_empty() {
                let _ = write!(out, " style=\"{style}\"");
            }
            out.push('>');
        }

        for t in &toks[i..j] {
            if t.boxed {
                let _ = write!(out, "<span class=\"wc\" style=\"--w:{}\">", t.width);
                html_escape(&t.text, out);
                out.push_str("</span>");
            } else {
                html_escape(&t.text, out);
            }
        }

        if linked {
            out.push_str("</a>");
        } else if styled {
            out.push_str("</span>");
        }
        i = j;
    }
    out.push_str("</div>");
}

/// Render the cursor overlay element. Lives inside the grid container, gets
/// its position from CSS custom properties so the only thing that crosses
/// the wire on a cursor move is the style attribute (~20 bytes per patch).
fn render_cursor_into(out: &mut String, target: &str, row: usize, col: usize) {
    let _ = write!(
        out,
        "<div class=\"cursor\" id=\"{target}-cursor\" style=\"--cursor-row:{row};--cursor-col:{col}\"></div>"
    );
}

/// Render the entire grid (cursor + all rows) as one HTML blob.
///
/// **Production uses `render_full_from_snap` + `emit_diff` via
/// `PtyViewCommand::run` instead** -- that path takes one term-lock pass
/// per frame and emits per-row diffs after the first frame. This helper
/// stays around for the unit tests that pin the stable-id contract by
/// driving a Terminal directly and parsing the rendered HTML.
#[cfg(test)]
fn render_grid_html(term: &mut Terminal, target: &str) -> String {
    scan_hyperlinks(term, 0);
    let size = term.get_size();
    let cols = size.cols;
    let phys_rows = size.rows;
    let cursor = term.cursor_pos();
    let screen = term.screen();
    let total = screen.scrollback_rows();
    let visible_start = total.saturating_sub(phys_rows);
    let lines = screen.lines_in_phys_range(0..total);
    let stable_base = screen.phys_to_stable_row_index(0);
    let cursor_row = visible_start + cursor.y as usize;
    let cursor_col = cursor.x;
    let default_attrs = CellAttributes::default();
    let mut out = String::new();
    let _ = write!(
        out,
        "<div id=\"{target}\" data-cols=\"{cols}\" data-rows=\"{phys_rows}\" data-total=\"{total}\">"
    );
    render_cursor_into(&mut out, target, cursor_row, cursor_col);
    for (row_idx, line) in lines.iter().enumerate() {
        let stable = stable_base + row_idx as StableRowIndex;
        render_row_into(&mut out, target, line, cols, stable, &default_attrs);
    }
    out.push_str("</div>");
    out
}

/// Append a JSON string literal (with surrounding quotes) for `s` into `out`.
fn json_string(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

// --- session bookkeeping ----------------------------------------------------

const PTY_EVENTS_TOPIC: &str = "pty.events";

struct PtySession {
    master: Box<dyn MasterPty + Send>,
    // Shared with the wezterm-term Terminal (for DA1/DA2/DSR auto-replies)
    // and with `pty write` (for user input). Both contend on the same Mutex,
    // which is fine -- this is a low-throughput interactive path.
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    child: Box<dyn PortableChild + Send + Sync>,
    meta: HashMap<String, Value>,
    // Canonical virtual screen. Fed by the reader thread, snapshotted by
    // `pty view` subscribers.
    term: Arc<Mutex<Terminal>>,
    // Generation counter + condvar. The reader thread bumps the counter
    // after each `advance_bytes` and notifies all waiters. Every `pty view`
    // subscriber holds its own `last_seen_gen` and wakes when this advances,
    // then renders the current screen. Many subscribers per sid are fine --
    // notify_all wakes them all.
    dirty: Arc<(Mutex<u64>, Condvar)>,
    // ms since epoch of the most recent write to this session's stdin. Seeded
    // to creation time so a freshly-spawned session sorts above quiet ones.
    // Bumped by `bump_last_input`, read by `pty list` so the sidebar can
    // order tabs by recent activity.
    last_input_ms: AtomicU64,
    // Carried so `bump_last_input` can publish a `touched` event when this
    // session's bump moves it above any other session in the sort order.
    bus: Arc<Bus>,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Bump this session's `last_input_ms` to now. If the bump moves it above
/// every other session's timestamp (i.e. the sort order's top sid changed),
/// publish `pty.events {event: "touched", sid}` so subscribers re-render.
/// Quiet bumps (this sid was already top) are skipped to keep the bus quiet
/// under sustained typing in the foreground tab.
fn bump_last_input(sid: &str) {
    let now = now_ms();
    let bus_to_notify = {
        let map = sessions().lock().unwrap();
        let Some(session) = map.get(sid) else {
            return;
        };
        let prev = session.last_input_ms.swap(now, Ordering::Relaxed);
        let was_top = map
            .iter()
            .filter(|(k, _)| k.as_str() != sid)
            .all(|(_, s)| s.last_input_ms.load(Ordering::Relaxed) <= prev);
        if was_top {
            None
        } else {
            Some(session.bus.clone())
        }
    };
    if let Some(bus) = bus_to_notify {
        let span = Span::unknown();
        bus.publish(
            PTY_EVENTS_TOPIC,
            Value::record(
                record! {
                    "event" => Value::string("touched", span),
                    "sid" => Value::string(sid, span),
                },
                span,
            ),
        );
    }
}

fn sessions() -> &'static Mutex<HashMap<String, PtySession>> {
    static SESSIONS: OnceLock<Mutex<HashMap<String, PtySession>>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[derive(Debug)]
pub(crate) enum WriteInputError {
    NotFound,
    Io(std::io::Error),
}

/// Single entry point for writing user input into a pty session. Used by the
/// handler-layer fast-path for POST /pty/input (which skips the nushell eval
/// thread) and by `pty write` (the nushell-side equivalent). Both callers
/// route through here so the bump + ordering ping happens in exactly one
/// place. The writer's Mutex is shared with the wezterm-term auto-reply
/// path; the lock is held only across this single write_all + flush.
pub(crate) fn write_input(sid: &str, bytes: &[u8]) -> Result<(), WriteInputError> {
    let writer = {
        let map = sessions().lock().unwrap();
        let session = map.get(sid).ok_or(WriteInputError::NotFound)?;
        session.writer.clone()
    };
    let mut w = writer.lock().unwrap();
    w.write_all(bytes).map_err(WriteInputError::Io)?;
    let _ = w.flush();
    drop(w);
    bump_last_input(sid);
    Ok(())
}

#[allow(clippy::result_large_err)]
fn err(span: Span, msg: impl Into<String>, label: impl Into<String>) -> ShellError {
    ShellError::Generic(GenericError::new(msg.into(), label.into(), span))
}

// --- pty open ---------------------------------------------------------------

#[derive(Clone)]
pub struct PtyOpenCommand {
    bus: Arc<Bus>,
}

impl PtyOpenCommand {
    pub fn new(bus: Arc<Bus>) -> Self {
        Self { bus }
    }
}

impl Command for PtyOpenCommand {
    fn name(&self) -> &str {
        "pty open"
    }

    fn description(&self) -> &str {
        "Open a pseudo-terminal session and return its sid. With --embedded, fork http-nu and run nu's REPL in the child instead of execing an external command."
    }

    fn signature(&self) -> Signature {
        Signature::build("pty open")
            .optional(
                "cmd",
                SyntaxShape::String,
                "command to spawn (ignored with --embedded)",
            )
            .named(
                "args",
                SyntaxShape::List(Box::new(SyntaxShape::String)),
                "command arguments",
                None,
            )
            .named(
                "cols",
                SyntaxShape::Int,
                "initial columns (default 80)",
                None,
            )
            .named("rows", SyntaxShape::Int, "initial rows (default 24)", None)
            .switch(
                "embedded",
                "fork http-nu and run nu's REPL in-process (no external nu binary)",
                None,
            )
            .input_output_types(vec![(Type::Nothing, Type::String)])
            .category(Category::Custom("http".into()))
    }

    fn run(
        &self,
        engine_state: &EngineState,
        stack: &mut Stack,
        call: &Call,
        _input: PipelineData,
    ) -> Result<PipelineData, ShellError> {
        let head = call.head;
        let cmd: Option<String> = call.opt(engine_state, stack, 0)?;
        let args: Option<Vec<String>> = call.get_flag(engine_state, stack, "args")?;
        let cols: Option<i64> = call.get_flag(engine_state, stack, "cols")?;
        let rows: Option<i64> = call.get_flag(engine_state, stack, "rows")?;
        let embedded = call.has_flag(engine_state, stack, "embedded")?;

        let size = PtySize {
            cols: cols.unwrap_or(80) as u16,
            rows: rows.unwrap_or(24) as u16,
            pixel_width: 0,
            pixel_height: 0,
        };

        let (session, reader) = if embedded {
            open_embedded(engine_state, size, head, self.bus.clone())?
        } else {
            let cmd = cmd.ok_or_else(|| err(head, "missing cmd", "required without --embedded"))?;
            open_exec(&cmd, args, size, head, self.bus.clone())?
        };

        let sid = scru128::new().to_string();
        let (cols_n, rows_n) = (size.cols as i64, size.rows as i64);
        let term = session.term.clone();
        let dirty = session.dirty.clone();
        sessions().lock().unwrap().insert(sid.clone(), session);

        // Spawn the reader thread now (after insert) so it can self-reap
        // by sid when the child eventually exits.
        spawn_reader(sid.clone(), reader, term, dirty, self.bus.clone());

        self.bus.publish(
            PTY_EVENTS_TOPIC,
            Value::record(
                record! {
                    "event" => Value::string("created", head),
                    "sid" => Value::string(&sid, head),
                    "cols" => Value::int(cols_n, head),
                    "rows" => Value::int(rows_n, head),
                },
                head,
            ),
        );

        Ok(PipelineData::Value(Value::string(sid, head), None))
    }
}

#[allow(clippy::result_large_err)]
fn open_exec(
    cmd: &str,
    args: Option<Vec<String>>,
    size: PtySize,
    span: Span,
    bus: Arc<Bus>,
) -> Result<(PtySession, Box<dyn Read + Send>), ShellError> {
    let pair = native_pty_system()
        .openpty(size)
        .map_err(|e| err(span, "openpty failed", e.to_string()))?;

    let mut builder = CommandBuilder::new(cmd);
    if let Some(args) = args {
        for a in args {
            builder.arg(a);
        }
    }
    for (k, v) in std::env::vars() {
        builder.env(k, v);
    }
    builder.env("TERM", "xterm-256color");
    if let Ok(cwd) = std::env::current_dir() {
        builder.cwd(cwd);
    }

    let child = pair
        .slave
        .spawn_command(builder)
        .map_err(|e| err(span, "spawn failed", e.to_string()))?;
    drop(pair.slave);

    let raw_writer = pair
        .master
        .take_writer()
        .map_err(|e| err(span, "take_writer failed", e.to_string()))?;

    let reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| err(span, "clone_reader failed", e.to_string()))?;

    let writer: Arc<Mutex<Box<dyn Write + Send>>> = Arc::new(Mutex::new(raw_writer));

    // Build the wezterm-term Terminal. Its writer is a SharedWriter pointing
    // at the same master pty fd that user input writes to. Auto-replies for
    // DA1/DA2/DSR queries always go straight to the slave -- the browser is
    // no longer a VT emulator in projection mode.
    let term_writer = SharedWriter {
        inner: writer.clone(),
    };
    let term = Terminal::new(
        TerminalSize {
            rows: size.rows as usize,
            cols: size.cols as usize,
            pixel_width: 0,
            pixel_height: 0,
            dpi: 0,
        },
        Arc::new(MinimalConfig),
        "http-nu-pty",
        env!("CARGO_PKG_VERSION"),
        Box::new(term_writer),
    );
    let term = Arc::new(Mutex::new(term));
    let dirty = Arc::new((Mutex::new(0u64), Condvar::new()));

    let session = PtySession {
        master: pair.master,
        writer,
        child,
        meta: HashMap::new(),
        term,
        dirty,
        last_input_ms: AtomicU64::new(now_ms()),
        bus,
    };
    Ok((session, reader))
}

/// Drain the pty master fd on a dedicated blocking thread. Each chunk is fed
/// to the wezterm-term Terminal (which updates the canonical virtual screen
/// state AND emits DA/DSR auto-replies straight to the slave through the
/// shared writer). After advancing, the dirty counter is bumped and all
/// `pty view` subscribers are notified so they can re-render. When `read`
/// returns 0 the child has exited; the thread removes the session from the
/// map (if `pty close` didn't already) and publishes `died` on the bus.
fn spawn_reader(
    sid: String,
    mut reader: Box<dyn Read + Send>,
    term: Arc<Mutex<Terminal>>,
    dirty: Arc<(Mutex<u64>, Condvar)>,
    bus: Arc<Bus>,
) {
    let dump_path = std::env::var("HTTP_NU_PTY_DUMP").ok();
    std::thread::spawn(move || {
        let mut dump_file = dump_path.as_deref().and_then(|p| {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(p)
                .ok()
        });
        let mut buf = [0u8; 4096];
        // Seqno of the last hyperlink scan; advanced each chunk so only lines
        // changed by this chunk get re-scanned.
        let mut scan_seqno = 0usize;
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if let Some(f) = dump_file.as_mut() {
                        let _ = writeln!(f, "[{sid}] {}", escape_bytes(&buf[..n]));
                        let _ = f.flush();
                    }
                    {
                        let mut term_guard = term.lock().unwrap();
                        term_guard.advance_bytes(&buf[..n]);
                        // Detect bare URLs on the lines just changed, before
                        // waking view subscribers so their clones carry the
                        // hyperlink attributes.
                        scan_seqno = scan_hyperlinks(&mut term_guard, scan_seqno);
                    }
                    let (lock, cv) = &*dirty;
                    {
                        let mut g = lock.lock().unwrap();
                        *g = g.wrapping_add(1);
                    }
                    cv.notify_all();
                }
                Err(e) => {
                    use std::io::ErrorKind;
                    if matches!(e.kind(), ErrorKind::Interrupted) {
                        continue;
                    }
                    break;
                }
            }
        }
        // EOF on master = child exited. If the session is still in the map,
        // we beat `pty close` to it: reap, then publish `died`. If the entry
        // is already gone, the close command handled cleanup + published
        // `deleted`, so don't publish anything here.
        let removed = sessions().lock().unwrap().remove(&sid);
        if let Some(mut s) = removed {
            // Wake any view subscribers so they exit promptly rather than
            // sitting on the condvar until next heartbeat.
            let (lock, cv) = &*s.dirty;
            {
                let mut g = lock.lock().unwrap();
                *g = g.wrapping_add(1);
            }
            cv.notify_all();

            let code = match s.child.wait() {
                Ok(es) => es.exit_code() as i64,
                Err(_) => -1,
            };
            let span = Span::unknown();
            bus.publish(
                PTY_EVENTS_TOPIC,
                Value::record(
                    record! {
                        "event" => Value::string("died", span),
                        "sid" => Value::string(sid, span),
                        "code" => Value::int(code, span),
                    },
                    span,
                ),
            );
        }
    });
}

/// Render a byte slice with ANSI escapes / control chars made visible, so
/// HTTP_NU_PTY_DUMP=/tmp/pty.log dumps are readable in `tail`.
fn escape_bytes(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for &c in b {
        match c {
            0x1b => s.push_str("\\e"),
            b'\n' => s.push_str("\\n"),
            b'\r' => s.push_str("\\r"),
            b'\t' => s.push_str("\\t"),
            0x20..=0x7e => s.push(c as char),
            _ => s.push_str(&format!("\\x{c:02x}")),
        }
    }
    s
}

#[allow(clippy::result_large_err)]
fn open_embedded(
    _engine_state: &EngineState,
    size: PtySize,
    span: Span,
    bus: Arc<Bus>,
) -> Result<(PtySession, Box<dyn Read + Send>), ShellError> {
    // Self-re-exec into our own `repl` subcommand. The fork-no-exec variant
    // ran fine for trivial use but silently dropped output from bare
    // externals (e.g. `^ls`) due to interactions between http-nu's
    // multi-threaded Rust runtime state and nushell's foreground-job
    // setpgid+tcsetpgrp dance. Exec'ing our own binary gives the embedded
    // REPL a clean process state, with all of http-nu's custom commands
    // still registered (because `repl` rebuilds them in its main).
    //
    // On Linux, exec `/proc/self/exe` directly rather than the string from
    // current_exe(): if the on-disk binary has been replaced (e.g. a cargo
    // rebuild during a live server), readlink('/proc/self/exe') reports
    // the path with " (deleted)" appended and execve fails ENOENT. The
    // symlink itself still resolves to the running inode at exec time,
    // so the child gets the same binary the parent is running.
    #[cfg(target_os = "linux")]
    let self_exe = "/proc/self/exe".to_string();
    #[cfg(not(target_os = "linux"))]
    let self_exe = std::env::current_exe()
        .map_err(|e| err(span, "current_exe failed", e.to_string()))?
        .into_os_string()
        .into_string()
        .map_err(|_| err(span, "current_exe path not utf-8", ""))?;
    open_exec(&self_exe, Some(vec!["repl".to_string()]), size, span, bus)
}

// --- pty write --------------------------------------------------------------

#[derive(Clone)]
pub struct PtyWriteCommand;

impl PtyWriteCommand {
    pub fn new() -> Self {
        Self
    }
}

impl Default for PtyWriteCommand {
    fn default() -> Self {
        Self::new()
    }
}

impl Command for PtyWriteCommand {
    fn name(&self) -> &str {
        "pty write"
    }

    fn description(&self) -> &str {
        "Write piped bytes/string to the pty session's stdin"
    }

    fn signature(&self) -> Signature {
        Signature::build("pty write")
            .required("sid", SyntaxShape::String, "session id")
            .input_output_types(vec![
                (Type::Binary, Type::Nothing),
                (Type::String, Type::Nothing),
                (Type::Nothing, Type::Nothing),
            ])
            .category(Category::Custom("http".into()))
    }

    fn run(
        &self,
        engine_state: &EngineState,
        stack: &mut Stack,
        call: &Call,
        input: PipelineData,
    ) -> Result<PipelineData, ShellError> {
        let head = call.head;
        let sid: String = call.req(engine_state, stack, 0)?;

        let bytes: Vec<u8> = match input {
            PipelineData::Empty => Vec::new(),
            PipelineData::Value(v, _) => crate::response::value_to_bytes(v),
            PipelineData::ByteStream(stream, _) => stream
                .into_bytes()
                .map_err(|e| err(head, "read stream", e.to_string()))?,
            PipelineData::ListStream(_, _) => {
                return Err(err(head, "list stream input not supported", ""));
            }
        };

        if bytes.is_empty() {
            return Ok(PipelineData::Empty);
        }

        write_input(&sid, &bytes).map_err(|e| match e {
            WriteInputError::NotFound => err(head, format!("no pty session: {sid}"), ""),
            WriteInputError::Io(e) => err(head, "pty write failed", e.to_string()),
        })?;

        Ok(PipelineData::Empty)
    }
}

// --- pty resize -------------------------------------------------------------

#[derive(Clone)]
pub struct PtyResizeCommand {
    bus: Arc<Bus>,
}

impl PtyResizeCommand {
    pub fn new(bus: Arc<Bus>) -> Self {
        Self { bus }
    }
}

impl Command for PtyResizeCommand {
    fn name(&self) -> &str {
        "pty resize"
    }

    fn description(&self) -> &str {
        "Resize the pty (TIOCSWINSZ + SIGWINCH to the foreground group)"
    }

    fn signature(&self) -> Signature {
        Signature::build("pty resize")
            .required("sid", SyntaxShape::String, "session id")
            .required("cols", SyntaxShape::Int, "columns")
            .required("rows", SyntaxShape::Int, "rows")
            .input_output_types(vec![(Type::Nothing, Type::Nothing)])
            .category(Category::Custom("http".into()))
    }

    fn run(
        &self,
        engine_state: &EngineState,
        stack: &mut Stack,
        call: &Call,
        _input: PipelineData,
    ) -> Result<PipelineData, ShellError> {
        let head = call.head;
        let sid: String = call.req(engine_state, stack, 0)?;
        let cols: i64 = call.req(engine_state, stack, 1)?;
        let rows: i64 = call.req(engine_state, stack, 2)?;

        {
            let map = sessions().lock().unwrap();
            let session = map
                .get(&sid)
                .ok_or_else(|| err(head, format!("no pty session: {sid}"), ""))?;
            session
                .master
                .resize(PtySize {
                    cols: cols as u16,
                    rows: rows as u16,
                    pixel_width: 0,
                    pixel_height: 0,
                })
                .map_err(|e| err(head, "pty resize failed", e.to_string()))?;
            session.term.lock().unwrap().resize(TerminalSize {
                rows: rows as usize,
                cols: cols as usize,
                pixel_width: 0,
                pixel_height: 0,
                dpi: 0,
            });
            // Wake subscribers so the next frame reflects the new grid
            // dimensions even if the program isn't generating output.
            let (lock, cv) = &*session.dirty;
            {
                let mut g = lock.lock().unwrap();
                *g = g.wrapping_add(1);
            }
            cv.notify_all();
        }

        self.bus.publish(
            PTY_EVENTS_TOPIC,
            Value::record(
                record! {
                    "event" => Value::string("resized", head),
                    "sid" => Value::string(sid, head),
                    "cols" => Value::int(cols, head),
                    "rows" => Value::int(rows, head),
                },
                head,
            ),
        );

        Ok(PipelineData::Empty)
    }
}

// --- pty view ---------------------------------------------------------------

/// Coalescing window: after a dirty notify wakes us, sleep this long before
/// rendering so a burst of pty output (e.g. `cat large.txt`) collapses into
/// one frame rather than one per chunk.
const VIEW_COALESCE: Duration = Duration::from_millis(16);

/// How long to wait on the condvar before emitting an SSE comment heartbeat.
/// Keeps intermediaries (proxies, browser) from closing an idle connection,
/// and bounds the time a stale subscriber holds the term lock.
const VIEW_HEARTBEAT: Duration = Duration::from_secs(15);

#[derive(Clone)]
pub struct PtyViewCommand;

impl PtyViewCommand {
    pub fn new() -> Self {
        Self
    }
}

impl Default for PtyViewCommand {
    fn default() -> Self {
        Self::new()
    }
}

impl Command for PtyViewCommand {
    fn name(&self) -> &str {
        "pty view"
    }

    fn description(&self) -> &str {
        "Stream the pty's visible screen as morph-able HTML grid frames over SSE (Datastar datastar-patch-elements events)"
    }

    fn signature(&self) -> Signature {
        Signature::build("pty view")
            .required("sid", SyntaxShape::String, "session id")
            .named(
                "target",
                SyntaxShape::String,
                "id of the morph-target element (default 'grid'); use a unique id per pane when several views render at once",
                None,
            )
            .switch(
                "no-signals",
                "suppress the termCols/termRows/termTitle signal patch (use when multiple views would otherwise collide on the same global signals)",
                None,
            )
            .input_output_types(vec![(Type::Nothing, Type::String)])
            .category(Category::Custom("http".into()))
    }

    fn run(
        &self,
        engine_state: &EngineState,
        stack: &mut Stack,
        call: &Call,
        _input: PipelineData,
    ) -> Result<PipelineData, ShellError> {
        let head = call.head;
        let sid: String = call.req(engine_state, stack, 0)?;
        let target: String = call
            .get_flag(engine_state, stack, "target")?
            .unwrap_or_else(|| "grid".to_string());
        let no_signals = call.has_flag(engine_state, stack, "no-signals")?;

        // Resolve term + dirty handles once. The session may go away while we
        // stream; we treat that as natural EOF by checking `sessions()` each
        // iteration and bailing if the sid is gone.
        let (term, dirty) = {
            let map = sessions().lock().unwrap();
            let session = map
                .get(&sid)
                .ok_or_else(|| err(head, format!("no pty session: {sid}"), ""))?;
            (session.term.clone(), session.dirty.clone())
        };

        let mut last_gen: u64 = 0;
        let mut sent_initial = false;
        // Last (cols, rows, title) emitted as signals; only re-emit the
        // patch-signals event when one changes so keystroke frames don't
        // carry a redundant signal patch.
        let mut last_meta: Option<(usize, usize, String)> = None;
        // Per-subscriber diff state, set on the first frame and advanced on
        // each subsequent one. `last_seqno` is wezterm's monotonic counter
        // (a `usize` alias for `SequenceNo`); we ask the screen which lines
        // changed since this value and emit only those. `last_stable_base`
        // and `last_max_stable` track the [start, end) of stable ids
        // currently mounted in the client so we can compute purges (top
        // shrinks) and new rows (bottom grows). `last_cursor` short-circuits
        // a cursor patch when nothing moved.
        let mut last_seqno: usize = 0;
        let mut last_stable_base: StableRowIndex = 0;
        let mut last_max_stable: StableRowIndex = 0;
        let mut last_cursor: (usize, usize) = (0, 0);
        // wezterm keeps separate `lines`/seqno counters for the primary and
        // alternate screens, so switching between them invalidates our diff
        // state entirely. Track which one we sampled last; a mismatch
        // triggers a full re-emit so the client lands on the new screen
        // instead of seeing alt content overlay the first N rows of stale
        // main content (the symptom under `bat`/`less`/`vim`).
        let mut last_alt: bool = false;
        let sid_owned = sid.clone();

        let stream = ByteStream::from_fn(
            head,
            engine_state.signals().clone(),
            ByteStreamType::String,
            move |buffer: &mut Vec<u8>| {
                // Bail when the session is gone (closed or child exited).
                if !sessions().lock().unwrap().contains_key(&sid_owned) {
                    return Ok(false);
                }

                if sent_initial {
                    // Wait for the dirty counter to advance or for the
                    // heartbeat timeout to fire. notify_all from the reader
                    // thread wakes us with the new generation.
                    let (lock, cv) = &*dirty;
                    let mut guard = lock.lock().unwrap();
                    let mut emitted_heartbeat = false;
                    while *guard == last_gen {
                        let (g, timeout) = cv.wait_timeout(guard, VIEW_HEARTBEAT).unwrap();
                        guard = g;
                        if timeout.timed_out() {
                            // Emit an SSE comment so proxies don't drop us.
                            buffer.extend_from_slice(b": hb\n\n");
                            emitted_heartbeat = true;
                            break;
                        }
                    }
                    drop(guard);
                    if emitted_heartbeat {
                        return Ok(true);
                    }
                    // Coalesce: sleep briefly so a burst of chunks collapses
                    // into one frame rather than one frame per chunk.
                    std::thread::sleep(VIEW_COALESCE);
                }

                // Snapshot the latest generation + everything we need to
                // either render the full first frame or compute the diff,
                // under a single term lock. Lines come out cloned so we can
                // render outside the lock.
                let (lock, _cv) = &*dirty;
                let gen_now = *lock.lock().unwrap();
                let snap: ViewSnapshot = {
                    let term_guard = term.lock().unwrap();
                    let size = term_guard.get_size();
                    let cols = size.cols;
                    let phys_rows = size.rows;
                    let cursor = term_guard.cursor_pos();
                    let title = term_guard.get_title().to_string();
                    let seqno = term_guard.current_seqno();
                    let alt_active = term_guard.is_alt_screen_active();
                    let screen = term_guard.screen();
                    let total = screen.scrollback_rows();
                    let visible_start = total.saturating_sub(phys_rows);
                    let stable_base = screen.phys_to_stable_row_index(0);
                    let max_stable = stable_base + total as StableRowIndex;
                    let cursor_row = visible_start + cursor.y as usize;
                    let cursor_col = cursor.x;
                    // A screen flip (primary <-> alt) invalidates the diff
                    // basis: the two screens have independent line storage
                    // and seqnos, so `get_changed_stable_rows(..last_seqno)`
                    // would lie about what the client needs to see. Treat
                    // the flip as if it were a fresh subscription.
                    let screen_flipped = sent_initial && alt_active != last_alt;
                    // Changed rows that the client still has: query only the
                    // overlap of the current stable range with what we last
                    // sent. New rows (above `last_max_stable`) are handled
                    // by the append path; purged rows fall off the front of
                    // the overlap so they don't appear here.
                    let changed_end = max_stable.min(last_max_stable);
                    let changed = if sent_initial && !screen_flipped && changed_end > stable_base {
                        screen.get_changed_stable_rows(stable_base..changed_end, last_seqno)
                    } else {
                        Vec::new()
                    };
                    let lines = screen.lines_in_phys_range(0..total);
                    ViewSnapshot {
                        cols,
                        rows: phys_rows,
                        title,
                        seqno,
                        alt_active,
                        screen_flipped,
                        stable_base,
                        max_stable,
                        cursor_row,
                        cursor_col,
                        lines,
                        changed,
                    }
                };
                last_gen = gen_now;

                if !sent_initial || snap.screen_flipped {
                    // First frame OR primary/alt screen flipped under us:
                    // hand the client the whole new grid in one outer morph
                    // so idiomorph drops anything no longer present and the
                    // diff state starts fresh.
                    let frame = render_full_from_snap(&snap, &target);
                    emit_patch_elements(buffer, &frame);
                    sent_initial = true;
                } else {
                    emit_diff(buffer, &snap, &target, last_stable_base, last_max_stable);
                    let cursor_now = (snap.cursor_row, snap.cursor_col);
                    if cursor_now != last_cursor {
                        let mut html = String::with_capacity(96);
                        render_cursor_into(&mut html, &target, cursor_now.0, cursor_now.1);
                        emit_patch_elements(buffer, &html);
                    }
                }

                last_seqno = snap.seqno;
                last_stable_base = snap.stable_base;
                last_max_stable = snap.max_stable;
                last_alt = snap.alt_active;
                last_cursor = (snap.cursor_row, snap.cursor_col);

                // Surface dims + title as signals so the client binds them
                // declaratively (status line, document.title) instead of
                // observing DOM attributes. Only emit on change, and never
                // when several views share the page (--no-signals) since the
                // signals are global and would clobber each other.
                if !no_signals {
                    let meta = (snap.cols, snap.rows, snap.title.clone());
                    if last_meta.as_ref() != Some(&meta) {
                        emit_patch_signals(buffer, meta.0, meta.1, &meta.2);
                        last_meta = Some(meta);
                    }
                }
                Ok(true)
            },
        );

        Ok(PipelineData::ByteStream(stream, None))
    }
}

/// Everything PtyViewCommand's stream loop needs out of one term-lock pass:
/// metadata + the cloned scrollback lines (for rendering outside the lock)
/// + the precomputed changed-rows set. Built fresh each iteration.
struct ViewSnapshot {
    cols: usize,
    rows: usize,
    title: String,
    seqno: usize,
    /// True when the terminal is currently rendering its alternate screen
    /// (vim, less, htop, etc. switch into it with `\x1b[?1049h`). The
    /// alt and primary screens have independent storage + seqnos, so a
    /// transition between them requires a full re-emit.
    alt_active: bool,
    /// True when this snapshot's `alt_active` differs from the subscriber's
    /// last sample; the view loop treats this as "first frame all over
    /// again" and ships the whole grid instead of a diff.
    screen_flipped: bool,
    stable_base: StableRowIndex,
    max_stable: StableRowIndex,
    cursor_row: usize,
    cursor_col: usize,
    lines: Vec<wezterm_term::Line>,
    /// Stable ids whose lines' content changed since the subscriber's last
    /// seqno, intersected with the rows still mounted in the client. Empty
    /// on a `screen_flipped` snapshot since the diff is unusable then.
    changed: Vec<StableRowIndex>,
}

/// Render the full grid HTML from a snapshot (cursor + every retained row).
/// Used for the first SSE patch of a subscriber so the client lands in a
/// consistent state; thereafter all frames are diffs.
fn render_full_from_snap(snap: &ViewSnapshot, target: &str) -> String {
    let default_attrs = CellAttributes::default();
    let mut out = String::new();
    let _ = write!(
        out,
        "<div id=\"{target}\" data-cols=\"{cols}\" data-rows=\"{rows}\" data-total=\"{total}\">",
        cols = snap.cols,
        rows = snap.rows,
        total = snap.lines.len(),
    );
    render_cursor_into(&mut out, target, snap.cursor_row, snap.cursor_col);
    for (idx, line) in snap.lines.iter().enumerate() {
        let stable = snap.stable_base + idx as StableRowIndex;
        render_row_into(&mut out, target, line, snap.cols, stable, &default_attrs);
    }
    out.push_str("</div>");
    out
}

/// Emit the per-frame diff bundle: a `mode: remove` selector list for any
/// stable ids that purged off the top, default-mode-outer patches for any
/// existing rows whose line seqno advanced, and a `mode: append` block of
/// rows that appeared at the bottom. Cursor moves are handled separately
/// by the caller.
fn emit_diff(
    buffer: &mut Vec<u8>,
    snap: &ViewSnapshot,
    target: &str,
    last_stable_base: StableRowIndex,
    last_max_stable: StableRowIndex,
) {
    let default_attrs = CellAttributes::default();

    // Rows that purged off the top since last frame -- comma-joined so one
    // SSE event removes them all at once. The id is grid-scoped
    // (`{target}-r-{stable}`) so two panes can't fight over the same id.
    if snap.stable_base > last_stable_base {
        let mut selector = String::new();
        for id in last_stable_base..snap.stable_base {
            if !selector.is_empty() {
                selector.push(',');
            }
            let _ = write!(selector, "#{target}-r-{id}");
        }
        emit_patch(buffer, Some(&selector), Some("remove"), &[]);
    }

    // Existing rows whose content changed. Default mode is `outer` and
    // datastar matches each element by id, so no selector is needed -- the
    // ids inside the HTML drive the morph.
    if !snap.changed.is_empty() {
        let mut htmls: Vec<String> = Vec::with_capacity(snap.changed.len());
        for &id in &snap.changed {
            let idx = (id - snap.stable_base) as usize;
            if let Some(line) = snap.lines.get(idx) {
                let mut s = String::with_capacity(snap.cols * 2 + 64);
                render_row_into(&mut s, target, line, snap.cols, id, &default_attrs);
                htmls.push(s);
            }
        }
        if !htmls.is_empty() {
            emit_patch(buffer, None, None, &htmls);
        }
    }

    // New rows at the bottom: append into the grid container. last_max_stable
    // can lag the current top (after a fast burst that's also purged the
    // start of what we'd been about to add); clamp to the current base.
    let new_start = last_max_stable.max(snap.stable_base);
    if snap.max_stable > new_start {
        let mut htmls: Vec<String> = Vec::with_capacity((snap.max_stable - new_start) as usize);
        for id in new_start..snap.max_stable {
            let idx = (id - snap.stable_base) as usize;
            if let Some(line) = snap.lines.get(idx) {
                let mut s = String::with_capacity(snap.cols * 2 + 64);
                render_row_into(&mut s, target, line, snap.cols, id, &default_attrs);
                htmls.push(s);
            }
        }
        if !htmls.is_empty() {
            let selector = format!("#{target}");
            emit_patch(buffer, Some(&selector), Some("append"), &htmls);
        }
    }
}

/// General `datastar-patch-elements` SSE event. Any of `selector`, `mode`,
/// `elements` may be omitted; datastar defaults `mode` to `outer` and (for
/// outer/replace) matches by element id, so a default-mode patch with no
/// selector morphs each top-level element in `elements` into its same-id
/// counterpart in the DOM.
///
/// All elements are concatenated onto a **single** `data: elements <...>`
/// line. Per the SSE spec multiple `data:` lines in the same event get
/// joined with `\n` by the browser, and datastar's parser feeds the result
/// to `DOMParser` -- which would turn that `\n` between top-level siblings
/// into a text node child of the fragment. With `white-space: pre` on the
/// grid, that text node renders as a literal blank line between every
/// appended/morphed row. Rendered rows never contain a literal newline
/// (we don't pretty-print), so a single concatenated line is safe.
fn emit_patch(
    buffer: &mut Vec<u8>,
    selector: Option<&str>,
    mode: Option<&str>,
    elements: &[String],
) {
    buffer.extend_from_slice(b"event: datastar-patch-elements\n");
    if let Some(s) = selector {
        buffer.extend_from_slice(b"data: selector ");
        buffer.extend_from_slice(s.as_bytes());
        buffer.push(b'\n');
    }
    if let Some(m) = mode {
        buffer.extend_from_slice(b"data: mode ");
        buffer.extend_from_slice(m.as_bytes());
        buffer.push(b'\n');
    }
    if !elements.is_empty() {
        buffer.extend_from_slice(b"data: elements ");
        for el in elements {
            // Defensive: a literal newline inside a single element gets
            // turned into a `\ndata: elements ` continuation so the
            // browser's SSE join puts it back as a `\n` *inside* that
            // element, not a separator between elements.
            if el.contains('\n') {
                let mut first = true;
                for line in el.split('\n') {
                    if !first {
                        buffer.extend_from_slice(b"\ndata: elements ");
                    }
                    first = false;
                    buffer.extend_from_slice(line.as_bytes());
                }
            } else {
                buffer.extend_from_slice(el.as_bytes());
            }
        }
        buffer.push(b'\n');
    }
    buffer.push(b'\n');
}

/// Default-outer single-element patch: idiomorph finds the existing element
/// by id and morphs in place. Used for the first full-grid frame and for
/// cursor-move patches.
fn emit_patch_elements(buffer: &mut Vec<u8>, html: &str) {
    emit_patch(buffer, None, None, std::slice::from_ref(&html.to_string()));
}

/// Emit a `datastar-patch-signals` event carrying the frame's dimensions
/// and OSC title, so the client surfaces them via signal bindings rather
/// than reading DOM attributes. Signals are prefixed `term*` so they don't
/// collide with surface-level signals (e.g. the sessions window `$title`).
fn emit_patch_signals(buffer: &mut Vec<u8>, cols: usize, rows: usize, title: &str) {
    let mut signals = String::new();
    let _ = write!(signals, "{{termCols:{cols},termRows:{rows},termTitle:");
    json_string(&mut signals, title);
    signals.push('}');
    buffer.extend_from_slice(b"event: datastar-patch-signals\n");
    buffer.extend_from_slice(b"data: signals ");
    buffer.extend_from_slice(signals.as_bytes());
    buffer.extend_from_slice(b"\n\n");
}

// --- pty close --------------------------------------------------------------

#[derive(Clone)]
pub struct PtyCloseCommand {
    bus: Arc<Bus>,
}

impl PtyCloseCommand {
    pub fn new(bus: Arc<Bus>) -> Self {
        Self { bus }
    }
}

impl Command for PtyCloseCommand {
    fn name(&self) -> &str {
        "pty close"
    }

    fn description(&self) -> &str {
        "Close a pty session: kill child, drop fds"
    }

    fn signature(&self) -> Signature {
        Signature::build("pty close")
            .required("sid", SyntaxShape::String, "session id")
            .input_output_types(vec![(Type::Nothing, Type::Nothing)])
            .category(Category::Custom("http".into()))
    }

    fn run(
        &self,
        engine_state: &EngineState,
        stack: &mut Stack,
        call: &Call,
        _input: PipelineData,
    ) -> Result<PipelineData, ShellError> {
        let head = call.head;
        let sid: String = call.req(engine_state, stack, 0)?;
        let session = sessions().lock().unwrap().remove(&sid);
        if let Some(mut s) = session {
            let _ = s.child.kill();
            let _ = s.child.wait();
            self.bus.publish(
                PTY_EVENTS_TOPIC,
                Value::record(
                    record! {
                        "event" => Value::string("deleted", head),
                        "sid" => Value::string(sid, head),
                    },
                    head,
                ),
            );
        }
        Ok(PipelineData::Empty)
    }
}

// --- pty meta ---------------------------------------------------------------
//
// Free-form per-session metadata (label, etc). `pty meta set` mutates the
// session's meta map and pings the `pty.events` bus topic so any subscribed
// UI can react.

#[derive(Clone)]
pub struct PtyMetaSetCommand {
    bus: Arc<Bus>,
}

impl PtyMetaSetCommand {
    pub fn new(bus: Arc<Bus>) -> Self {
        Self { bus }
    }
}

impl Command for PtyMetaSetCommand {
    fn name(&self) -> &str {
        "pty meta set"
    }

    fn description(&self) -> &str {
        "Set a free-form meta value on a pty session; publishes a ping on pty.events"
    }

    fn signature(&self) -> Signature {
        Signature::build("pty meta set")
            .required("sid", SyntaxShape::String, "session id")
            .required("key", SyntaxShape::String, "meta key")
            .required("value", SyntaxShape::Any, "meta value")
            .input_output_types(vec![(Type::Nothing, Type::Nothing)])
            .category(Category::Custom("http".into()))
    }

    fn run(
        &self,
        engine_state: &EngineState,
        stack: &mut Stack,
        call: &Call,
        _input: PipelineData,
    ) -> Result<PipelineData, ShellError> {
        let head = call.head;
        let sid: String = call.req(engine_state, stack, 0)?;
        let key: String = call.req(engine_state, stack, 1)?;
        let value: Value = call.req(engine_state, stack, 2)?;

        {
            let mut map = sessions().lock().unwrap();
            let session = map
                .get_mut(&sid)
                .ok_or_else(|| err(head, format!("no pty session: {sid}"), ""))?;
            session.meta.insert(key.clone(), value.clone());
        }

        let event = Value::record(
            record! {
                "event" => Value::string("meta", head),
                "sid" => Value::string(sid, head),
                "key" => Value::string(key, head),
                "value" => value,
            },
            head,
        );
        self.bus.publish(PTY_EVENTS_TOPIC, event);

        Ok(PipelineData::Empty)
    }
}

// --- pty list ---------------------------------------------------------------

#[derive(Clone)]
pub struct PtyListCommand;

impl PtyListCommand {
    pub fn new() -> Self {
        Self
    }
}

impl Default for PtyListCommand {
    fn default() -> Self {
        Self::new()
    }
}

impl Command for PtyListCommand {
    fn name(&self) -> &str {
        "pty list"
    }

    fn description(&self) -> &str {
        "List all live pty sessions as [{sid, cols, rows, meta}, ...]"
    }

    fn signature(&self) -> Signature {
        Signature::build("pty list")
            .input_output_types(vec![(Type::Nothing, Type::Any)])
            .category(Category::Custom("http".into()))
    }

    fn run(
        &self,
        _engine_state: &EngineState,
        _stack: &mut Stack,
        call: &Call,
        _input: PipelineData,
    ) -> Result<PipelineData, ShellError> {
        let head = call.head;
        let map = sessions().lock().unwrap();
        let mut rows: Vec<Value> = Vec::with_capacity(map.len());
        for (sid, s) in map.iter() {
            let size = s.master.get_size().ok();
            let cols = size.as_ref().map(|sz| sz.cols as i64).unwrap_or(0);
            let rs = size.as_ref().map(|sz| sz.rows as i64).unwrap_or(0);
            let mut meta_rec = nu_protocol::Record::new();
            for (k, v) in &s.meta {
                meta_rec.push(k.clone(), v.clone());
            }
            let last_input = s.last_input_ms.load(Ordering::Relaxed) as i64;
            rows.push(Value::record(
                record! {
                    "sid" => Value::string(sid, head),
                    "cols" => Value::int(cols, head),
                    "rows" => Value::int(rs, head),
                    "meta" => Value::record(meta_rec, head),
                    "last_input_ms" => Value::int(last_input, head),
                },
                head,
            ));
        }
        Ok(Value::list(rows, head).into_pipeline_data())
    }
}

#[derive(Clone)]
pub struct PtyMetaGetCommand;

impl PtyMetaGetCommand {
    pub fn new() -> Self {
        Self
    }
}

impl Default for PtyMetaGetCommand {
    fn default() -> Self {
        Self::new()
    }
}

impl Command for PtyMetaGetCommand {
    fn name(&self) -> &str {
        "pty meta get"
    }

    fn description(&self) -> &str {
        "Read pty session meta. With no key, returns the whole record; with a key, returns its value (or nothing)."
    }

    fn signature(&self) -> Signature {
        Signature::build("pty meta get")
            .required("sid", SyntaxShape::String, "session id")
            .optional(
                "key",
                SyntaxShape::String,
                "specific key; omit for whole record",
            )
            .input_output_types(vec![(Type::Nothing, Type::Any)])
            .category(Category::Custom("http".into()))
    }

    fn run(
        &self,
        engine_state: &EngineState,
        stack: &mut Stack,
        call: &Call,
        _input: PipelineData,
    ) -> Result<PipelineData, ShellError> {
        let head = call.head;
        let sid: String = call.req(engine_state, stack, 0)?;
        let key: Option<String> = call.opt(engine_state, stack, 1)?;

        let map = sessions().lock().unwrap();
        let session = map
            .get(&sid)
            .ok_or_else(|| err(head, format!("no pty session: {sid}"), ""))?;

        let out = match key {
            Some(k) => session
                .meta
                .get(&k)
                .cloned()
                .unwrap_or(Value::nothing(head)),
            None => {
                let mut rec = nu_protocol::Record::new();
                for (k, v) in &session.meta {
                    rec.push(k.clone(), v.clone());
                }
                Value::record(rec, head)
            }
        };
        Ok(out.into_pipeline_data())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a small terminal and feed it `\r\n`-terminated lines.
    fn term_with_lines(rows: usize, cols: usize, range: std::ops::Range<usize>) -> Terminal {
        let mut term = Terminal::new(
            TerminalSize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
                dpi: 0,
            },
            Arc::new(MinimalConfig),
            "test",
            "0",
            Box::new(Vec::<u8>::new()),
        );
        for i in range {
            term.advance_bytes(format!("L{i}\r\n").as_bytes());
        }
        term
    }

    /// Parse `render_grid_html` output into (row id, trimmed text) pairs in
    /// document order. Strips all tags so cell spans collapse to their text.
    /// Tests pass `target = "grid"` so row ids look like `id="grid-r-{N}"`.
    fn rows_of(html: &str) -> Vec<(isize, String)> {
        let mut out = Vec::new();
        let marker = "<div class=\"row\" id=\"grid-r-";
        let mut rest = html;
        while let Some(pos) = rest.find(marker) {
            rest = &rest[pos + marker.len()..];
            let id_end = rest.find("\">").unwrap();
            let id: isize = rest[..id_end].parse().unwrap();
            rest = &rest[id_end + 2..];
            let close = rest.find("</div>").unwrap();
            let inner = &rest[..close];
            // Drop every <...> tag, keep the text between them.
            let mut text = String::new();
            let mut in_tag = false;
            for c in inner.chars() {
                match c {
                    '<' => in_tag = true,
                    '>' => in_tag = false,
                    _ if !in_tag => text.push(c),
                    _ => {}
                }
            }
            out.push((id, text.trim_end().to_string()));
            rest = &rest[close + "</div>".len()..];
        }
        out
    }

    #[test]
    fn row_id_is_stable_across_scrollback_purge() {
        // Fill well past the scrollback cap so the oldest lines purge.
        let mut term = term_with_lines(4, 12, 0..SCROLLBACK_LINES + 100);
        let before = rows_of(&render_grid_html(&mut term, "grid"));

        // Feed more lines, forcing further purges off the top.
        for i in SCROLLBACK_LINES + 100..SCROLLBACK_LINES + 150 {
            term.advance_bytes(format!("L{i}\r\n").as_bytes());
        }
        let after = rows_of(&render_grid_html(&mut term, "grid"));

        // The top id must have advanced -- a purge actually happened.
        assert!(
            after[0].0 > before[0].0,
            "expected top row id to advance after purge: {} -> {}",
            before[0].0,
            after[0].0
        );

        // Every line of text present in both frames must keep the same id.
        // (With the old phys-index scheme the ids would all shift by 50.)
        let after_by_text: std::collections::HashMap<&str, isize> =
            after.iter().map(|(id, t)| (t.as_str(), *id)).collect();
        let mut shared = 0;
        for (id, text) in &before {
            if text.is_empty() {
                continue;
            }
            if let Some(&aid) = after_by_text.get(text.as_str()) {
                assert_eq!(aid, *id, "row {text:?} changed id across purge");
                shared += 1;
            }
        }
        assert!(
            shared > 100,
            "too few shared rows to be meaningful: {shared}"
        );
    }

    /// Build a terminal of `rows x cols` and feed raw bytes once. No trailing
    /// newline, so the cursor stays on the line we just wrote -- which lets us
    /// read its column off the rendered cursor div.
    fn term_with_bytes(rows: usize, cols: usize, bytes: &[u8]) -> Terminal {
        let mut term = Terminal::new(
            TerminalSize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
                dpi: 0,
            },
            Arc::new(MinimalConfig),
            "test",
            "0",
            Box::new(Vec::<u8>::new()),
        );
        term.advance_bytes(bytes);
        term
    }

    /// Pull `--cursor-col:{N}` out of the rendered cursor div.
    fn cursor_col_of(html: &str) -> usize {
        let marker = "--cursor-col:";
        let pos = html.find(marker).expect("cursor div present");
        let rest = &html[pos + marker.len()..];
        let end = rest.find(['"', ';']).unwrap();
        rest[..end].parse().unwrap()
    }

    /// A double-width glyph (CJK, emoji) is pinned in a fixed-width `.wc` box
    /// spanning its two columns, with no pad space leaking into the hidden
    /// continuation column. wezterm gives U+4E2D (zhong, "middle") cell width
    /// 2; `render_row_into` advances past the continuation column rather than
    /// filling it, so for "ab<zhong>cd" the rendered text is exactly the five
    /// typed glyphs, and the glyph sits in a `--w:2` box so the browser font
    /// can't shift the rest of the row. The cursor stays at wezterm's column 6
    /// (a, b, zhong = 2 cols, c, d) and now lines up with the visible text.
    #[test]
    fn render_row_wide_char_no_pad() {
        let zhong = '\u{4E2D}';
        let mut term = term_with_bytes(2, 12, "ab\u{4E2D}cd".as_bytes());
        let html = render_grid_html(&mut term, "grid");
        let rows = rows_of(&html);

        // No spurious pad: the five typed glyphs and nothing more.
        let (_, ref text) = rows[0];
        assert_eq!(
            text, "ab\u{4E2D}cd",
            "no pad space in the continuation column"
        );
        assert_eq!(text.chars().count(), 5, "exactly the five typed glyphs");

        // The wide glyph is followed directly by 'c'.
        let after_glyph: String = text
            .chars()
            .skip_while(|&c| c != zhong)
            .skip(1)
            .take(1)
            .collect();
        assert_eq!(after_glyph, "c", "no cell between the wide glyph and 'c'");

        // The wide glyph is boxed at its two-column width so its font advance
        // can't push the row sideways.
        assert!(
            html.contains("<span class=\"wc\" style=\"--w:2\">\u{4E2D}</span>"),
            "wide glyph pinned in a --w:2 box, got:\n{html}"
        );

        // Cursor matches wezterm's column model and now aligns with the text.
        assert_eq!(cursor_col_of(&html), 6, "cursor at wezterm column 6");
    }

    /// Pull every `href="..."` value out of the rendered HTML, in order.
    fn hrefs_of(html: &str) -> Vec<String> {
        let mut out = Vec::new();
        let marker = "href=\"";
        let mut rest = html;
        while let Some(pos) = rest.find(marker) {
            rest = &rest[pos + marker.len()..];
            let end = rest.find('"').unwrap();
            out.push(rest[..end].to_string());
            rest = &rest[end + 1..];
        }
        out
    }

    /// OSC 8 explicit hyperlinks: a program wraps text in
    /// `ESC ] 8 ; ; URI ST ... ESC ] 8 ; ; ST`. wezterm-term parses this and
    /// tags the enclosed cells with a hyperlink attribute; the renderer should
    /// emit those cells inside an `<a href>`.
    #[test]
    fn render_osc8_hyperlink_becomes_anchor() {
        let bytes = b"\x1b]8;;https://example.com\x1b\\Click\x1b]8;;\x1b\\";
        let mut term = term_with_bytes(2, 40, bytes);
        let html = render_grid_html(&mut term, "grid");
        assert!(
            html.contains("<a "),
            "expected an anchor element for the OSC 8 link, got:\n{html}"
        );
        assert_eq!(
            hrefs_of(&html),
            vec!["https://example.com".to_string()],
            "anchor should carry the OSC 8 URI"
        );
        let rows = rows_of(&html);
        assert_eq!(
            rows[0].1, "Click",
            "link text should render as the cell text"
        );
    }

    /// Implicit detection: a bare URL printed as plain text carries no OSC 8
    /// attribute, so the renderer must scan the line against URL rules and
    /// linkify the match itself.
    #[test]
    fn render_bare_url_is_detected_and_linked() {
        let mut term = term_with_bytes(2, 40, b"see https://example.com ok");
        let html = render_grid_html(&mut term, "grid");
        assert!(
            html.contains("<a "),
            "expected an anchor element for the detected bare URL, got:\n{html}"
        );
        assert!(
            hrefs_of(&html).iter().any(|h| h == "https://example.com"),
            "detected URL should appear as an href"
        );
    }

    /// A URL that wraps across the right edge is one logical line in wezterm.
    /// Scanning groups the wrapped physical rows and links the whole URL, so
    /// the full target (including the tail on the next row) appears as the
    /// href -- per-physical-line scanning would only catch the head on row 0
    /// and leave the tail an unlinked fragment.
    #[test]
    fn render_wrapped_url_is_linked_across_rows() {
        // 20 cols: "https://example.com/" fills row 0 exactly, "abcdef" wraps
        // to row 1.
        let full = "https://example.com/abcdef";
        let mut term = term_with_bytes(4, 20, full.as_bytes());
        let html = render_grid_html(&mut term, "grid");
        let hrefs = hrefs_of(&html);
        assert!(
            hrefs.iter().any(|h| h == full),
            "wrapped URL should link to the full target {full:?}, got hrefs {hrefs:?}"
        );
        // Both rows carry the link (head on row 0, tail on row 1).
        assert!(
            hrefs.iter().filter(|h| h.as_str() == full).count() >= 2,
            "both wrapped rows should carry the href, got {hrefs:?}"
        );
    }
}
