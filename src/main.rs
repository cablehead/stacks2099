// nu_protocol::ShellError is a large enum; pty.rs returns it in Result Err
// positions throughout. The vendored engine crate carried this same allow.
#![allow(clippy::result_large_err)]

use std::io::Read;
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::Duration;

use arc_swap::ArcSwap;
use bytes::Bytes;
use clap::Parser;
use http_body_util::{combinators::BoxBody, BodyExt, Empty};
use include_dir::{include_dir, Dir};

mod pty;

type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// The app (serve.nu + www) baked into the binary at compile time. In the
/// default (production) mode we materialize this to a per-user dir and run it,
/// so the binary is self-contained -- no files alongside it. `--dev` ignores
/// this and runs the same tree live from source instead.
static APP_DIR: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/app");

/// Per-user fallback base dir, used only when no --store is given (the app
/// normally unpacks into the store dir). XDG_DATA_HOME, else ~/.local/share,
/// else the temp dir.
fn data_dir() -> PathBuf {
    if let Ok(x) = std::env::var("XDG_DATA_HOME") {
        if !x.is_empty() {
            return PathBuf::from(x).join("stacks2099");
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        if !home.is_empty() {
            return PathBuf::from(home).join(".local/share/stacks2099");
        }
    }
    std::env::temp_dir().join("stacks2099")
}

/// Write the embedded app tree to `dest`, overwriting (idempotent). Cheap --
/// a handful of small files plus the woff2 fonts -- so we re-extract on every
/// production launch and never serve a stale asset after an upgrade.
fn extract_app(dest: &std::path::Path) -> std::io::Result<()> {
    fn walk(dir: &Dir<'_>, dest: &std::path::Path) -> std::io::Result<()> {
        for entry in dir.entries() {
            match entry {
                include_dir::DirEntry::Dir(d) => walk(d, dest)?,
                include_dir::DirEntry::File(f) => {
                    let out = dest.join(f.path());
                    if let Some(parent) = out.parent() {
                        std::fs::create_dir_all(parent)?;
                    }
                    std::fs::write(out, f.contents())?;
                }
            }
        }
        Ok(())
    }
    std::fs::create_dir_all(dest)?;
    walk(&APP_DIR, dest)
}
use http_nu::{
    engine::{script_to_engine, HttpNuOptions},
    handler::{handle, AppConfig},
    listener::TlsConfig,
    logging::{
        init_broadcast, log_reloaded, log_started, log_stop_timed_out, log_stopped, log_stopping,
        run_human_handler, run_jsonl_handler, shutdown, StartupOptions,
    },
    response::value_to_json,
    store::Store,
    Engine, Listener,
};
use hyper::service::service_fn;
use hyper_util::rt::{TokioExecutor, TokioIo};
use hyper_util::server::conn::auto::Builder as HttpConnectionBuilder;
use hyper_util::server::graceful::GracefulShutdown;
use notify::{RecursiveMode, Watcher};
use tokio::signal;
use tokio::sync::mpsc;

#[derive(Parser, Debug)]
#[clap(version)]
struct Args {
    #[command(subcommand)]
    command: Option<Command>,

    /// Address to listen on [HOST]:PORT or <PATH> for Unix domain socket
    #[clap(value_parser)]
    addr: Option<String>,

    /// Path to PEM file containing certificate and private key
    #[clap(short, long)]
    tls: Option<PathBuf>,

    /// Load a Nushell plugin from the specified path (can be used multiple times)
    #[clap(long = "plugin", global = true, value_parser)]
    plugins: Vec<PathBuf>,

    /// Log format: human (live-updating) or jsonl (structured)
    #[clap(long, default_value = "human")]
    log_format: LogFormat,

    /// Path to store directory (enables .cat, .append, .cas commands)
    #[cfg(feature = "cross-stream")]
    #[clap(long, help_heading = "cross.stream")]
    store: Option<PathBuf>,

    /// Enable actors, services, and actions
    #[cfg(feature = "cross-stream")]
    #[clap(long, requires = "store", help_heading = "cross.stream")]
    services: bool,

    /// Expose API on additional address ([HOST]:PORT or iroh://)
    #[cfg(feature = "cross-stream")]
    #[clap(
        long,
        requires = "store",
        value_name = "ADDR",
        help_heading = "cross.stream"
    )]
    expose: Option<String>,

    /// Development mode: run the app (app/serve.nu) from the source tree with
    /// hot-reload instead of the copy baked into the binary; also relaxes
    /// security defaults (e.g. omits the Secure flag on cookies). ADDR and
    /// --store are still required.
    #[clap(long, global = true)]
    dev: bool,

    /// Trust proxies from these CIDR ranges for X-Forwarded-For parsing
    #[clap(long = "trust-proxy", value_name = "CIDR")]
    trust_proxies: Vec<ipnet::IpNet>,

    /// Set NU_LIB_DIRS for module resolution (can be repeated)
    #[clap(short = 'I', long = "include-path", global = true, value_name = "PATH")]
    include_paths: Vec<PathBuf>,
}

