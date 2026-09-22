//! Generic AirTraffic file export primitive.
//!
//! IMPORTANT: ATAirlock's FileComplete operation is move-based. A successful
//! export moves the requested device file into the Media/AFC recovery area,
//! copies its bytes to `output_path`, and then removes the recovery artifact.
//! The caller is responsible for replacing/restoring the device file after a
//! successful export. This behavior is intentional for transactional backup
//! flows such as Wallet artwork preservation immediately before replacement.

use std::ffi::{c_char, c_void, CString};
use std::time::{SystemTime, UNIX_EPOCH};

use idevice::afc::opcode::AfcFopenMode;
use idevice::afc::AfcClient;
use idevice::pairing_file::PairingFile;
use idevice::provider::{IdeviceProvider, TcpProvider};
use idevice::remote_pairing::RpPairingFile;
use idevice::services::lockdown::LockdownClient;
use idevice::{Idevice, IdeviceService, ReadWrite};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::ffi_util::{cstr, opt_str};

const AIRLOCK_ROOT: &str = "/var/mobile/Media/Airlock/Book";
const RECOVERED_PREFIX: &str = "airlift-recovered-";
const RSD_PORT: u16 = 49152;

#[allow(non_camel_case_types)]
pub type ALLogCallback = Option<extern "C" fn(ctx: *mut c_void, msg: *const c_char)>;

struct Logger {
    cb: ALLogCallback,
    ctx: *mut c_void,
}
unsafe impl Send for Logger {}
unsafe impl Sync for Logger {}

impl Logger {
    fn log(&self, msg: impl AsRef<str>) {
        let s = msg.as_ref();
        tracing::info!("{s}");
        if let Some(cb) = self.cb {
            if let Ok(c) = CString::new(s) {
                cb(self.ctx, c.as_ptr());
            }
        }
    }
}

enum DeviceTunnel {
    Rsd {
        adapter: idevice::tcp::handle::AdapterHandle,
        handshake: idevice::services::rsd::RsdHandshake,
    },
    Lockdown {
        provider: TcpProvider,
        pairing_file: PairingFile,
        legacy: bool,
    },
}

impl DeviceTunnel {
    async fn connect_afc(&mut self, logger: &Logger) -> Result<AfcClient, String> {
        match self {
            DeviceTunnel::Rsd { adapter, handshake } => handshake
                .connect::<AfcClient>(adapter)
                .await
                .map_err(|e| format!("AFC connect over RSD failed: {e:?}")),
            DeviceTunnel::Lockdown {
                provider,
                pairing_file,
                legacy,
            } => {
                let stream = connect_service_lockdown(
                    provider,
                    pairing_file,
                    *legacy,
                    "com.apple.afc",
                    logger,
                )
                .await?;
                let idevice = Idevice::new(stream, "Airlift");
                Ok(AfcClient::new(idevice))
            }
        }
    }

    async fn connect_service(
        &mut self,
        service_base: &str,
        logger: &Logger,
    ) -> Result<Box<dyn ReadWrite>, String> {
        match self {
            DeviceTunnel::Rsd { adapter, handshake } => {
                connect_service_rsd(adapter, handshake, service_base, logger).await
            }
            DeviceTunnel::Lockdown {
                provider,
                pairing_file,
                legacy,
            } => {
                connect_service_lockdown(provider, pairing_file, *legacy, service_base, logger).await
            }
        }
    }
}

async fn connect_service_lockdown(
    provider: &TcpProvider,
    pairing_file: &PairingFile,
    legacy: bool,
    service_name: &str,
    logger: &Logger,
) -> Result<Box<dyn ReadWrite>, String> {
    logger.log(format!("airlift-export: starting '{service_name}' via Lockdown..."));
    let mut lockdown = LockdownClient::connect(provider)
        .await
        .map_err(|e| format!("Lockdown connect failed: {e:?}"))?;

    let _ = lockdown
        .start_session(pairing_file)
        .await
        .map_err(|e| format!("Lockdown start_session failed: {e:?}"))?;

    let (port, ssl) = lockdown
        .start_service(service_name)
        .await
        .map_err(|e| format!("Lockdown start_service('{service_name}') failed: {e:?}"))?;

    let mut idevice = provider
        .connect(port)
        .await
        .map_err(|e| format!("Connect to service port {port} failed: {e:?}"))?;

    if ssl {
        idevice
            .start_session(pairing_file, legacy)
            .await
            .map_err(|e| format!("Service TLS session failed: {e:?}"))?;
    }

    idevice
        .get_socket()
        .ok_or_else(|| "Failed to get socket from idevice".to_string())
}

