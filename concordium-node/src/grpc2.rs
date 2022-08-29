use prost::bytes::BufMut;
use std::{convert::TryFrom, marker::PhantomData};

pub mod types {
    use self::account_info_request::AccountIdentifier;

    include!(concat!(env!("OUT_DIR"), "/concordium.v2.rs"));

    pub(crate) fn account_identifier_to_ffi(
        account_identifier: &AccountIdentifier,
    ) -> Option<(u8, *const u8)> {
        match account_identifier {
            AccountIdentifier::Address(addr) if addr.value.len() == 32 => {
                Some((0u8, addr.value.as_ptr()))
            }
            AccountIdentifier::CredId(cred_id) if cred_id.value.len() == 48 => {
                Some((1u8, cred_id.value.as_ptr()))
            }
            AccountIdentifier::AccountIndex(ai) => {
                Some((2u8, (&ai.value) as *const u64 as *const u8))
            }
            _ => None,
        }
    }

    pub(crate) fn block_hash_input_to_ffi(bhi: &BlockHashInput) -> Option<(u8, *const u8)> {
        use block_hash_input::BlockHashInput::*;
        match bhi.block_hash_input.as_ref()? {
            Best(_) => Some((0, std::ptr::null())),
            LastFinal(_) => Some((1, std::ptr::null())),
            Given(bh) if bh.value.len() == 32 => Some((2, bh.value.as_ptr())),
            _ => None,
        }
    }
}

pub mod service {
    include!(concat!(env!("OUT_DIR"), "/concordium.v2.Queries.rs"));
}

pub struct RawCodec<E, D>(PhantomData<E>, PhantomData<D>);
impl<E, D> Default for RawCodec<E, D> {
    fn default() -> Self { Self(Default::default(), Default::default()) }
}

impl<E: AsRef<[u8]> + Send + Sync + 'static, D: prost::Message + Default + 'static>
    tonic::codec::Codec for RawCodec<E, D>
{
    type Decode = D;
    type Decoder = RawDecoder<D>;
    type Encode = E;
    type Encoder = RawEncoder<E>;

    fn encoder(&mut self) -> Self::Encoder { RawEncoder::default() }

    fn decoder(&mut self) -> Self::Decoder { RawDecoder::default() }
}

pub struct RawEncoder<E>(PhantomData<E>);

impl<E> Default for RawEncoder<E> {
    fn default() -> Self { Self(Default::default()) }
}

impl<E: AsRef<[u8]>> tonic::codec::Encoder for RawEncoder<E> {
    type Error = tonic::Status;
    type Item = E;

    fn encode(
        &mut self,
        item: Self::Item,
        dst: &mut tonic::codec::EncodeBuf<'_>,
    ) -> Result<(), Self::Error> {
        dst.reserve(item.as_ref().len());
        dst.put_slice(item.as_ref());
        Ok(())
    }
}

pub struct RawDecoder<D>(PhantomData<D>);

impl<D> Default for RawDecoder<D> {
    fn default() -> Self { RawDecoder(Default::default()) }
}

impl<D: prost::Message + Default> tonic::codec::Decoder for RawDecoder<D> {
    type Error = tonic::Status;
    type Item = D;

    fn decode(
        &mut self,
        src: &mut tonic::codec::DecodeBuf<'_>,
    ) -> Result<Option<Self::Item>, Self::Error> {
        D::decode(src).map(Option::Some).map_err(|e| tonic::Status::internal(e.to_string()))
    }
}

pub mod server {
    use std::sync::{Arc, Mutex};

    use anyhow::Context;
    use futures::{FutureExt, StreamExt};
    use tonic::{async_trait, transport::ServerTlsConfig};

    use crate::{
        configuration::GRPC2Config,
        consensus_ffi::{consensus::ConsensusContainer, ffi::NotificationHandlers},
        p2p::P2PNode,
    };

    use super::*;

    /// An updatable list of listeners for events generated by the node.
    type Clients = Arc<Mutex<Vec<tokio::sync::mpsc::Sender<Result<Arc<[u8]>, tonic::Status>>>>>;

