// Fixed copy of omnisette's RemoteAnisetteProviderV3 (rustpush/apple-private-apis/omnisette/src/remote_anisette_v3.rs).
// Same on-disk state (<configuration_path>/state.plist), but falls back across several servers,
// reports server errors readably and is bounded by timeouts so sign-in can never hang.

use std::{collections::HashMap, fs, io::Cursor, path::PathBuf, sync::Arc, time::Duration};

use anyhow::anyhow;
use base64::prelude::*;
use chrono::{DateTime, SubsecRound, Utc};
use futures::{SinkExt, Stream, StreamExt};
use log::{info, warn};
use omnisette::{AnisetteClient, AnisetteError, AnisetteProvider, ArcAnisetteClient, LoginClientInfo};
use plist::{Data, Dictionary};
use rand::Rng;
use reqwest::{Certificate, Client, ClientBuilder, RequestBuilder};
use serde::{de::Error as _, Deserialize, Deserializer, Serialize, Serializer};
use sha2::{Digest, Sha256};
use tokio::{sync::Mutex, time::{timeout, timeout_at, Instant}};
use tokio_tungstenite::{connect_async, tungstenite::{self, Message}};
use uuid::Uuid;

const APPLE_ROOT: &[u8] = include_bytes!("../../rustpush/apple-private-apis/icloud-auth/src/apple_root.der");

const SERVERS: &[&str] = &[
    "https://ani.sidestore.zip",
    "https://ani.sidestore.app",
    "https://ani.sidestore.io",
];
const PROVISION_PASSES: usize = 2;
const MSG_TIMEOUT: Duration = Duration::from_secs(15);
const HTTP_TIMEOUT: Duration = Duration::from_secs(15);
const ATTEMPT_TIMEOUT: Duration = Duration::from_secs(30);
const OVERALL_TIMEOUT: Duration = Duration::from_secs(90);

fn err(msg: String) -> AnisetteError {
    AnisetteError::Anyhow(anyhow!(msg))
}

fn bin_serialize<S: Serializer>(x: &[u8], s: S) -> Result<S::Ok, S::Error> {
    s.serialize_bytes(x)
}

fn bin_serialize_opt<S: Serializer>(x: &Option<Vec<u8>>, s: S) -> Result<S::Ok, S::Error> {
    x.clone().map(Data::new).serialize(s)
}

fn bin_deserialize_opt<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Vec<u8>>, D::Error> {
    let s: Option<Data> = Deserialize::deserialize(d)?;
    Ok(s.map(|i| i.into()))
}

fn bin_deserialize_16<'de, D: Deserializer<'de>>(d: D) -> Result<[u8; 16], D::Error> {
    let s: Data = Deserialize::deserialize(d)?;
    let s: Vec<u8> = s.into();
    s.try_into().map_err(|_| D::Error::custom("keychain_identifier must be 16 bytes"))
}

fn encode_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

fn plist_to_string<T: Serialize>(value: &T) -> Result<String, AnisetteError> {
    let mut buf: Vec<u8> = Vec::new();
    plist::to_writer_xml(Cursor::new(&mut buf), value)?;
    String::from_utf8(buf).map_err(|e| err(e.to_string()))
}

#[derive(Serialize, Deserialize)]
struct AnisetteState {
    #[serde(serialize_with = "bin_serialize", deserialize_with = "bin_deserialize_16")]
    keychain_identifier: [u8; 16],
    #[serde(default, serialize_with = "bin_serialize_opt", deserialize_with = "bin_deserialize_opt")]
    adi_pb: Option<Vec<u8>>,
}

impl AnisetteState {
    fn new() -> AnisetteState {
        AnisetteState { keychain_identifier: rand::thread_rng().gen::<[u8; 16]>(), adi_pb: None }
    }

    fn md_lu(&self) -> [u8; 32] {
        let mut hasher = Sha256::new();
        hasher.update(&self.keychain_identifier);
        hasher.finalize().into()
    }

