use tao::{
    event::{Event, StartCause, WindowEvent},
    event_loop::{ControlFlow, EventLoop, EventLoopWindowTarget},
    window::WindowBuilder,
};
use wry::{http, WebView, WebViewBuilder};

#[cfg(target_os = "android")]
fn init_logging() {
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Trace)
            .with_tag("android-app"),
    );
}

#[cfg(not(target_os = "android"))]
fn init_logging() {
    env_logger::init();
}

#[cfg(any(target_os = "android", target_os = "ios"))]
fn stop_unwind<F: FnOnce() -> T, T>(f: F) -> T {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(t) => t,
        Err(err) => {
            eprintln!("attempt to unwind out of `rust` with err: {:?}", err);
            std::process::abort()
        }
    }
}

#[cfg(any(target_os = "android", target_os = "ios"))]
fn _start_app() {
    stop_unwind(|| main());
}

#[no_mangle]
#[inline(never)]
#[cfg(any(target_os = "android", target_os = "ios"))]
pub extern "C" fn start_app() {
    #[cfg(target_os = "android")]
    {
        tao::android_binding!(
            com_example,
            androidapp,
            WryActivity,
            wry::android_setup, // pass the wry::android_setup function to tao which will invoke when the event loop is created
            _start_app
        );
        wry::android_binding!(com_example, android_app);
    }

    #[cfg(target_os = "ios")]
    _start_app()
}

pub fn main() {
    init_logging();
    let event_loop = EventLoop::new();

    let mut webview = None;
    event_loop.run(move |event, event_loop, control_flow| {
        *control_flow = ControlFlow::Wait;

        match event {
            Event::NewEvents(StartCause::Init) => {
                webview = Some(build_webview(event_loop).unwrap());
            }
            Event::WindowEvent {
                event: WindowEvent::CloseRequested { .. },
                ..
            } => {
                webview.take();
                *control_flow = ControlFlow::Exit;
            }
            _ => (),
        }
    });
}

fn build_webview(event_loop: &EventLoopWindowTarget<()>) -> anyhow::Result<WebView> {
    let window = WindowBuilder::new()
        .with_title("A fantastic window!")
        .build(&event_loop)?;

    #[cfg(any(
        target_os = "windows",
        target_os = "macos",
        target_os = "ios",
        target_os = "android"
    ))]
    let builder =  WebViewBuilder::new(&window);
    #[cfg(not(any(
        target_os = "windows",
        target_os = "macos",
        target_os = "ios",
        target_os = "android"
    )))]
    let builder = {
        use tao::platform::unix::WindowExtUnix;
        use wry::WebViewBuilderExtUnix;
        let vbox = window.default_vbox().unwrap();
        WebViewBuilder::new_gtk(vbox)
    };
    let webview = builder
        .with_url("https://tauri.app")
        // If you want to use custom protocol, set url like this and add files like index.html to assets directory.
        // .with_url("wry://assets/index.html")?
        .with_devtools(true)
        .with_initialization_script("console.log('hello world from init script');")
        .with_ipc_handler(|s| {
            dbg!(s);
        })
        .with_custom_protocol("wry".into(), move |request| {
            match process_custom_protcol(request) {
                Ok(r) => r.map(Into::into),
                Err(e) => http::Response::builder()
                    .header(http::header::CONTENT_TYPE, "text/plain")
                    .status(500)
                    .body(e.to_string().as_bytes().to_vec())
                    .unwrap()
                    .map(Into::into),
            }
        })
        .build()?;

    Ok(webview)
}

fn process_custom_protcol(
    _request: http::Request<Vec<u8>>,
) -> anyhow::Result<http::Response<Vec<u8>>> {
    #[cfg(not(target_os = "android"))]
    {
        use std::fs::{canonicalize, read};
        use wry::http::header::CONTENT_TYPE;

        // Remove url scheme
        let path = _request.uri().path();

        #[cfg(not(target_os = "ios"))]
        let content = read(canonicalize(&path[1..])?)?;

        #[cfg(target_os = "ios")]
        let content = {
            let path = core_foundation::bundle::CFBundle::main_bundle()
                .resources_path()
                .unwrap()
                .join(&path);
            read(canonicalize(&path)?)?
        };

        // Return asset contents and mime types based on file extentions
        // If you don't want to do this manually, there are some crates for you.
        // Such as `infer` and `mime_guess`.
        let (data, meta) = if path.ends_with(".html") {
            (content, "text/html")
        } else if path.ends_with(".js") {
            (content, "text/javascript")
        } else if path.ends_with(".png") {
            (content, "image/png")
        } else {
            unimplemented!();
        };

        Ok(http::Response::builder()
            .header(CONTENT_TYPE, meta)
            .body(data.into())?)
    }

    #[cfg(target_os = "android")]
    {
        Ok(http::Response::builder().body(Vec::new().into())?)
    }
}
