//! `pixi-build-bazel`: an experimental pixi build backend for Bazel workspaces.
//!
//! Every `conda_package` target (rules_rattler) in the workspace is a conda
//! output. `conda/outputs` finds them with a Bazel dry run (`cquery`, analysis
//! only); pixi picks the ones it needs and `conda/build_v1` builds each with
//! `bazel build`, against the host environment pixi installed.
//!
//! Speaks JSON-RPC over stdin/stdout, like every pixi build backend.

mod bazel;
mod protocol;

use std::{path::PathBuf, sync::Arc};

use jsonrpc_core::{Error, ErrorCode, IoHandler, Params, to_value};
use pixi_build_types::{
    BackendCapabilities,
    procedures::{
        conda_build_v1::{self, CondaBuildV1Params},
        conda_outputs::{self, CondaOutputsParams},
        initialize::{self, InitializeParams, InitializeResult},
        negotiate_capabilities::{self, NegotiateCapabilitiesParams, NegotiateCapabilitiesResult},
    },
};
use tokio::sync::RwLock;

use crate::protocol::{BazelBackend, Config};

fn rpc_error(err: miette::Report) -> Error {
    // Same shape as pixi's own backends: pixi renders `data` as a diagnostic.
    let mut json = String::new();
    let data = miette::JSONReportHandler::new()
        .render_report(&mut json, err.as_ref())
        .ok()
        .and_then(|_| serde_json::from_str(&json).ok());
    Error {
        code: ErrorCode::ServerError(-32000),
        message: err.to_string(),
        data,
    }
}

type State = Arc<RwLock<Option<Arc<BazelBackend>>>>;

async fn backend(state: &State) -> Result<Arc<BazelBackend>, Error> {
    state.read().await.clone().ok_or_else(Error::invalid_request)
}

fn initialize(params: InitializeParams) -> miette::Result<BazelBackend> {
    let manifest_dir = params
        .manifest_path
        .parent()
        .map(PathBuf::from)
        .unwrap_or_default();
    let workspace = params.source_directory.unwrap_or(manifest_dir);
    let config: Config = match params.configuration {
        Some(value) => serde_json::from_value(value)
            .map_err(|e| miette::miette!("invalid [package.build.config]: {e}"))?,
        None => Config::default(),
    };
    Ok(BazelBackend::new(workspace, config))
}

#[tokio::main]
async fn main() {
    if std::env::args().nth(1).as_deref() == Some("--version") {
        println!("pixi-build-bazel {}", env!("CARGO_PKG_VERSION"));
        return;
    }

    let state: State = Arc::new(RwLock::new(None));
    let mut io = IoHandler::new();

    io.add_method(negotiate_capabilities::METHOD_NAME, |params: Params| async move {
        let _: NegotiateCapabilitiesParams = params.parse()?;
        Ok(to_value(NegotiateCapabilitiesResult {
            capabilities: BackendCapabilities {
                provides_conda_outputs: Some(true),
                provides_conda_build_v1: Some(true),
            },
        })
        .expect("serializable"))
    });

    let s = state.clone();
    io.add_method(initialize::METHOD_NAME, move |params: Params| {
        let state = s.clone();
        async move {
            let params: InitializeParams = params.parse()?;
            let backend = initialize(params).map_err(rpc_error)?;
            *state.write().await = Some(Arc::new(backend));
            Ok(to_value(InitializeResult {}).expect("serializable"))
        }
    });

    let s = state.clone();
    io.add_method(conda_outputs::METHOD_NAME, move |params: Params| {
        let state = s.clone();
        async move {
            let params: CondaOutputsParams = params.parse()?;
            let result = backend(&state).await?.conda_outputs(params).await.map_err(rpc_error)?;
            Ok(to_value(result).expect("serializable"))
        }
    });

    let s = state.clone();
    io.add_method(conda_build_v1::METHOD_NAME, move |params: Params| {
        let state = s.clone();
        async move {
            let params: CondaBuildV1Params = params.parse()?;
            let result = backend(&state).await?.conda_build_v1(params).await.map_err(rpc_error)?;
            Ok(to_value(result).expect("serializable"))
        }
    });

    jsonrpc_stdio_server::ServerBuilder::new(io).build().await;
}