async fn connect_service_rsd(
    adapter: &mut idevice::tcp::handle::AdapterHandle,
    handshake: &mut idevice::services::rsd::RsdHandshake,
    service_base: &str,
    logger: &Logger,
) -> Result<Box<dyn ReadWrite>, String> {
    let shim_name = format!("{service_base}.shim.remote");
    if let Some(s) = handshake.services.get(&shim_name) {
        let port = s.port;
        let stream = adapter
            .connect(port)
            .await
            .map_err(|e| format!("Connect to '{shim_name}' on port {port} failed: {e:?}"))?;
        let mut dev = Idevice::new(Box::new(stream), "Airlift");
        dev.rsd_checkin()
            .await
            .map_err(|e| format!("RSD checkin for '{shim_name}' failed: {e:?}"))?;
        return dev
            .get_socket()
            .ok_or_else(|| "Failed to get socket from Idevice".to_string());
    }

    if let Some(s) = handshake.services.get(service_base) {
        let port = s.port;
        let stream = adapter
            .connect(port)
            .await
            .map_err(|e| format!("Connect to '{service_base}' on port {port} failed: {e:?}"))?;
        let mut dev = Idevice::new(Box::new(stream), "Airlift");
        dev.rsd_checkin()
            .await
            .map_err(|e| format!("RSD checkin for '{service_base}' failed: {e:?}"))?;
        return dev
            .get_socket()
            .ok_or_else(|| "Failed to get socket from Idevice".to_string());
    }

    logger.log(format!(
        "airlift-export: '{service_base}' not directly in RSD, starting via Lockdown..."
    ));
    let mut lockdown = handshake
        .connect::<LockdownClient>(adapter)
        .await
        .map_err(|e| format!("Lockdown connect for '{service_base}' failed: {e:?}"))?;
    let (port, _ssl) = lockdown
        .start_service(service_base)
        .await
        .map_err(|e| format!("Lockdown start_service('{service_base}') failed: {e:?}"))?;
    let stream = adapter
        .connect(port)
        .await
        .map_err(|e| format!("Connect to service port {port} failed: {e:?}"))?;
    Ok(Box::new(stream))
}

