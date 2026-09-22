//! Airlift FFI — C-callable surface for the iOS on-device exploit.
//!
//! Exports:
//!   al_log_init            — install the tracing subscriber
//!   al_pairing_run_host    — RPPairing host (blocks until paired)
//!   al_pairing_result_free — free the ALPairResult heap strings
//!   al_exploit_run         — run the AirTraffic exploit over the loopback tunnel
//!   al_exploit_export_file — destructively export a device file to a local path
//!   al_string_free         — free any char* returned by this library

use std::ffi::{c_char, c_void};

pub mod exploit;
pub mod ffi_util;
pub mod grappa;
pub mod logging;
pub mod pairing;
pub mod readback;

// Re-export idevice-ffi's symbols into our staticlib (tunnel_create_rppairing,
// afc_*, rsd_*, adapter_*, etc.) so Swift can call them directly.
#[allow(unused_imports)]
extern crate idevice_ffi;

pub use pairing::{ALPairPinCb, ALPairReadyCb, ALPairResult};

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

/// Install the global tracing subscriber. Returns 0 on success, 1 if already
/// initialised. Call once at launch.
#[no_mangle]
pub extern "C" fn al_log_init(cb: logging::LogCallback, ctx: *mut c_void) -> i32 {
    logging::init(cb, ctx)
}

// ---------------------------------------------------------------------------
// Pairing
// ---------------------------------------------------------------------------

/// Run the RPPairing host. Blocks until a device pairs or an error occurs.
/// Returns 0 on success. `port` 0 lets the OS pick a free port.
///
/// # Safety
/// All `*const c_char` args must be null or valid C strings.
/// `out` must point to a writable `ALPairResult`.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn al_pairing_run_host(
    bind_addr: *const c_char,
    port: u16,
    name: *const c_char,
    model: *const c_char,
    out_path: *const c_char,
    host_alt_irk_hex: *const c_char,
    ready_cb: ALPairReadyCb,
    pin_cb: ALPairPinCb,
    ctx: *mut c_void,
    out: *mut ALPairResult,
) -> i32 {
    pairing::run_host(
        bind_addr, port, name, model, out_path, host_alt_irk_hex,
        ready_cb, pin_cb, ctx, out,
    )
}

/// Free the heap strings inside an `ALPairResult`.
///
/// # Safety
/// `r` must be null or a `ALPairResult` populated by `al_pairing_run_host`.
#[no_mangle]
pub unsafe extern "C" fn al_pairing_result_free(r: *mut ALPairResult) {
    pairing::result_free(r)
}

// ---------------------------------------------------------------------------
// Exploit
// ---------------------------------------------------------------------------

/// Run the AirTraffic sandbox escape.
///
/// `pairing_path` — path to the RPPairing file produced by `al_pairing_run_host`.
/// `target`       — absolute iOS directory to write the canary into
///                  (e.g. "/var/mobile/Library/SpringBoard").
/// `log_cb`       — receives log lines (called from arbitrary threads).
/// `ctx`          — passed back untouched to every log_cb invocation.
/// `out_json`     — set to a heap JSON result string (free with al_string_free).
/// `out_error`    — set to a heap error string on failure (free with al_string_free).
///
/// Returns 0 on success (exploit confirmed, bytes match), 1 on failure.
///
/// # Safety
/// All pointer arguments must be null or valid for their documented use.
#[no_mangle]
pub unsafe extern "C" fn al_exploit_run(
    pairing_path: *const c_char,
    target: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::run(pairing_path, target, log_cb, ctx, out_json, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_exploit_run: {e:?}"));
            }
            1
        }
    }
}

/// Write all files from `source_dir` into `target_dir` outside the sandbox via AirTraffic exploit.
///
/// # Safety
/// All pointer arguments must be null or valid for their documented use.
#[no_mangle]
pub unsafe extern "C" fn al_exploit_write_dir(
    pairing_path: *const c_char,
    source_dir: *const c_char,
    target_dir: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::write_dir(pairing_path, source_dir, target_dir, log_cb, ctx, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_exploit_write_dir: {e:?}"));
            }
            1
        }
    }
}

/// Inject an entire directory `folder_path` into `target_parent_dir/dest_name` outside the sandbox via AirTraffic exploit.
///
/// # Safety
/// All pointer arguments must be null or valid for their documented use.
#[no_mangle]
pub unsafe extern "C" fn al_exploit_inject_folder(
    pairing_path: *const c_char,
    folder_path: *const c_char,
    target_parent_dir: *const c_char,
    dest_name: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::inject_folder(pairing_path, folder_path, target_parent_dir, dest_name, log_cb, ctx, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_exploit_inject_folder: {e:?}"));
            }
            1
        }
    }
}

/// Destructively export one device file to a local app path using AirTraffic.
///
/// A successful call moves `device_path` out of its original location and
/// persists its exact bytes at `output_path`. The caller must replace or
/// restore the device file as part of the surrounding transaction.
///
/// # Safety
/// All pointer arguments must be null or valid for their documented use.
#[no_mangle]
pub unsafe extern "C" fn al_exploit_export_file(
    pairing_path: *const c_char,
    device_path: *const c_char,
    output_path: *const c_char,
    log_cb: readback::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        readback::export_file(
            pairing_path,
            device_path,
            output_path,
            log_cb,
            ctx,
            out_error,
        )
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_exploit_export_file: {e:?}"));
            }
            1
        }
    }
}