#[derive(Clone, Debug, Default, clap::ValueEnum)]
enum LogFormat {
    #[default]
    Human,
    Jsonl,
}

#[derive(clap::Subcommand, Debug)]
enum Command {
    /// Run an interactive nushell REPL with http-nu's custom commands
    /// registered. Used by `pty open --embedded` via self-re-exec so that
    /// the embedded REPL gets a clean Rust process and externals work.
    Repl,

    /// Evaluate a Nushell script with http-nu commands and exit
    Eval {
        /// Script file to evaluate, or '-' to read from stdin
        #[clap(value_parser)]
        file: Option<String>,

        /// Evaluate script from command line
        #[clap(short = 'c', long = "commands")]
        commands: Option<String>,

        /// Path to store directory (enables .cat, .append, .cas commands)
        #[cfg(feature = "cross-stream")]
        #[clap(long)]
        store: Option<PathBuf>,

        /// Define $DATASTAR_JS_PATH and related Datastar consts
        #[clap(long)]
        datastar: bool,
    },
}

/// Creates and configures the base engine with all commands, signals, and ctrlc handler.
fn create_base_engine(
    interrupt: Arc<AtomicBool>,
    plugins: &[PathBuf],
    include_paths: &[PathBuf],
    store: Option<&Store>,
    options: &HttpNuOptions,
) -> Result<Engine, Box<dyn std::error::Error + Send + Sync>> {
    let mut engine = Engine::new()?;
    // stacks: build $nu in every engine (eval, serve.nu, repl) so user nu
    // config and parse-time consts can read $nu.*. Upstream Engine::new leaves
    // it unbuilt.
    engine.state.generate_nu_constant();
    engine.add_custom_commands()?;
    register_pty_commands(&mut engine)?;
    engine.set_lib_dirs(include_paths)?;
    engine.set_http_nu_const(options)?;

    for plugin_path in plugins {
        engine.load_plugin(plugin_path)?;
    }

    if let Some(store) = store {
        store.configure_engine(&mut engine)?;
    }

    engine.set_signals(interrupt.clone());
    setup_ctrlc_handler(&engine, interrupt)?;
    Ok(engine)
}