    struct RpcServerImpl {
        node: Arc<P2PNode>,
        consensus: ConsensusContainer,
        blocks_channels: Clients,
        finalized_blocks_channels: Clients,
    }

    pub struct GRPC2Server {
        task:                   tokio::task::JoinHandle<Result<(), tonic::transport::Error>>,
        shutdown_sender:        tokio::sync::oneshot::Sender<()>,
        blocks_relay:           tokio::task::JoinHandle<()>,
        finalized_blocks_relay: tokio::task::JoinHandle<()>,
    }

    impl GRPC2Server {
        /// Creates a new RPC server if the configuration demands it.
        /// Otherwise returns `Ok(None)`.
        pub fn new(
            node: &Arc<P2PNode>,
            consensus: &ConsensusContainer,
            config: &GRPC2Config,
            notification_handlers: NotificationHandlers,
        ) -> anyhow::Result<Option<Self>> {
            if let Some(listen_addr) = config.api_listen_addr {
                let identity = match (&config.api_x509_cert, &config.api_cert_private_key) {
                    (None, None) => None,
                    (None, Some(_)) => {
                        anyhow::bail!("Private key supplied, but not the certificate.")
                    }
                    (Some(_), None) => {
                        anyhow::bail!("Certificate supplied, but not the private key.")
                    }
                    (Some(cert_path), Some(key_path)) => {
                        let cert =
                            std::fs::read(cert_path).context("Unable to read certificate.")?;
                        let key = std::fs::read(key_path).context("Unable to read key.")?;
                        let identity = tonic::transport::Identity::from_pem(cert, key);
                        Some(identity)
                    }
                };
                let server = RpcServerImpl {
                    node: Arc::clone(node),
                    consensus: consensus.clone(),
                    blocks_channels: Arc::new(Mutex::new(Vec::new())),
                    finalized_blocks_channels: Arc::new(Mutex::new(Vec::new())),
                };

                let NotificationHandlers {
                    mut blocks,
                    mut finalized_blocks,
                } = notification_handlers;

                let blocks_channel = server.blocks_channels.clone();
                let blocks_relay = tokio::spawn(async move {
                    while let Some(v) = blocks.next().await {
                        match blocks_channel.lock() {
                            Ok(mut senders) => senders.retain(|sender| {
                                if let Err(e) = sender.try_send(Ok(v.clone())) {
                                    match e {
                                        tokio::sync::mpsc::error::TrySendError::Full(_) => true,
                                        tokio::sync::mpsc::error::TrySendError::Closed(_) => {
                                            debug!("Dropping client.");
                                            false
                                        }
                                    }
                                } else {
                                    true
                                }
                            }),
                            Err(e) => {
                                error!("Could not acquire lock to the list of receivers: {}.", e)
                            }
                        }
                    }
                });

                let finalized_blocks_channel = server.finalized_blocks_channels.clone();
                let finalized_blocks_relay = tokio::spawn(async move {
                    while let Some(v) = finalized_blocks.next().await {
                        match finalized_blocks_channel.lock() {
                            Ok(mut senders) => senders.retain(|sender| {
                                if let Err(e) = sender.try_send(Ok(v.clone())) {
                                    match e {
                                        tokio::sync::mpsc::error::TrySendError::Full(_) => true,
                                        tokio::sync::mpsc::error::TrySendError::Closed(_) => {
                                            debug!(
                                                "Dropping client listening for finalized blocks."
                                            );
                                            false
                                        }
                                    }
                                } else {
                                    true
                                }
                            }),
                            Err(e) => {
                                error!("Could not acquire lock to the list of receivers: {}.", e)
                            }
                        }
                    }
                });
                let service = service::queries_server::QueriesServer::new(server);
                let log_layer = tower_http::trace::TraceLayer::new_for_grpc();
                let mut builder = tonic::transport::Server::builder().layer(log_layer);
                if let Some(identity) = identity {
                    builder = builder
                        .tls_config(ServerTlsConfig::new().identity(identity))
                        .context("Unable to configure TLS.")?;
                } else {
                    // if TLS is not enabled and we want grpc-web we need to explicitly
                    // enable http1 support.
                    // This is because TLS supports protocol negotiation.
                    if config.api_enable_grpc_web {
                        builder = builder.accept_http1(true);
                    }
                }

                let (shutdown_sender, shutdown_receiver) = tokio::sync::oneshot::channel::<()>();

                let router = if config.api_enable_grpc_web {
                    builder.add_service(tonic_web::enable(service))
                } else {
                    builder.add_service(service)
                };

                let task = tokio::spawn(async move {
                    router.serve_with_shutdown(listen_addr, shutdown_receiver.map(|_| ())).await
                });
                Ok(Some(Self {
                    task,
                    shutdown_sender,
                    blocks_relay,
                    finalized_blocks_relay,
                }))
            } else {
                Ok(None)
            }
        }