    fn device_id(&self) -> String {
        Uuid::from_bytes(self.keychain_identifier).to_string()
    }
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
struct ProvisionBodyData {
    header: Dictionary,
    request: Dictionary,
}

fn make_reqwest() -> Result<Client, AnisetteError> {
    Ok(ClientBuilder::new()
        .http1_title_case_headers()
        .add_root_certificate(Certificate::from_der(APPLE_ROOT)?)
        .timeout(HTTP_TIMEOUT)
        .build()?)
}

fn build_apple_request(info: &LoginClientInfo, state: &AnisetteState, mut builder: RequestBuilder) -> RequestBuilder {
    let dt: DateTime<Utc> = Utc::now().round_subsecs(0);

    builder = builder.header("User-Agent", &info.akd_user_agent)
        .header("X-Apple-Baa-E", "-10000")
        .header("X-Apple-I-MD-LU", encode_hex(&state.md_lu()))
        .header("X-Mme-Device-Id", state.device_id())
        .header("X-Apple-Baa-Avail", "2")
        .header("X-Mme-Client-Info", &info.mme_client_info)
        .header("X-Apple-I-Client-Time", dt.format("%+").to_string())
        .header("Accept-Language", "en-US,en;q=0.9")
        .header("X-Apple-Client-App-Name", "akd")
        .header("Accept", "*/*")
        .header("Content-Type", "application/x-www-form-urlencoded") // not a bug, it's how you *think different*
        .header("X-Apple-Baa-UE", "AKAuthenticationError:-7066|com.apple.devicecheck.error.baa:-10000")
        .header("X-Apple-Host-Baa-E", "-7066");

    for item in &info.hardware_headers {
        builder = builder.header(item.0, item.1);
    }

    builder
}

fn dict_get<'a>(dict: &'a Dictionary, key: &str) -> Result<&'a plist::Value, AnisetteError> {
    dict.get(key).ok_or_else(|| err(format!("Apple response is missing \"{key}\"")))
}

fn dict_dict<'a>(dict: &'a Dictionary, key: &str) -> Result<&'a Dictionary, AnisetteError> {
    dict_get(dict, key)?.as_dictionary().ok_or_else(|| err(format!("Apple response \"{key}\" is not a dictionary")))
}

fn dict_str(dict: &Dictionary, key: &str) -> Result<String, AnisetteError> {
    dict_get(dict, key)?.as_string().map(str::to_string).ok_or_else(|| err(format!("Apple response \"{key}\" is not a string")))
}

async fn apple_post(info: &LoginClientInfo, state: &AnisetteState, url: &str, body: ProvisionBodyData) -> Result<Dictionary, AnisetteError> {
    let text = build_apple_request(info, state, make_reqwest()?.post(url))
        .body(plist_to_string(&body)?)
        .send().await?
        .text().await?;
    let value = plist::Value::from_reader(Cursor::new(text.as_str()))?;
    let root = value.as_dictionary().ok_or_else(|| err("Apple response is not a dictionary".to_string()))?;
    Ok(dict_dict(root, "Response")?.clone())
}

/// Next text frame from the provisioning socket; close, end of stream, read errors and silence are errors.
async fn next_text<S>(conn: &mut S, server: &str) -> Result<String, AnisetteError>
where
    S: Stream<Item = Result<Message, tungstenite::Error>> + Unpin,
{
    loop {
        match timeout(MSG_TIMEOUT, conn.next()).await {
            Err(_) => return Err(err(format!("Anisette server {server} sent nothing for {}s", MSG_TIMEOUT.as_secs()))),
            Ok(None) => return Err(err(format!("Anisette server {server} closed the provisioning connection"))),
            Ok(Some(Err(e))) => return Err(err(format!("Anisette server {server} provisioning socket error: {e}"))),
            Ok(Some(Ok(Message::Text(text)))) => return Ok(text),
            Ok(Some(Ok(Message::Close(frame)))) => {
                let reason = frame.map(|f| format!(": {}", f.reason)).unwrap_or_default();
                return Err(err(format!("Anisette server {server} closed the provisioning connection{reason}")));
            }
            Ok(Some(Ok(_))) => continue, // ping/pong/binary
        }
    }
}