/// Read script from file, convert to engine, send through `tx`. If `watch` is true,
/// spawn a watcher that re-reads, converts, and sends on changes.
async fn file_source(path: &str, watch: bool, base_engine: Engine, tx: mpsc::Sender<Engine>) {
    let content = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("Error reading {path}: {e}");
        std::process::exit(1);
    });

    let script_path = PathBuf::from(path).canonicalize().unwrap_or_else(|e| {
        eprintln!("Error resolving {path}: {e}");
        std::process::exit(1);
    });

    if let Some(engine) = script_to_engine(&base_engine, &content, Some(&script_path)) {
        tx.send(engine).await.expect("channel closed unexpectedly");
    }

    if watch {
        std::thread::spawn(move || {
            let watch_dir = script_path.parent().unwrap_or(&script_path).to_path_buf();

            let (raw_tx, raw_rx) = std::sync::mpsc::channel();

            let mut watcher =
                notify::recommended_watcher(raw_tx).expect("Failed to create watcher");

            watcher
                .watch(&watch_dir, RecursiveMode::Recursive)
                .expect("Failed to watch directory");

            let debounce = Duration::from_millis(100);
            let mut pending_reload = false;

            loop {
                let timeout = if pending_reload {
                    debounce
                } else {
                    Duration::from_secs(86400)
                };

                match raw_rx.recv_timeout(timeout) {
                    Ok(Ok(event)) => {
                        use notify::EventKind;
                        let dominated_by = matches!(
                            event.kind,
                            EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
                        );
                        if dominated_by {
                            pending_reload = true;
                        }
                    }
                    Ok(Err(e)) => {
                        eprintln!("Watch error: {e:?}");
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                        if pending_reload {
                            pending_reload = false;
                            match std::fs::read_to_string(&script_path) {
                                Ok(content) => {
                                    if let Some(engine) =
                                        script_to_engine(&base_engine, &content, Some(&script_path))
                                    {
                                        if tx.blocking_send(engine).is_err() {
                                            break;
                                        }
                                    }
                                }
                                Err(e) => {
                                    eprintln!("Error reading script file: {e}");
                                }
                            }
                        }
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                        break;
                    }
                }
            }
        });
    }
}

/// Read script from stdin, convert to engine, send through `tx`. If `watch` is true,
/// spawn a reader that reads null-terminated scripts for hot reload.
// Unused now that stacks2099 only runs the bundled app (no stdin/`-` source),
// but kept intact rather than excised from the http-nu glue.
#[allow(dead_code)]
async fn stdin_source(watch: bool, base_engine: Engine, tx: mpsc::Sender<Engine>) {
    if watch {
        std::thread::spawn(move || {
            let mut stdin = std::io::stdin().lock();
            let mut buffer = Vec::new();
            let mut byte = [0u8; 1];

            loop {
                buffer.clear();

                // Read until null terminator or EOF
                loop {
                    match stdin.read(&mut byte) {
                        Ok(0) => break, // EOF
                        Ok(_) => {
                            if byte[0] == b'\0' {
                                break;
                            }
                            buffer.push(byte[0]);
                        }
                        Err(e) => {
                            eprintln!("Error reading stdin: {e}");
                            return;
                        }
                    }
                }

                if buffer.is_empty() {
                    break;
                }

                let script = String::from_utf8_lossy(&buffer).into_owned();

                if let Some(engine) = script_to_engine(&base_engine, &script, None) {
                    if tx.blocking_send(engine).is_err() {
                        break;
                    }
                }
            }
        });
    } else {
        let mut content = String::new();
        std::io::stdin()
            .read_to_string(&mut content)
            .expect("Failed to read from stdin");
        if let Some(engine) = script_to_engine(&base_engine, &content, None) {
            tx.send(engine).await.expect("channel closed unexpectedly");
        }
    }
}

/// Register the pty command surface (stacks2099-specific) on top of http-nu's
/// built-ins. The vendored engine registered these inside add_custom_commands,
/// so eval / serve / repl all saw them; mirror that by calling this right after
/// add_custom_commands in each path.
fn register_pty_commands(engine: &mut Engine) -> Result<(), BoxError> {
    // Hoist the bus clone so the command vec doesn't borrow `engine` while
    // add_commands holds it mutably.
    let bus = engine.bus.clone();
    engine.add_commands(vec![
        Box::new(pty::PtyOpenCommand::new(bus.clone())),
        Box::new(pty::PtyWriteCommand::new()),
        Box::new(pty::PtyResizeCommand::new(bus.clone())),
        Box::new(pty::PtyViewCommand::new()),
        Box::new(pty::PtyRawCommand::new()),
        Box::new(pty::PtySnapCommand::new()),
        Box::new(pty::PtyCloseCommand::new(bus.clone())),
        Box::new(pty::PtyMetaSetCommand::new(bus.clone())),
        Box::new(pty::PtyMetaGetCommand::new()),
        Box::new(pty::PtyListCommand::new()),
    ])
}