async fn connect_tunnel(pairing_bytes: &[u8], logger: &Logger) -> Result<DeviceTunnel, String> {
    let mut last_error = String::new();

    if let Ok(mut rpf) = RpPairingFile::from_bytes(pairing_bytes) {
        let extra_hosts = vec![
            std::net::IpAddr::V4(std::net::Ipv4Addr::new(127, 0, 0, 1)),
            std::net::IpAddr::V4(std::net::Ipv4Addr::new(10, 7, 0, 1)),
            std::net::IpAddr::V4(std::net::Ipv4Addr::new(10, 7, 0, 2)),
            std::net::IpAddr::V4(std::net::Ipv4Addr::new(10, 7, 0, 3)),
            std::net::IpAddr::V6(std::net::Ipv6Addr::LOCALHOST),
        ];
        let targets = ["127.0.0.1", "10.7.0.1", "10.7.0.2", "10.7.0.3"];

        for ip_str in targets {
            let Ok(ip) = ip_str.parse::<std::net::Ipv4Addr>() else {
                continue;
            };
            let socket_addr = std::net::SocketAddr::new(std::net::IpAddr::V4(ip), RSD_PORT);

            match tokio::time::timeout(
                std::time::Duration::from_millis(6000),
                idevice_ffi::tunnel_provider::tunnel_create_remotexpc_multihost_async(
                    socket_addr,
                    "Airlift",
                    &mut rpf,
                    &extra_hosts,
                ),
            )
            .await
            {
                Ok(Ok((adapter, handshake))) => {
                    return Ok(DeviceTunnel::Rsd { adapter, handshake });
                }
                Ok(Err(failure)) => {
                    last_error = format!("{ip_str}:{RSD_PORT}: {:?}", failure.kind);
                }
                Err(_) => {
                    last_error = format!("{ip_str}:{RSD_PORT}: RemoteXPC timed out");
                }
            }

            match tokio::time::timeout(
                std::time::Duration::from_millis(6000),
                idevice_ffi::tunnel_provider::tunnel_create_rppairing_multihost_async(
                    socket_addr,
                    "Airlift",
                    &mut rpf,
                    &extra_hosts,
                ),
            )
            .await
            {
                Ok(Ok((adapter, handshake))) => {
                    return Ok(DeviceTunnel::Rsd { adapter, handshake });
                }
                Ok(Err(failure)) => {
                    last_error = format!("{ip_str}:{RSD_PORT}: {:?}", failure.kind);
                }
                Err(_) => {
                    last_error = format!("{ip_str}:{RSD_PORT}: raw RPPairing timed out");
                }
            }
        }
    }

    match PairingFile::from_bytes(pairing_bytes) {
        Ok(pf) => {
            for ip_str in ["127.0.0.1", "10.7.0.1", "10.7.0.2", "10.7.0.3"] {
                let Ok(ip) = ip_str.parse::<std::net::Ipv4Addr>() else {
                    continue;
                };
                let provider = TcpProvider {
                    addr: std::net::IpAddr::V4(ip),
                    scope_id: None,
                    pairing_file: pf.clone(),
                    label: "Airlift".to_string(),
                };

                match tokio::time::timeout(
                    std::time::Duration::from_millis(2000),
                    LockdownClient::connect(&provider),
                )
                .await
                {
                    Ok(Ok(mut lockdown)) => match lockdown.start_session(&pf).await {
                        Ok(legacy) => {
                            return Ok(DeviceTunnel::Lockdown {
                                provider,
                                pairing_file: pf,
                                legacy,
                            });
                        }
                        Err(e) => {
                            last_error = format!("lockdownd start_session failed: {e:?}");
                        }
                    },
                    Ok(Err(e)) => {
                        last_error = format!("connect to lockdownd failed: {e:?}");
                    }
                    Err(_) => {
                        last_error = format!("connect to lockdownd on {ip_str}:62078 timed out");
                    }
                }
            }
        }
        Err(e) if last_error.is_empty() => {
            last_error = format!("Failed to parse pairing file: {e}");
        }
        Err(_) => {}
    }

    Err(format!(
        "Device connection failed: {last_error}. Ensure the loopback VPN/tunnel is active."
    ))
}

fn random_hex(bytes: usize) -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let mut h = Sha256::new();
    h.update(now.to_le_bytes());
    h.update(std::process::id().to_le_bytes());
    h.update(std::thread::current().name().unwrap_or("airlift-export").as_bytes());
    let digest = h.finalize();
    hex::encode(&digest[..bytes.min(digest.len())])
}

fn posix_rel(path: &str, base: &str) -> String {
    let path_parts: Vec<&str> = path
        .trim_start_matches('/')
        .split('/')
        .filter(|p| !p.is_empty())
        .collect();
    let base_parts: Vec<&str> = base
        .trim_start_matches('/')
        .split('/')
        .filter(|p| !p.is_empty())
        .collect();

    let mut common = 0usize;
    while common < path_parts.len()
        && common < base_parts.len()
        && path_parts[common] == base_parts[common]
    {
        common += 1;
    }

    let mut parts: Vec<String> = Vec::new();
    for _ in common..base_parts.len() {
        parts.push("..".to_string());
    }
    parts.extend(path_parts[common..].iter().map(|p| (*p).to_string()));
    if parts.is_empty() {
        ".".to_string()
    } else {
        parts.join("/")
    }
}