/// One provisioning attempt against one server. Returns the new adi.pb.
async fn provision_with(server: &str, info: &LoginClientInfo, state: &AnisetteState) -> Result<Vec<u8>, AnisetteError> {
    let text = build_apple_request(info, state, make_reqwest()?.get("https://gsa.apple.com/grandslam/GsService2/lookup"))
        .send().await?
        .text().await?;
    let lookup = plist::Value::from_reader(Cursor::new(text.as_str()))?;
    let lookup = lookup.as_dictionary().ok_or_else(|| err("Apple lookup response is not a dictionary".to_string()))?;
    let urls = dict_dict(lookup, "urls")?;
    let start_provisioning_url = dict_str(urls, "midStartProvisioning")?;
    let end_provisioning_url = dict_str(urls, "midFinishProvisioning")?;

    let provision_ws_url = format!("{}/v3/provisioning_session", server).replace("https://", "wss://");
    let (mut connection, _) = timeout(MSG_TIMEOUT, connect_async(&provision_ws_url)).await
        .map_err(|_| err(format!("Anisette server {server} did not accept a connection within {}s", MSG_TIMEOUT.as_secs())))?
        .map_err(|e| err(format!("Anisette server {server} connection failed: {e}")))?;

    #[derive(Deserialize)]
    #[serde(tag = "result")]
    enum ProvisionInput {
        GiveIdentifier,
        GiveStartProvisioningData,
        GiveEndProvisioningData { cpim: String },
        ProvisioningSuccess { adi_pb: String },
        StartProvisioningError { message: String },
        EndProvisioningError { message: String },
        Timeout,
    }

    loop {
        let txt = next_text(&mut connection, server).await?;
        let msg: ProvisionInput = serde_json::from_str(&txt)
            .map_err(|_| err(format!("Anisette server {server} sent an unexpected message: {txt}")))?;
        let reply = match msg {
            ProvisionInput::GiveIdentifier => {
                serde_json::json!({ "identifier": BASE64_STANDARD.encode(state.keychain_identifier) })
            },
            ProvisionInput::GiveStartProvisioningData => {
                let body = ProvisionBodyData { header: Dictionary::new(), request: Dictionary::new() };
                let response = apple_post(info, state, &start_provisioning_url, body).await?;
                serde_json::json!({ "spim": dict_str(&response, "spim")? })
            },
            ProvisionInput::GiveEndProvisioningData { cpim } => {
                let body = ProvisionBodyData { header: Dictionary::new(), request: Dictionary::from_iter([("cpim", cpim)]) };
                let response = apple_post(info, state, &end_provisioning_url, body).await?;
                serde_json::json!({ "ptm": dict_str(&response, "ptm")?, "tk": dict_str(&response, "tk")? })
            },
            ProvisionInput::ProvisioningSuccess { adi_pb } => {
                let _ = connection.close(None).await;
                return BASE64_STANDARD.decode(adi_pb.trim())
                    .map_err(|e| err(format!("Anisette server {server} sent an invalid adi_pb: {e}")));
            },
            ProvisionInput::StartProvisioningError { message } =>
                return Err(err(format!("Anisette server {server} failed to start provisioning: {message}"))),
            ProvisionInput::EndProvisioningError { message } =>
                return Err(err(format!("Anisette server {server} failed to finish provisioning: {message}"))),
            ProvisionInput::Timeout =>
                return Err(err(format!("Anisette server {server} timed out during provisioning"))),
        };
        connection.send(Message::Text(reply.to_string())).await
            .map_err(|e| err(format!("Anisette server {server} provisioning socket error: {e}")))?;
    }
}