/// An empty response body in the shape http-nu's `handle` returns, so the pty
/// fast-path and the delegated closure path share one return type.
fn empty_body() -> BoxBody<Bytes, BoxError> {
    Empty::<Bytes>::new()
        .map_err(|never| match never {})
        .boxed()
}

/// Per-request entry: the pty fast-path first, otherwise http-nu's handler.
/// A free async fn (not an inline async block in the service closure) so the
/// closure returns one concrete future, keeping the connection future's
/// lifetime bounds nameable for serve_connection_with_upgrades.
async fn dispatch(
    engine: Arc<ArcSwap<Engine>>,
    remote_addr: Option<std::net::SocketAddr>,
    config: Arc<AppConfig>,
    req: hyper::Request<hyper::body::Incoming>,
) -> Result<hyper::Response<BoxBody<Bytes, BoxError>>, BoxError> {
    // stacks fast-path: a pty keystroke writes straight to the fd instead of
    // spawning an eval thread through the nu closure.
    if req.method() == hyper::Method::POST && req.uri().path() == "/pty/input" {
        return pty_input(req).await;
    }
    handle(engine, remote_addr, config, req).await
}

/// stacks2099 fast-path for `POST /pty/input`: drain the body and write it
/// straight to the pty fd, skipping the nu closure dispatch. A sid is required;
/// without one we 400 rather than 404 so "no sid -> never reaches a pty" stays
/// explicit, and a misrouted POST can't fall through to a user handler.
async fn pty_input(
    req: hyper::Request<hyper::body::Incoming>,
) -> Result<hyper::Response<BoxBody<Bytes, BoxError>>, BoxError> {
    let sid = req
        .uri()
        .query()
        .and_then(|q| {
            url::form_urlencoded::parse(q.as_bytes())
                .find(|(k, _)| k == "sid")
                .map(|(_, v)| v.into_owned())
        })
        .unwrap_or_default();

    let status: u16 = if sid.is_empty() {
        400
    } else {
        match req.into_body().collect().await {
            Err(_) => 500,
            Ok(collected) => match pty::write_input(&sid, &collected.to_bytes()) {
                Ok(()) => 204,
                Err(pty::WriteInputError::NotFound) => 404,
                Err(pty::WriteInputError::Io(_)) => 500,
            },
        }
    };

    Ok(hyper::Response::builder()
        .status(status)
        .body(empty_body())?)
}