fn build_books_plist(identifiers: &[String]) -> Result<Vec<u8>, String> {
    let rows: Vec<plist::Value> = identifiers
        .iter()
        .enumerate()
        .map(|(index, identifier)| {
            let mut row = plist::Dictionary::new();
            row.insert(
                "Persistent ID".into(),
                plist::Value::String(identifier.clone()),
            );
            row.insert(
                "Item ID".into(),
                plist::Value::String((index + 1).to_string()),
            );
            row.insert("DSID".into(), plist::Value::String("1".into()));
            plist::Value::Dictionary(row)
        })
        .collect();

    let mut root = plist::Dictionary::new();
    root.insert("Books".into(), plist::Value::Array(rows));
    let mut buf = Vec::new();
    plist::to_writer_binary(&mut buf, &plist::Value::Dictionary(root))
        .map_err(|e| format!("encode Books.plist: {e}"))?;
    Ok(buf)
}

fn atc_message_name(dict: &plist::Dictionary) -> Option<String> {
    dict.get("Command")
        .and_then(|v| v.as_string())
        .or_else(|| dict.get("MessageName").and_then(|v| v.as_string()))
        .map(ToOwned::to_owned)
}

fn atc_session_number(dict: &plist::Dictionary) -> Option<i64> {
    dict.get("Session")
        .and_then(|v| v.as_signed_integer())
        .or_else(|| dict.get("SessionNumber").and_then(|v| v.as_signed_integer()))
}

fn make_atc_msg(
    command: &str,
    session: i64,
    params: Option<plist::Dictionary>,
) -> plist::Dictionary {
    let mut msg = plist::Dictionary::new();
    msg.insert("Command".into(), plist::Value::String(command.into()));
    msg.insert("Session".into(), plist::Value::Integer(session.into()));
    if let Some(params) = params {
        msg.insert("Params".into(), plist::Value::Dictionary(params));
    }
    msg
}

async fn read_atc_dict<S: AsyncReadExt + Unpin>(stream: &mut S) -> Result<plist::Dictionary, String> {
    let mut len_buf = [0u8; 4];
    stream
        .read_exact(&mut len_buf)
        .await
        .map_err(|e| format!("read ATC length: {e}"))?;
    let len_le = u32::from_le_bytes(len_buf) as usize;
    let len_be = u32::from_be_bytes(len_buf) as usize;
    let len = if len_le > 0 && len_le <= 10 * 1024 * 1024 {
        len_le
    } else if len_be > 0 && len_be <= 10 * 1024 * 1024 {
        len_be
    } else {
        return Err(format!("ATC message length invalid: le={len_le}, be={len_be}"));
    };
    let mut body = vec![0u8; len];
    stream
        .read_exact(&mut body)
        .await
        .map_err(|e| format!("read ATC body: {e}"))?;
    let value: plist::Value = plist::from_bytes(&body).map_err(|e| format!("decode ATC plist: {e}"))?;
    value
        .into_dictionary()
        .ok_or_else(|| "expected ATC plist dictionary".to_string())
}

async fn send_atc_dict<S: AsyncWriteExt + Unpin>(
    stream: &mut S,
    dict: &plist::Dictionary,
) -> Result<(), String> {
    let mut buf = Vec::new();
    plist::to_writer_binary(&mut buf, &plist::Value::Dictionary(dict.clone()))
        .map_err(|e| format!("encode ATC plist: {e}"))?;
    stream
        .write_all(&(buf.len() as u32).to_le_bytes())
        .await
        .map_err(|e| format!("write ATC length: {e}"))?;
    stream
        .write_all(&buf)
        .await
        .map_err(|e| format!("write ATC body: {e}"))?;
    stream.flush().await.map_err(|e| format!("flush ATC: {e}"))?;
    Ok(())
}