        pub async fn shutdown(self) {
            if self.shutdown_sender.send(()).is_err() {
                error!("Could not stop the GRPC2 server correctly. Forcing shutdown.");
                self.task.abort();
            }
            self.blocks_relay.abort();
            self.finalized_blocks_relay.abort();
            // Force the rpc server to shut down in at most 10 seconds.
            let timeout_duration = std::time::Duration::from_secs(10);
            match tokio::time::timeout(timeout_duration, self.task).await {
                Ok(res) => {
                    if let Err(err) = res {
                        if err.is_cancelled() {
                            info!("GRPC2 server was successfully stopped.");
                        } else if err.is_panic() {
                            error!("GRPC2 server panicked: {}", err);
                        }
                    }
                }
                Err(timed_out) => {
                    warn!("RPC server was forcefully shut down due to: {}", timed_out);
                }
            }
        }
    }

    #[async_trait]
    impl service::queries_server::Queries for RpcServerImpl {
        type GetAccountListStream =
            futures::channel::mpsc::Receiver<Result<Vec<u8>, tonic::Status>>;
        type GetAncestorsStream = futures::channel::mpsc::Receiver<Result<Vec<u8>, tonic::Status>>;
        ///Server streaming response type for the FinalizedBlocks method.
        type GetFinalizedBlocksStream =
            tokio_stream::wrappers::ReceiverStream<Result<Arc<[u8]>, tonic::Status>>;
        type GetInstanceListStream =
            futures::channel::mpsc::Receiver<Result<Vec<u8>, tonic::Status>>;
        type GetModuleListStream = futures::channel::mpsc::Receiver<Result<Vec<u8>, tonic::Status>>;

        async fn get_finalized_blocks(
            &self,
            _request: tonic::Request<crate::grpc2::types::Empty>,
        ) -> Result<tonic::Response<Self::GetFinalizedBlocksStream>, tonic::Status> {
            let (sender, receiver) = tokio::sync::mpsc::channel(100);
            match self.finalized_blocks_channels.lock() {
                Ok(mut fbs) => {
                    fbs.push(sender);
                }
                Err(e) => {
                    error!("Could not acquire lock: {}", e);
                    return Err(tonic::Status::internal("Could not enqueue request."));
                }
            }
            Ok(tonic::Response::new(tokio_stream::wrappers::ReceiverStream::new(receiver)))
        }

        async fn get_account_info(
            &self,
            request: tonic::Request<crate::grpc2::types::AccountInfoRequest>,
        ) -> Result<tonic::Response<Vec<u8>>, tonic::Status> {
            let request = request.get_ref();
            let block_hash = request.block_hash.require()?;
            let account_identifier = request.account_identifier.require()?;
            let (hash, response) =
                self.consensus.get_account_info_v2(block_hash, account_identifier)?;
            let mut response = tonic::Response::new(response);
            add_hash(&mut response, hash)?;
            Ok(response)
        }

        async fn get_account_list(
            &self,
            request: tonic::Request<crate::grpc2::types::BlockHashInput>,
        ) -> Result<tonic::Response<Self::GetAccountListStream>, tonic::Status> {
            let (sender, receiver) = futures::channel::mpsc::channel(100);
            let hash = self.consensus.get_account_list_v2(request.get_ref(), sender)?;
            let mut response = tonic::Response::new(receiver);
            add_hash(&mut response, hash)?;
            Ok(response)
        }