async fn serve(
    addr: String,
    tls: Option<PathBuf>,
    mut rx: mpsc::Receiver<Engine>,
    interrupt: Arc<AtomicBool>,
    config: AppConfig,
    start_time: std::time::Instant,
    startup_options: StartupOptions,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let shutdown = shutdown_signal(interrupt.clone());
    tokio::pin!(shutdown);

    // Wait for first valid engine from source, but allow shutdown to interrupt
    let first_engine = tokio::select! {
        engine = rx.recv() => {
            engine.expect("no engine received - source closed without providing a valid engine")
        }
        _ = &mut shutdown => {
            log_stopped();
            return Ok(());
        }
    };

    let engine = Arc::new(ArcSwap::from_pointee(first_engine));

    // Spawn task to receive engines and swap in new ones
    let engine_updater = engine.clone();
    tokio::spawn(async move {
        while let Some(new_engine) = rx.recv().await {
            // Cancel SSE streams on old engine
            engine_updater.load().sse_cancel_token.cancel();
            engine_updater.store(Arc::new(new_engine));
            log_reloaded();
        }
    });

    // Configure TLS if enabled
    let tls_config = if let Some(pem_path) = tls {
        Some(TlsConfig::from_pem(pem_path)?)
    } else {
        None
    };

    let tls_enabled = tls_config.is_some();
    let mut listener = Listener::bind(&addr, tls_config).await?;
    let startup_ms = start_time.elapsed().as_millis();
    let addr_display = {
        let raw = format!("{listener}");
        // Format TCP addresses as clickable URLs, leave Unix sockets as-is
        if raw.starts_with('/') {
            raw
        } else {
            // Strip " (TLS)" suffix from Listener's Display
            let addr = raw.strip_suffix(" (TLS)").unwrap_or(&raw);
            if tls_enabled {
                format!("https://{addr}")
            } else {
                format!("http://{addr}")
            }
        }
    };
    log_started(&addr_display, startup_ms, startup_options);

    // HTTP/1 + HTTP/2 auto-detection builder
    let http_builder = HttpConnectionBuilder::new(TokioExecutor::new());

    // Graceful shutdown tracker for all connections
    let graceful = GracefulShutdown::new();

    // Wrap config in Arc for sharing across connections
    let config = Arc::new(config);

    loop {
        tokio::select! {
            result = listener.accept() => {
                match result {
                    Ok((stream, remote_addr)) => {
                        let io = TokioIo::new(stream);
                        let engine = engine.clone();
                        let config = config.clone();

                        let service = service_fn(move |req| {
                            dispatch(engine.clone(), remote_addr, config.clone(), req)
                        });

                        // serve_connection_with_upgrades supports HTTP/1 and HTTP/2
                        let conn = http_builder.serve_connection_with_upgrades(io, service);

                        // Watch this connection for graceful shutdown
                        let conn = graceful.watch(conn.into_owned());

                        tokio::task::spawn(async move {
                            if let Err(err) = conn.await {
                                // Suppress errors normal for client disconnect
                                if let Some(hyper_err) = err.downcast_ref::<hyper::Error>() {
                                    if hyper_err.is_incomplete_message()
                                        || hyper_err.is_body_write_aborted()
                                    {
                                        return;
                                    }
                                }
                                eprintln!("Connection error: {err}");
                            }
                        });
                    }
                    Err(err) => {
                        eprintln!("Error accepting connection: {err}");
                        continue;
                    }
                }
            }
            _ = &mut shutdown => {
                break;
            }
        }
    }

    // Cancel SSE streams so they don't hold connections open.
    // New connections are no longer accepted (broke out of accept loop above),
    // so SSE clients won't reconnect.
    engine.load().sse_cancel_token.cancel();

    // Graceful shutdown: wait for inflight connections to complete
    let inflight = graceful.count();
    let mut timed_out = false;

    if inflight > 0 {
        log_stopping(inflight);

        tokio::select! {
            _ = graceful.shutdown() => {}
            _ = tokio::time::sleep(Duration::from_secs(10)) => {
                timed_out = true;
            }
        }
    }

    if timed_out {
        log_stop_timed_out();
    } else {
        log_stopped();
    }

    Ok(())
}

async fn shutdown_signal(interrupt: Arc<AtomicBool>) {
    use tokio::time::{interval, Duration};

    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("failed to install signal handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    let interrupt_check = async {
        let mut interval = interval(Duration::from_millis(100));
        loop {
            interval.tick().await;
            if interrupt.load(Ordering::Relaxed) {
                break;
            }
        }
    };

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
        _ = interrupt_check => {},
    }
}