async fn run_airtraffic_move(
    tunnel: &mut DeviceTunnel,
    identifier: &str,
    destination: &str,
    logger: &Logger,
) -> Result<(), String> {
    let mut atc_stream = tunnel.connect_service("com.apple.atc", logger).await?;
    let mut grappa_info: Option<(u32, u32, u32)> = None;
    let mut session_number = 0i64;

    for _ in 0..12 {
        match tokio::time::timeout(
            std::time::Duration::from_millis(1500),
            read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(sn) = atc_session_number(&dict) {
                    session_number = sn;
                }
                if let Some(name) = atc_message_name(&dict) {
                    if name == "Capabilities" {
                        if let Some(params) = dict.get("Params").and_then(|p| p.as_dictionary()) {
                            if let Some(gi) = params
                                .get("GrappaSupportInfo")
                                .and_then(|g| g.as_dictionary())
                            {
                                let ver = gi
                                    .get("version")
                                    .and_then(|v| v.as_unsigned_integer())
                                    .unwrap_or(1) as u32;
                                let dt = gi
                                    .get("deviceType")
                                    .and_then(|v| v.as_unsigned_integer())
                                    .unwrap_or(0) as u32;
                                let pv = gi
                                    .get("protocolVersion")
                                    .and_then(|v| v.as_unsigned_integer())
                                    .unwrap_or(1) as u32;
                                grappa_info = Some((ver, dt, pv));
                            }
                        }
                    }
                    if name == "SyncAllowed" {
                        break;
                    }
                }
            }
            Ok(Err(_)) => break,
            Err(_) => {}
        }
    }

    let mut host_info = plist::Dictionary::new();
    host_info.insert("Type".into(), plist::Value::String("iTunes".into()));
    host_info.insert("Version".into(), plist::Value::String("13.7.0.161".into()));
    host_info.insert("MacOSVersion".into(), plist::Value::String("15.0".into()));
    host_info.insert("SyncHostName".into(), plist::Value::String("airlift".into()));
    host_info.insert(
        "LibraryID".into(),
        plist::Value::String(format!("{}-{}", random_hex(8), random_hex(8))),
    );
    host_info.insert(
        "SyncedDataclasses".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host_info.insert(
        "SyncedAssetTypes".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host_info.insert("Wakeable".into(), plist::Value::Boolean(false));

    let grappa_token = crate::grappa::generate_grappa_token(grappa_info, |s| logger.log(s));
    if let Some(ref token) = grappa_token {
        host_info.insert("Grappa".into(), plist::Value::Data(token.clone()));
    }

    let mut host_params = plist::Dictionary::new();
    host_params.insert("HostInfo".into(), plist::Value::Dictionary(host_info.clone()));
    host_params.insert("LocalCloudSupport".into(), plist::Value::Boolean(false));
    send_atc_dict(&mut atc_stream, &make_atc_msg("HostInfo", 0, Some(host_params))).await?;

    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    let mut request_params = plist::Dictionary::new();
    request_params.insert(
        "Dataclasses".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    request_params.insert(
        "DataclassAnchors".into(),
        plist::Value::Dictionary(plist::Dictionary::new()),
    );
    request_params.insert("HostInfo".into(), plist::Value::Dictionary(host_info));
    if let Some(token) = grappa_token {
        request_params.insert("Grappa".into(), plist::Value::Data(token));
    }
    send_atc_dict(
        &mut atc_stream,
        &make_atc_msg("RequestingSync", 1, Some(request_params)),
    )
    .await?;

    let mut ready = false;
    for _ in 0..24 {
        match tokio::time::timeout(
            std::time::Duration::from_secs(5),
            read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(name) = atc_message_name(&dict) {
                    if name == "Ping" {
                        let _ = send_atc_dict(&mut atc_stream, &make_atc_msg("Pong", 1, None)).await;
                        continue;
                    }
                    if name == "ReadyForSync" || name == "AssetManifest" {
                        ready = true;
                        break;
                    }
                    if name == "SyncFailed" {
                        continue;
                    }
                }
            }
            Ok(Err(_)) => break,
            Err(_) => {}
        }
    }
    if !ready {
        return Err(format!(
            "AirTraffic ReadyForSync not observed (session={session_number})"
        ));
    }

    let mut sync_types = plist::Dictionary::new();
    sync_types.insert("Book".into(), plist::Value::Integer(1.into()));
    let mut meta_params = plist::Dictionary::new();
    meta_params.insert("SyncTypes".into(), plist::Value::Dictionary(sync_types));
    meta_params.insert(
        "DataclassAnchors".into(),
        plist::Value::Dictionary(plist::Dictionary::new()),
    );
    send_atc_dict(
        &mut atc_stream,
        &make_atc_msg("FinishedSyncingMetadata", 1, Some(meta_params)),
    )
    .await?;

    let mut manifest = false;
    for _ in 0..20 {
        match tokio::time::timeout(
            std::time::Duration::from_secs(5),
            read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(name) = atc_message_name(&dict) {
                    if name == "Ping" {
                        let _ = send_atc_dict(&mut atc_stream, &make_atc_msg("Pong", 1, None)).await;
                        continue;
                    }
                    if name == "AssetManifest" {
                        manifest = true;
                        break;
                    }
                    if name == "SyncFinished" {
                        break;
                    }
                    if name == "SyncFailed" {
                        continue;
                    }
                }
            }
            Ok(Err(_)) => break,
            Err(_) => {}
        }
    }
    if !manifest {
        return Err("AirTraffic AssetManifest not observed".into());
    }

    let mut file_params = plist::Dictionary::new();
    file_params.insert("AssetID".into(), plist::Value::String(identifier.to_string()));
    file_params.insert("Dataclass".into(), plist::Value::String("Book".into()));
    file_params.insert("AssetPath".into(), plist::Value::String(destination.to_string()));
    send_atc_dict(
        &mut atc_stream,
        &make_atc_msg("FileComplete", 1, Some(file_params)),
    )
    .await?;

    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    Ok(())
}