/// Free any `*mut c_char` returned by this library.
///
/// # Safety
/// `p` must be null or a pointer returned by one of this library's functions.
#[no_mangle]
pub unsafe extern "C" fn al_string_free(p: *mut c_char) {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        ffi_util::string_free(p);
    }));
}

// ---------------------------------------------------------------------------
// Live Card Scanner / Syslog Stream
// ---------------------------------------------------------------------------

/// Stream device syslog lines over the RSD tunnel.
/// Blocks until `al_syslog_stream_stop()` is called or an error occurs.
///
/// # Safety
/// All pointers must be valid or null as documented.
#[no_mangle]
pub unsafe extern "C" fn al_syslog_stream_start(
    pairing_path: *const c_char,
    line_cb: exploit::ALSyslogLineCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::run_syslog_stream(pairing_path, line_cb, ctx, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_syslog_stream_start: {e:?}"));
            }
            1
        }
    }
}

/// Request the running syslog stream to stop.
#[no_mangle]
pub extern "C" fn al_syslog_stream_stop() {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::stop_syslog_stream();
    }));
}

// ---------------------------------------------------------------------------
// Passthm Archive Extractor
// ---------------------------------------------------------------------------

/// Extract all image and asset files from a .passthm zip archive into `dest_dir`.
/// Returns 0 on success.
#[no_mangle]
pub unsafe extern "C" fn al_passthm_extract(
    archive_path: *const c_char,
    dest_dir: *const c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let archive_path = match ffi_util::opt_str(archive_path, "").as_str() {
            "" => return 1,
            s => s.to_string(),
        };
        let dest_dir = match ffi_util::opt_str(dest_dir, "").as_str() {
            "" => return 1,
            s => s.to_string(),
        };

        let file = match std::fs::File::open(&archive_path) {
            Ok(f) => f,
            Err(_) => return 2,
        };

        let mut archive = match zip::ZipArchive::new(file) {
            Ok(a) => a,
            Err(_) => return 3,
        };

        let dest = std::path::Path::new(&dest_dir);
        if std::fs::create_dir_all(dest).is_err() {
            return 4;
        }

        for i in 0..archive.len() {
            let mut file = match archive.by_index(i) {
                Ok(f) => f,
                Err(_) => continue,
            };
            let name = match file.enclosed_name() {
                Some(n) => n.to_owned(),
                None => continue,
            };
            if file.is_file() {
                let file_name = name.file_name().unwrap_or(name.as_os_str());
                let outpath = dest.join(file_name);
                if let Ok(mut outfile) = std::fs::File::create(&outpath) {
                    let _ = std::io::copy(&mut file, &mut outfile);
                }
            }
        }
        0
    }));
    res.unwrap_or(1)
}

/// Extract all files and directories from a zip archive into `dest_dir`.
/// Preserves directory hierarchies and skips unsafe path traversals.
/// Returns 0 on success.
#[no_mangle]
pub unsafe extern "C" fn al_zip_extract_all(
    archive_path: *const c_char,
    dest_dir: *const c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let archive_path = match ffi_util::opt_str(archive_path, "").as_str() {
            "" => return 1,
            s => s.to_string(),
        };
        let dest_dir = match ffi_util::opt_str(dest_dir, "").as_str() {
            "" => return 1,
            s => s.to_string(),
        };

        let file = match std::fs::File::open(&archive_path) {
            Ok(f) => f,
            Err(_) => return 2,
        };

        let mut archive = match zip::ZipArchive::new(file) {
            Ok(a) => a,
            Err(_) => return 3,
        };

        let dest = std::path::Path::new(&dest_dir);
        if std::fs::create_dir_all(dest).is_err() {
            return 4;
        }

        for i in 0..archive.len() {
            let mut file = match archive.by_index(i) {
                Ok(f) => f,
                Err(_) => continue,
            };
            let name = match file.enclosed_name() {
                Some(n) => n.to_owned(),
                None => continue,
            };
            let name_str = name.to_string_lossy();
            if name_str.contains("__MACOSX") || name_str.ends_with(".DS_Store") {
                continue;
            }
            let outpath = dest.join(&name);
            if file.is_dir() {
                let _ = std::fs::create_dir_all(&outpath);
            } else {
                if let Some(parent) = outpath.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                if let Ok(mut outfile) = std::fs::File::create(&outpath) {
                    let _ = std::io::copy(&mut file, &mut outfile);
                }
            }
        }
        0
    }));
    res.unwrap_or(1)
}

/// Query InstallationProxy over the pairing tunnel for an application's Container directory path.
/// Returns 0 on success (with out_container set), 1 on error (with out_error set).
#[no_mangle]
pub unsafe extern "C" fn al_find_app_container(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_container: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::find_container(pairing_path, bundle_id, log_cb, ctx, out_container, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_find_app_container: {e:?}"));
            }
            1
        }
    }
}

/// Trigger device restart / respring via Diagnostics Relay over the pairing tunnel.
/// Returns 0 on success, 1 on error.
#[no_mangle]
pub unsafe extern "C" fn al_device_respring(
    pairing_path: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::device_respring(pairing_path, log_cb, ctx, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_device_respring: {e:?}"));
            }
            1
        }
    }
}