/// Raw headers from one server. `AnisetteNotProvisioned` means adi.pb is no longer valid.
async fn headers_with(server: &str, state: &AnisetteState) -> Result<(String, String, String), AnisetteError> {
    #[derive(Serialize)]
    struct GetHeadersBody {
        identifier: String,
        adi_pb: String,
    }
    let body = GetHeadersBody {
        identifier: BASE64_STANDARD.encode(state.keychain_identifier),
        adi_pb: BASE64_STANDARD.encode(state.adi_pb.as_ref().ok_or(AnisetteError::AnisetteNotProvisioned)?),
    };

    #[derive(Deserialize)]
    #[serde(tag = "result")]
    enum AnisetteHeaders {
        GetHeadersError { message: String },
        Headers {
            #[serde(rename = "X-Apple-I-MD-M")]
            machine_id: String,
            #[serde(rename = "X-Apple-I-MD")]
            one_time_password: String,
            #[serde(rename = "X-Apple-I-MD-RINFO")]
            routing_info: String,
        },
    }

    let text = make_reqwest()?.post(format!("{}/v3/get_headers", server))
        .json(&body)
        .send().await?
        .error_for_status()?
        .text().await?;
    match serde_json::from_str::<AnisetteHeaders>(&text) {
        Ok(AnisetteHeaders::Headers { machine_id, one_time_password, routing_info }) => Ok((machine_id, one_time_password, routing_info)),
        Ok(AnisetteHeaders::GetHeadersError { message }) if message.contains("-45061") => Err(AnisetteError::AnisetteNotProvisioned),
        Ok(AnisetteHeaders::GetHeadersError { message }) => Err(err(format!("Anisette server {server} failed to get headers: {message}"))),
        Err(_) => Err(err(format!("Anisette server {server} sent an unexpected response: {text}"))),
    }
}

/// Preferred (last working) server first, then the rest in list order.
fn server_order(preferred: usize) -> Vec<(usize, &'static str)> {
    std::iter::once(preferred).chain((0..SERVERS.len()).filter(|i| *i != preferred)).map(|i| (i, SERVERS[i])).collect()
}

fn attempt_deadline(deadline: Instant) -> Instant {
    deadline.min(Instant::now() + ATTEMPT_TIMEOUT)
}

pub struct FallbackAnisetteProvider {
    state: Option<AnisetteState>,
    configuration_path: PathBuf,
    info: LoginClientInfo,
    preferred: usize,
}

impl FallbackAnisetteProvider {
    pub fn new(info: LoginClientInfo, configuration_path: PathBuf) -> FallbackAnisetteProvider {
        FallbackAnisetteProvider { state: None, configuration_path, info, preferred: 0 }
    }