async fn restore_books(afc: &mut AfcClient, original: Option<&[u8]>) {
    if let Some(data) = original {
        if let Ok(mut fd) = afc.open("Books/Sync/Books.plist", AfcFopenMode::WrOnly).await {
            let _ = fd.write_entire(data).await;
            let _ = fd.close().await;
        }
    } else {
        let _ = afc.remove("Books/Sync/Books.plist").await;
    }
}

async fn export_file_impl(
    pairing_path: String,
    device_path: String,
    output_path: String,
    logger: &Logger,
) -> Result<usize, String> {
    if !device_path.starts_with('/') {
        return Err("device_path must be an absolute iOS path".into());
    }
    if output_path.is_empty() {
        return Err("output_path must not be empty".into());
    }

    let pairing_bytes = std::fs::read(&pairing_path)
        .map_err(|e| format!("Failed to read pairing file at {pairing_path}: {e}"))?;
    let mut tunnel = connect_tunnel(&pairing_bytes, logger).await?;
    let mut afc = tunnel.connect_afc(logger).await?;

    let original_books = match afc.open("Books/Sync/Books.plist", AfcFopenMode::RdOnly).await {
        Ok(mut fd) => {
            let data = fd.read_entire().await.ok();
            let _ = fd.close().await;
            data
        }
        Err(_) => None,
    };

    // Use a deterministic AFC recovery object for this device path. If the app
    // is killed after ATAirlock moves the source but before Swift can write it
    // back, the next export attempt can discover and resume this exact object.
    let recovered = {
        let mut h = Sha256::new();
        h.update(device_path.as_bytes());
        let digest = h.finalize();
        format!("{}{}", RECOVERED_PREFIX, hex::encode(&digest[..10]))
    };

    // Read a retained recovery object in its own borrow scope. Once the file
    // descriptor is dropped we can safely mutate AFC again to remove it.
    let retained_bytes = match afc.open(&recovered, AfcFopenMode::RdOnly).await {
        Ok(mut recovered_fd) => {
            logger.log(format!(
                "airlift-export: resuming retained AFC recovery object '{recovered}' for '{device_path}'"
            ));
            let bytes = recovered_fd
                .read_entire()
                .await
                .map_err(|e| format!("Failed to read retained recovery bytes: {e:?}"))?;
            let _ = recovered_fd.close().await;
            Some(bytes)
        }
        Err(_) => None,
    };

    if let Some(bytes) = retained_bytes {
        let output = std::path::Path::new(&output_path);
        if let Some(parent) = output.parent() {
            std::fs::create_dir_all(parent).map_err(|e| {
                format!("Failed to create backup directory {}: {e}", parent.display())
            })?;
        }
        let tmp = output.with_extension(format!("airlift-tmp-{}", random_hex(4)));
        std::fs::write(&tmp, &bytes).map_err(|e| {
            format!("Failed to write resumed backup {}: {e}", tmp.display())
        })?;
        std::fs::rename(&tmp, output).map_err(|e| {
            format!("Failed to finalize resumed backup {}: {e}", output.display())
        })?;

        logger.log(format!(
            "airlift-export: recovered {} bytes for '{device_path}' from interrupted transaction",
            bytes.len()
        ));
        let _ = afc.remove(&recovered).await;
        return Ok(bytes.len());
    }

    let identifier = posix_rel(&device_path, AIRLOCK_ROOT);
    let books_plist = build_books_plist(&[identifier.clone()])?;

    let result: Result<usize, String> = async {
        let _ = afc.mk_dir("Airlock").await;
        let _ = afc.mk_dir("Airlock/Book").await;
        let _ = afc.mk_dir("Books").await;
        let _ = afc.mk_dir("Books/Sync").await;

        let mut books_fd = afc
            .open("Books/Sync/Books.plist", AfcFopenMode::WrOnly)
            .await
            .map_err(|e| format!("AFC open Books.plist: {e:?}"))?;
        books_fd
            .write_entire(&books_plist)
            .await
            .map_err(|e| format!("AFC write Books.plist: {e:?}"))?;
        let _ = books_fd.close().await;

        logger.log(format!(
            "airlift-export: moving '{device_path}' to AFC recovery object '{recovered}'"
        ));
        run_airtraffic_move(&mut tunnel, &identifier, &recovered, logger).await?;

        let mut recovered_fd = afc
            .open(&recovered, AfcFopenMode::RdOnly)
            .await
            .map_err(|e| format!("Exported file not found in AFC recovery area: {e:?}"))?;
        let bytes = recovered_fd
            .read_entire()
            .await
            .map_err(|e| format!("Failed to read exported bytes: {e:?}"))?;
        let _ = recovered_fd.close().await;

        let output = std::path::Path::new(&output_path);
        if let Some(parent) = output.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("Failed to create backup directory {}: {e}", parent.display()))?;
        }
        let tmp = output.with_extension(format!("airlift-tmp-{}", random_hex(4)));
        std::fs::write(&tmp, &bytes)
            .map_err(|e| format!("Failed to write temporary backup {}: {e}", tmp.display()))?;
        std::fs::rename(&tmp, output)
            .map_err(|e| format!("Failed to finalize backup {}: {e}", output.display()))?;

        logger.log(format!(
            "airlift-export: exported {} bytes from '{device_path}'",
            bytes.len()
        ));
        Ok(bytes.len())
    }
    .await;

    if result.is_ok() {
        let _ = afc.remove(&recovered).await;
    } else {
        // Never discard the only remaining copy after a failed move/read/write.
        // The deterministic name lets a later invocation resume it safely.
        logger.log(format!(
            "airlift-export: export failed; retaining AFC recovery object '{recovered}' for retry"
        ));
    }
    restore_books(&mut afc, original_books.as_deref()).await;
    result
}