/// Sets up Ctrl-C handling
fn setup_ctrlc_handler(
    engine: &Engine,
    interrupt: Arc<AtomicBool>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    ctrlc::set_handler({
        let interrupt = interrupt.clone();
        let engine_state = engine.state.clone();
        move || {
            interrupt.store(true, Ordering::Relaxed);
            // Kill all active jobs
            if let Ok(mut jobs) = engine_state.jobs.lock() {
                let job_ids: Vec<_> = jobs.iter().map(|(id, _)| id).collect();
                for id in job_ids {
                    let _ = jobs.kill_and_remove(id);
                }
            }
        }
    })?;

    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let args = Args::parse();

    // Set up logging handler based on log format (both spawn dedicated threads)
    let rx = init_broadcast();
    let log_handle = match args.log_format {
        LogFormat::Human => run_human_handler(rx),
        LogFormat::Jsonl => run_jsonl_handler(rx),
    };

    rustls::crypto::aws_lc_rs::default_provider()
        .install_default()
        .expect("failed to install default rustls CryptoProvider");

    // Initialize nu_command's TLS crypto provider
    nu_command::tls::CRYPTO_PROVIDER
        .default()
        .then_some(())
        .expect("failed to set nu_command crypto provider");

    // Set up interrupt signal
    let interrupt = Arc::new(AtomicBool::new(false));

    // Hold a persistent connection to the in-memory sqlite database so that
    // `stor` commands work. The shared-cache in-memory database is destroyed
    // when the last connection closes, so we keep one alive for the lifetime
    // of the process.
    let _stor_db = nu_command::open_connection_in_memory_custom()?;

    // Handle Repl subcommand: build the engine like Eval, then hand off to
    // nushell's interactive REPL. Used by `pty open --embedded` via
    // self-re-exec, so we never run the http server here -- just become nu.
    if let Some(Command::Repl) = args.command {
        // Replicate nushell's terminal::acquire (it's pub(crate) so we can't
        // call it). Ignore SIGTTOU/SIGTTIN/etc so externals can call
        // tcsetpgrp from their pre_exec without being stopped.
        #[cfg(unix)]
        unsafe {
            use nix::sys::signal::{sigaction, SaFlags, SigAction, SigHandler, SigSet, Signal};
            let ignore = SigAction::new(SigHandler::SigIgn, SaFlags::empty(), SigSet::empty());
            let _ = sigaction(Signal::SIGQUIT, &ignore);
            let _ = sigaction(Signal::SIGTSTP, &ignore);
            let _ = sigaction(Signal::SIGTTIN, &ignore);
            let _ = sigaction(Signal::SIGTTOU, &ignore);
        }
        let mut engine = Engine::new()?;
        engine.state.generate_nu_constant();
        engine.add_custom_commands()?;
        register_pty_commands(&mut engine)?;
        engine.set_lib_dirs(&args.include_paths)?;
        engine.set_http_nu_const(&HttpNuOptions::default())?;
        for plugin_path in &args.plugins {
            engine.load_plugin(plugin_path)?;
        }
        engine.set_signals(interrupt.clone());

        // Load the nushell standard library (std, std-rfc, etc.) so user
        // configs that `use std-rfc/kv *` and friends parse cleanly.
        if let Err(e) = nu_std::load_standard_library(&mut engine.state) {
            eprintln!("warning: nu_std::load_standard_library failed: {e:?}");
        }

        // Become an interactive shell: mark interactive + rebuild the $nu
        // constant BEFORE evaluating config, so user env.nu/config.nu can read
        // $nu.* (including parse-time consts) and $nu.is-interactive is accurate.
        engine.state.is_interactive = true;
        engine.state.generate_nu_constant();

        // Build a fresh Stack and bootstrap default env+config, then layer
        // the user's ~/.config/nushell/{env,config}.nu on top (same order
        // stock nushell uses via read_config_file). Restore nushell's stock
        // `print` afterward (http-nu's PrintCommand shadows it and routes
        // to the http log).
        let mut stack = nu_protocol::engine::Stack::new();

        // Stock nushell evaluates default env (which defines $env.ENV_CONVERSIONS
        // with the PATH/Path string<->list converters), then runs
        // convert_env_values BEFORE evaluating the user's env.nu / config.nu.
        // Without that step, $env.PATH stays as a colon-joined string and the
        // user's `$env.PATH = ($env.PATH | append ...)` produces a 2-element
        // list of [original colon-string, appended dir] -- which breaks
        // command resolution.
        let env_kind = nu_utils::ConfigFileKind::Env;
        nu_cli::eval_source(
            &mut engine.state,
            &mut stack,
            env_kind.default().as_bytes(),
            env_kind.name(),
            nu_protocol::PipelineData::empty(),
            false,
        );
        let _ = engine.state.merge_env(&mut stack);
        if let Err(e) = nu_engine::convert_env_values(&mut engine.state, &mut stack) {
            eprintln!("warning: convert_env_values failed: {e:?}");
        }
        for kind in [
            nu_utils::ConfigFileKind::Env,
            nu_utils::ConfigFileKind::Config,
        ] {
            // Default env was already evaluated above; for the user-config
            // pass we only need to layer the user's file on top (if any).
            if kind == nu_utils::ConfigFileKind::Config {
                nu_cli::eval_source(
                    &mut engine.state,
                    &mut stack,
                    kind.default().as_bytes(),
                    kind.name(),
                    nu_protocol::PipelineData::empty(),
                    false,
                );
                let _ = engine.state.merge_env(&mut stack);
            }
            if let Some(dir) = nu_path::nu_config_dir() {
                let path: std::path::PathBuf = dir.into();
                let path = path.join(kind.path());
                if path.is_file() {
                    nu_cli::eval_config_contents(path, &mut engine.state, &mut stack, false);
                }
            }
        }
        {
            let mut ws = nu_protocol::engine::StateWorkingSet::new(&engine.state);
            ws.add_decl(Box::new(nu_cli::Print));
            engine.state.merge_delta(ws.render())?;
        }

        let _ = nu_cli::evaluate_repl(
            &mut engine.state,
            stack,
            None,
            None,
            std::time::Instant::now().into(),
        );
        shutdown();
        log_handle.join().ok();
        return Ok(());
    }

    // Handle subcommands
    if let Some(Command::Eval {
        file,
        commands,
        #[cfg(feature = "cross-stream")]
        store,
        datastar,
    }) = args.command
    {
        let (script, script_path) = match (&file, &commands) {
            (Some(_), Some(_)) => {
                eprintln!("Error: cannot specify both file and --commands");
                std::process::exit(1);
            }
            (None, None) => {
                eprintln!("Error: provide a file or use --commands");
                std::process::exit(1);
            }
            (Some(path), None) if path == "-" => {
                let mut buf = String::new();
                std::io::stdin().read_to_string(&mut buf)?;
                (buf, None)
            }
            (Some(path), None) => {
                let p = PathBuf::from(path).canonicalize()?;
                (std::fs::read_to_string(&p)?, Some(p))
            }
            (None, Some(cmd)) => (cmd.clone(), None),
        };

        let mut engine = Engine::new()?;
        engine.state.generate_nu_constant();
        engine.add_custom_commands()?;
        register_pty_commands(&mut engine)?;
        engine.set_lib_dirs(&args.include_paths)?;

        #[cfg(feature = "cross-stream")]
        let store_path = store.as_ref().map(|p| p.display().to_string());
        #[cfg(not(feature = "cross-stream"))]
        let store_path: Option<String> = None;

        engine.set_http_nu_const(&HttpNuOptions {
            dev: args.dev,
            datastar,
            store: store_path,
            ..Default::default()
        })?;

        #[cfg(feature = "cross-stream")]
        if let Some(ref path) = store {
            let xs_store = xs::store::Store::new(path.clone())?;
            let eval_store = Store::from_inner(xs_store, path.clone());
            eval_store.configure_engine(&mut engine)?;
        }

        for plugin_path in &args.plugins {
            engine.load_plugin(plugin_path)?;
        }

        engine.set_signals(interrupt.clone());

        let exit_code = match engine.eval(&script, script_path.as_deref()) {
            Ok(value) => {
                match value {
                    // A void result (Nothing) stays silent rather than printing "null".
                    nu_protocol::Value::Nothing { .. } => {}
                    // A string result is emitted raw, not JSON-quoted, so fetching
                    // text/markdown (the /api docs, /pty/snap, ...) reads cleanly
                    // and a plain string still round-trips without `from json`.
                    nu_protocol::Value::String { val, .. } => println!("{val}"),
                    // Everything structured serializes as JSON so stdout pipes
                    // cleanly into `from json`.
                    other => {
                        let output =
                            serde_json::to_string(&value_to_json(&other)).unwrap_or_default();
                        println!("{output}");
                    }
                }
                0
            }
            Err(e) => {
                eprintln!("{e}");
                1
            }
        };
        shutdown();
        log_handle.join().ok();
        std::process::exit(exit_code);
    }

    // stacks2099 runs the workspace app -- nothing else. You choose where it
    // listens (ADDR) and where state lives (--store); both are required.
    let Some(addr) = args.addr.clone() else {
        eprintln!("Error: an ADDR ([HOST]:PORT) is required.");
        eprintln!("Usage: stacks2099 <ADDR> --store <DIR>");
        eprintln!("       stacks2099 --dev <ADDR> --store <DIR>   # run from source, hot-reload");
        std::process::exit(1);
    };
    #[cfg(feature = "cross-stream")]
    if args.store.is_none() {
        eprintln!("Error: --store <DIR> is required (where the event log lives).");
        eprintln!("Usage: stacks2099 <ADDR> --store <DIR>");
        eprintln!("       stacks2099 --dev <ADDR> --store <DIR>   # run from source, hot-reload");
        std::process::exit(1);
    }

    // Under --dev it runs from the source tree (hot-reload, relaxed cookie
    // security); otherwise it runs the copy baked into the binary, unpacked into
    // the store dir so the assets live with the workspace state they serve.
    let script_path: String = if args.dev {
        concat!(env!("CARGO_MANIFEST_DIR"), "/app/serve.nu").to_string()
    } else {
        let base = args.store.clone().unwrap_or_else(data_dir);
        let app = base.join("app");
        if let Err(e) = extract_app(&app) {
            eprintln!("Failed to unpack the bundled app to {}: {e}", app.display());
            std::process::exit(1);
        }
        app.join("serve.nu").display().to_string()
    };
    let watch = args.dev; // --dev implies hot-reload; production never watches
    let datastar = true; // the app always needs the Datastar bundle

    // Create channel for engines
    let (tx, rx) = mpsc::channel::<Engine>(1);

    // Create cross.stream store if --store is specified
    #[cfg(feature = "cross-stream")]
    let store = match args.store {
        Some(ref path) => {
            match Store::init(path.clone(), args.services, args.expose.clone()).await {
                Ok(store) => Some(store),
                Err(e) => {
                    eprintln!("Failed to open store at {}: {e}", path.display());
                    std::process::exit(1);
                }
            }
        }
        None => None,
    };
    #[cfg(not(feature = "cross-stream"))]
    let store: Option<Store> = None;

    // Build $HTTP_NU options
    let http_nu_options = HttpNuOptions {
        dev: args.dev,
        datastar,
        watch,
        tls: args.tls.as_ref().map(|p| p.display().to_string()),
        #[cfg(feature = "cross-stream")]
        store: args.store.as_ref().map(|p| p.display().to_string()),
        #[cfg(not(feature = "cross-stream"))]
        store: None,
        topic: None,
        #[cfg(feature = "cross-stream")]
        expose: args.expose.clone(),
        #[cfg(not(feature = "cross-stream"))]
        expose: None,
        #[cfg(feature = "cross-stream")]
        services: args.services,
        #[cfg(not(feature = "cross-stream"))]
        services: false,
    };

    // Create base engine with commands, signals, and plugins
    let base_engine = create_base_engine(
        interrupt.clone(),
        &args.plugins,
        &args.include_paths,
        store.as_ref(),
        &http_nu_options,
    )?;

    // Handler source: always the bundled app (file, watched under --dev).
    file_source(&script_path, watch, base_engine.clone(), tx).await;

    let startup_options = StartupOptions {
        watch,
        tls: args.tls.as_ref().map(|p| p.display().to_string()),
        #[cfg(feature = "cross-stream")]
        store: args.store.as_ref().map(|p| p.display().to_string()),
        #[cfg(not(feature = "cross-stream"))]
        store: None,
        topic: None,
        #[cfg(feature = "cross-stream")]
        expose: args.expose.clone(),
        #[cfg(not(feature = "cross-stream"))]
        expose: None,
        #[cfg(feature = "cross-stream")]
        services: args.services,
        #[cfg(not(feature = "cross-stream"))]
        services: false,
        datastar,
    };

    serve(
        addr,
        args.tls,
        rx,
        interrupt,
        AppConfig {
            trusted_proxies: args.trust_proxies,
            datastar,
            dev: args.dev,
        },
        std::time::Instant::now(),
        startup_options,
    )
    .await?;

    shutdown();
    log_handle.join().ok();
    Ok(())
}