    async fn provision(&mut self, deadline: Instant) -> Result<(), AnisetteError> {
        let mut failures = vec![];
        'passes: for pass in 1..=PROVISION_PASSES {
            for (i, server) in server_order(self.preferred) {
                if Instant::now() >= deadline {
                    failures.push(format!("gave up after {}s", OVERALL_TIMEOUT.as_secs()));
                    break 'passes;
                }
                info!("Anisette: provisioning with {server} (pass {pass}/{PROVISION_PASSES})");
                let state = self.state.as_ref().expect("state loaded");
                let result = timeout_at(attempt_deadline(deadline), provision_with(server, &self.info, state)).await
                    .unwrap_or_else(|_| Err(err(format!("Anisette server {server} timed out during provisioning"))));
                match result {
                    Ok(adi_pb) => {
                        info!("Anisette: provisioned with {server}");
                        self.state.as_mut().expect("state loaded").adi_pb = Some(adi_pb);
                        self.preferred = i;
                        return Ok(());
                    },
                    Err(e) => {
                        warn!("Anisette: provisioning with {server} failed: {e}");
                        failures.push(format!("{server}: {e}"));
                    },
                }
            }
        }
        Err(err(format!("Anisette provisioning failed on every server:\n{}", failures.join("\n"))))
    }

    async fn get_headers(&mut self, deadline: Instant) -> Result<HashMap<String, String>, AnisetteError> {
        let state = self.state.as_ref().expect("state loaded");
        let mut failures = vec![];
        for (i, server) in server_order(self.preferred) {
            if Instant::now() >= deadline {
                failures.push(format!("gave up after {}s", OVERALL_TIMEOUT.as_secs()));
                break;
            }
            info!("Anisette: getting headers from {server}");
            let result = timeout_at(attempt_deadline(deadline), headers_with(server, state)).await
                .unwrap_or_else(|_| Err(err(format!("Anisette server {server} timed out getting headers"))));
            match result {
                Ok((machine_id, one_time_password, routing_info)) => {
                    self.preferred = i;
                    let dt: DateTime<Utc> = Utc::now().round_subsecs(0);
                    return Ok(HashMap::from_iter([
                        ("X-Apple-I-Client-Time".to_string(), dt.format("%+").to_string().replace("+00:00", "Z")),
                        ("X-Apple-I-TimeZone".to_string(), "UTC".to_string()),
                        ("X-Apple-Locale".to_string(), "en_US".to_string()),
                        ("X-Apple-I-MD-RINFO".to_string(), routing_info),
                        ("X-Apple-I-MD-LU".to_string(), encode_hex(&state.md_lu())),
                        ("X-Mme-Device-Id".to_string(), state.device_id()),
                        ("X-Apple-I-MD".to_string(), one_time_password),
                        ("X-Apple-I-MD-M".to_string(), machine_id),
                        ("X-Mme-Client-Info".to_string(), self.info.mme_client_info.clone()),
                    ]));
                },
                // adi.pb is portable across servers, so a server rejecting it means re-provisioning is needed
                Err(AnisetteError::AnisetteNotProvisioned) => {
                    warn!("Anisette: {server} says this device is not provisioned");
                    return Err(AnisetteError::AnisetteNotProvisioned);
                },
                Err(e) => {
                    warn!("Anisette: getting headers from {server} failed: {e}");
                    failures.push(format!("{server}: {e}"));
                },
            }
        }
        Err(err(format!("Anisette headers failed on every server:\n{}", failures.join("\n"))))
    }
}

impl AnisetteProvider for FallbackAnisetteProvider {
    async fn get_anisette_headers(&mut self) -> Result<HashMap<String, String>, AnisetteError> {
        let deadline = Instant::now() + OVERALL_TIMEOUT;

        fs::create_dir_all(&self.configuration_path)?;
        let config_path = self.configuration_path.join("state.plist");
        if self.state.is_none() {
            self.state = Some(plist::from_file(&config_path).unwrap_or_else(|_| AnisetteState::new()));
        }

        if self.state.as_ref().expect("state loaded").adi_pb.is_none() {
            self.provision(deadline).await?;
            plist::to_file_xml(&config_path, self.state.as_ref().expect("state loaded"))?;
        }
        match self.get_headers(deadline).await {
            Err(AnisetteError::AnisetteNotProvisioned) => {
                self.state.as_mut().expect("state loaded").adi_pb = None;
                self.provision(deadline).await?;
                plist::to_file_xml(&config_path, self.state.as_ref().expect("state loaded"))?;
                self.get_headers(deadline).await
            },
            result => result,
        }
    }
}

pub fn default_provider(info: LoginClientInfo, path: PathBuf) -> ArcAnisetteClient<FallbackAnisetteProvider> {
    Arc::new(Mutex::new(AnisetteClient::new(FallbackAnisetteProvider::new(info, path))))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_order_puts_preferred_first() {
        assert_eq!(server_order(0).iter().map(|s| s.0).collect::<Vec<_>>(), vec![0, 1, 2]);
        assert_eq!(server_order(1).iter().map(|s| s.0).collect::<Vec<_>>(), vec![1, 0, 2]);
        assert_eq!(server_order(2).iter().map(|s| s.0).collect::<Vec<_>>(), vec![2, 0, 1]);
    }
}