/// Destructively export a device file to a local app path.
///
/// On success, the requested device file has been moved out of its original
/// location by ATAirlock and its exact bytes have been persisted at
/// `output_path`. The caller must replace/restore the device file as part of
/// the surrounding transaction.
///
/// # Safety
/// Pointer arguments must be null or valid C strings as documented.
pub unsafe fn export_file(
    pairing_path: *const c_char,
    device_path: *const c_char,
    output_path: *const c_char,
    log_cb: ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let device_path = opt_str(device_path, "");
    let output_path = opt_str(output_path, "");
    let ctx_usize = ctx as usize;

    let res = crate::ffi_util::run_with_large_stack("al_exploit_export_file", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(export_file_impl(
            pairing_path,
            device_path,
            output_path,
            &logger,
        ))
    });

    match res {
        Ok(Ok(_size)) => 0,
        Ok(Err(e)) | Err(e) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::posix_rel;

    #[test]
    fn wallet_artwork_path_is_relative_to_airlock_root() {
        let rel = posix_rel(
            "/var/mobile/Library/Passes/Cards/example.pkpass/cardBackgroundCombined@3x.png",
            "/var/mobile/Media/Airlock/Book",
        );
        assert_eq!(
            rel,
            "../../../Library/Passes/Cards/example.pkpass/cardBackgroundCombined@3x.png"
        );
    }
}