        async fn get_module_list(
            &self,
            request: tonic::Request<crate::grpc2::types::BlockHashInput>,
        ) -> Result<tonic::Response<Self::GetModuleListStream>, tonic::Status> {
            let (sender, receiver) = futures::channel::mpsc::channel(100);
            let hash = self.consensus.get_module_list_v2(request.get_ref(), sender)?;
            let mut response = tonic::Response::new(receiver);
            add_hash(&mut response, hash)?;
            Ok(response)
        }

        async fn get_module_source(
            &self,
            request: tonic::Request<crate::grpc2::types::ModuleSourceRequest>,
        ) -> Result<tonic::Response<Vec<u8>>, tonic::Status> {
            let request = request.get_ref();
            let block_hash = request.block_hash.require()?;
            let module_ref = request.module_ref.require()?;
            let (hash, response) = self.consensus.get_module_source_v2(block_hash, module_ref)?;
            let mut response = tonic::Response::new(response);
            add_hash(&mut response, hash)?;
            Ok(response)
        }

        async fn get_instance_list(
            &self,
            request: tonic::Request<crate::grpc2::types::BlockHashInput>,
        ) -> Result<tonic::Response<Self::GetInstanceListStream>, tonic::Status> {
            let (sender, receiver) = futures::channel::mpsc::channel(100);
            let hash = self.consensus.get_instance_list_v2(request.get_ref(), sender)?;
            let mut response = tonic::Response::new(receiver);
            add_hash(&mut response, hash)?;
            Ok(response)
        }

        async fn get_instance_info(
            &self,
            request: tonic::Request<crate::grpc2::types::InstanceInfoRequest>,
        ) -> Result<tonic::Response<Vec<u8>>, tonic::Status> {
            let request = request.get_ref();
            let block_hash = request.block_hash.require()?;
            let contract_address = request.address.require()?;
            let (hash, response) =
                self.consensus.get_instance_info_v2(block_hash, contract_address)?;
            let mut response = tonic::Response::new(response);
            add_hash(&mut response, hash)?;
            Ok(response)
        }

        async fn get_ancestors(
            &self,
            request: tonic::Request<crate::grpc2::types::AncestorsRequest>,
        ) -> Result<tonic::Response<Self::GetAncestorsStream>, tonic::Status> {
            let (sender, receiver) = futures::channel::mpsc::channel(100);
            let request = request.get_ref();
            let block_hash = request.block_hash.require()?;
            let amount = request.amount;
            let hash = self.consensus.get_ancestors_v2(block_hash, amount, sender)?;
            let mut response = tonic::Response::new(receiver);
            add_hash(&mut response, hash)?;
            Ok(response)
        }
    }
}

/// Add a block hash to the metadata of a response. Used for returning the block
/// hash for streaming responses.
fn add_hash<T>(response: &mut tonic::Response<T>, hash: [u8; 32]) -> Result<(), tonic::Status> {
    let value = tonic::metadata::MetadataValue::try_from(hex::encode(&hash))
        .map_err(|_| tonic::Status::internal("Cannot add metadata hash."))?;
    response.metadata_mut().insert("blockhash", value);
    Ok(())
}

/// A helper trait to make it simpler to require specific fields when parsing a
/// protobuf message by allowing us to use method calling syntax and
/// constructing responses that match the calling context, allowing us to use
/// the `?` syntax.
///
/// The main reason for needing this is that in proto3 all fields are optional,
/// so it is up to the application to validate inputs if they are required.
pub(crate) trait Require<E> {
    type A;
    fn require(&self) -> Result<&Self::A, E>;
    fn require_owned(self) -> Result<Self::A, E>;
}

impl<A> Require<tonic::Status> for Option<A> {
    type A = A;

    fn require(&self) -> Result<&Self::A, tonic::Status> {
        match self {
            Some(v) => Ok(v),
            None => Err(tonic::Status::invalid_argument("missing field")),
        }
    }

    fn require_owned(self) -> Result<Self::A, tonic::Status> {
        match self {
            Some(v) => Ok(v),
            None => Err(tonic::Status::invalid_argument("missing field")),
        }
    }
}
