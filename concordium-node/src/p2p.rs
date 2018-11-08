use atomic_counter::AtomicCounter;
use atomic_counter::RelaxedCounter;
use byteorder::{NetworkEndian, ReadBytesExt, WriteBytesExt};
use bytes::{BufMut, BytesMut};
use common;
use common::{
    ConnectionType, NetworkMessage, NetworkPacket, NetworkRequest, NetworkResponse, P2PNodeId,
    P2PPeer,
};
use errors::*;
use get_if_addrs;
use mio::net::TcpListener;
use mio::net::TcpStream;
use mio::*;
use num_bigint::BigUint;
use num_bigint::ToBigUint;
use num_traits::pow;
use prometheus_exporter::PrometheusServer;
use rand::{thread_rng, Rng};
use rustls::{
    Certificate, ClientConfig, ClientSession, NoClientAuth, PrivateKey, RootCertStore,
    ServerCertVerified, ServerCertVerifier, ServerConfig, ServerSession, Session, TLSError,
};
use std::collections::{HashMap, HashSet, VecDeque};
use std::io;
use std::io::Cursor;
use std::io::Error;
use std::io::ErrorKind;
use std::io::Read;
use std::io::Write;
use std::net::IpAddr;
use std::net::IpAddr::{V4, V6};
use std::net::{Shutdown, SocketAddr};
use std::str::FromStr;
use std::sync::mpsc;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use time;
use time::Timespec;
use utils;
use vecio::Rawv;
use webpki::DNSNameRef;

const SERVER: Token = Token(0);
const BUCKET_SIZE: u8 = 20;
const KEY_SIZE: u16 = 256;
const BOOTSTRAP_PEER_COUNT: usize = 100;
const MAX_UNREACHABLE_MARK_TIME: u64 = 1000 * 60 * 60 * 24;
const MAX_FAILED_PACKETS_ALLOWED: u32 = 50;

lazy_static! {
    static ref TOTAL_MESSAGES_RECEIVED_COUNTER: RelaxedCounter = { RelaxedCounter::new(0) };
    static ref TOTAL_MESSAGES_SENT_COUNTER: RelaxedCounter = { RelaxedCounter::new(0) };
}

pub struct WriteVAdapter<'a> {
    rawv: &'a mut Rawv,
}

impl<'a> WriteVAdapter<'a> {
    pub fn new(rawv: &'a mut Rawv) -> WriteVAdapter<'a> {
        WriteVAdapter { rawv }
    }
}

impl<'a> rustls::WriteV for WriteVAdapter<'a> {
    fn writev(&mut self, bytes: &[&[u8]]) -> io::Result<usize> {
        self.rawv.writev(bytes)
    }
}

#[derive(Debug, Clone)]
struct SeenMessagesList {
    seen_msgs: Arc<Mutex<Vec<String>>>,
}

impl SeenMessagesList {
    fn new() -> Self {
        SeenMessagesList { seen_msgs: Arc::new(Mutex::new(Vec::new())), }
    }

    fn contains(&self, msgid: &String) -> bool {
        if let Ok(ref mut list) = self.seen_msgs.lock() {
            return list.contains(msgid);
        }
        false
    }

    fn append(&self, msgid: &String) -> bool {
        if let Ok(ref mut list) = self.seen_msgs.lock() {
            if !list.contains(msgid) {
                if list.len() >= 1000 {
                    list.remove(0);
                    list.push(msgid.clone().to_owned());
                } else {
                    list.push(msgid.clone().to_owned());
                }
            }
            true
        } else {
            false
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum P2PNodeMode {
    NormalMode,
    NormalPrivateMode,
    BootstrapperMode,
    BootstrapperPrivateMode,
}

#[derive(Clone, Debug, PartialEq)]
pub enum P2PEvent {
    ConnectEvent(String, u16),
    DisconnectEvent(String),
    ReceivedMessageEvent(P2PNodeId),
    SentMessageEvent(P2PNodeId),
    InitiatingConnection(IpAddr, u16),
    JoinedNetwork(P2PPeer, u16),
    LeftNetwork(P2PPeer, u16),
}

struct Buckets {
    buckets: HashMap<u16, Vec<(P2PPeer, Vec<u16>)>>,
}

impl Buckets {
    fn new() -> Buckets {
        let mut buckets = HashMap::new();
        for i in 0..KEY_SIZE {
            buckets.insert(i, Vec::new());
        }

        Buckets { buckets }
    }

    pub fn distance(&self, from: &P2PNodeId, to: &P2PNodeId) -> BigUint {
        from.get_id().clone() ^ to.get_id().clone()
    }

    pub fn insert_into_bucket(&mut self, node: &P2PPeer, own_id: &P2PNodeId, nids: Vec<u16>) {
        let dist = self.distance(&own_id, &node.id());
        for i in 0..KEY_SIZE {
            match self.buckets.get_mut(&i) {
                Some(x) => {
                    x.retain(|ref ele| ele.0 != *node);
                }
                _ => {}
            }
            if dist >= pow(2_i8.to_biguint().unwrap(), i as usize)
               && dist < pow(2_i8.to_biguint().unwrap(), (i as usize) + 1)
            {
                match self.buckets.get_mut(&i) {
                    Some(x) => {
                        if x.len() >= BUCKET_SIZE as usize {
                            x.remove(0);
                        }
                        x.push((node.clone(), nids.clone()));
                        break;
                    }
                    None => {
                        error!("Couldn't get bucket as mutable");
                    }
                }
            }
        }
    }

    pub fn update_network_ids(&mut self, node: &P2PPeer, nids: Vec<u16>) {
        for i in 0..KEY_SIZE {
            match self.buckets.get_mut(&i) {
                Some(x) => {
                    x.retain(|ref ele| ele.0 != *node);
                    x.push((node.clone(), nids.clone()));
                    break;
                }
                None => {
                    error!("Couldn't get buck as mutable");
                }
            }
        }
    }

    fn _find_bucket_id(&mut self, own_id: P2PNodeId, id: P2PNodeId) -> Option<u16> {
        let dist = self.distance(&own_id, &id);
        let mut ret: i32 = -1;
        for i in 0..KEY_SIZE {
            if dist >= pow(2_i8.to_biguint().unwrap(), i as usize)
               && dist < pow(2_i8.to_biguint().unwrap(), (i as usize) + 1)
            {
                ret = i as i32;
            }
        }

        if ret == -1 {
            None
        } else {
            Some(ret as u16)
        }
    }

    fn closest_nodes(&self, _id: &P2PNodeId) -> Vec<P2PPeer> {
        let mut ret: Vec<P2PPeer> = Vec::with_capacity(KEY_SIZE as usize);
        let mut count = 0;
        for (_, bucket) in &self.buckets {
            //Fix later to do correctly
            if count < KEY_SIZE {
                for peer in bucket {
                    if count < KEY_SIZE {
                        ret.push(peer.0.clone());
                        count += 1;
                    } else {
                        break;
                    }
                }
            } else {
                break;
            }
        }
        ret
    }

    fn clean_peers_older_than(&mut self, older_than: u64) {
        debug!("Cleaning buckets currently at {}", self.len());
        for i in 0..KEY_SIZE {
            match self.buckets.get_mut(&i) {
                Some(x) => {
                    x.retain(|ref ele| ele.0.last_seen() >= older_than);
                }
                None => {
                    error!("Couldn't get bucket as mutable");
                }
            }
        }
    }

    pub fn get_all_nodes(&self, sender: Option<&P2PPeer>, networks: &Vec<u16>) -> Vec<P2PPeer> {
        let mut ret: Vec<P2PPeer> = Vec::new();
        match sender {
            Some(sender_peer) => {
                for (_, bucket) in &self.buckets {
                    for peer in bucket {
                        if sender_peer != &peer.0
                           && peer.0.connection_type() == ConnectionType::Node
                           && (networks.len() == 0 || peer.1.iter().any(|x| networks.contains(x)))
                        {
                            ret.push(peer.0.clone());
                        }
                    }
                }
            }
            None => {
                for (_, bucket) in &self.buckets {
                    for peer in bucket {
                        if peer.0.connection_type() == ConnectionType::Node
                           && (networks.len() == 0 || peer.1.iter().any(|x| networks.contains(x)))
                        {
                            ret.push(peer.0.clone());
                        }
                    }
                }
            }
        }

        ret
    }

    pub fn len(&self) -> usize {
        self.buckets.iter().map(|(_, y)| y.len() as usize).sum()
    }

    pub fn get_random_nodes(&self,
                            sender: &P2PPeer,
                            amount: usize,
                            nids: &Vec<u16>)
                            -> Vec<P2PPeer> {
        let mut ret: Vec<P2PPeer> = self.get_all_nodes(Some(sender), nids);
        thread_rng().shuffle(&mut ret);
        ret.truncate(amount);
        ret
    }
}

#[derive(Debug)]
pub struct PeerStatistic {
    pub id: String,
    pub ip: IpAddr,
    pub port: u16,
    pub sent: u64,
    pub received: u64,
    pub measured_latency: Option<u64>,
}

impl PeerStatistic {
    pub fn new(id: String,
               ip: IpAddr,
               port: u16,
               sent: u64,
               received: u64,
               measured_latency: Option<u64>)
               -> PeerStatistic {
        PeerStatistic { id,
                        ip,
                        port,
                        sent,
                        received,
                        measured_latency, }
    }

    pub fn id(&self) -> String {
        self.id.clone()
    }

    pub fn sent(&self) -> u64 {
        self.sent
    }

    pub fn received(&self) -> u64 {
        self.received
    }

    pub fn measured_latency(&self) -> Option<u64> {
        self.measured_latency.clone()
    }

    pub fn ip(&self) -> IpAddr {
        self.ip.clone()
    }

    pub fn port(&self) -> u16 {
        self.port
    }
}

#[derive(Clone, Debug)]
struct UnreachableNodes {
    nodes: Arc<Mutex<Vec<(u64, IpAddr, u16)>>>,
}

impl UnreachableNodes {
    fn new() -> Self {
        UnreachableNodes { nodes: Arc::new(Mutex::new(vec![])), }
    }

    fn contains(&self, ip: IpAddr, port: u16) -> bool {
        if let Ok(ref mut nodes) = self.nodes.lock() {
            return nodes.iter()
                        .find(|&&x| {
                                  let (_, mip, mport) = x;
                                  ip == mip && port == mport
                              })
                        .is_some();
        }
        true
    }

    fn insert(&mut self, ip: IpAddr, port: u16) -> bool {
        if let Ok(ref mut nodes) = self.nodes.lock() {
            nodes.push((common::get_current_stamp(), ip.clone(), port));
            true
        } else {
            false
        }
    }

    fn cleanup(&mut self, since: u64) -> bool {
        if let Ok(ref mut nodes) = self.nodes.lock() {
            nodes.retain(|&x| {
                             let (time, _, _) = x;
                             time >= since
                         });
            true
        } else {
            false
        }
    }
}

struct TlsServer {
    server: TcpListener,
    connections: HashMap<Token, Connection>,
    next_id: usize,
    server_tls_config: Arc<ServerConfig>,
    client_tls_config: Arc<ClientConfig>,
    own_id: P2PNodeId,
    event_log: Option<Sender<P2PEvent>>,
    self_peer: P2PPeer,
    banned_peers: HashSet<P2PPeer>,
    mode: P2PNodeMode,
    prometheus_exporter: Option<Arc<Mutex<PrometheusServer>>>,
    networks: Arc<Mutex<Vec<u16>>>,
    unreachable_nodes: UnreachableNodes,
    seen_messages: SeenMessagesList,
}

impl TlsServer {
    fn new(server: TcpListener,
           server_cfg: Arc<ServerConfig>,
           client_cfg: Arc<ClientConfig>,
           own_id: P2PNodeId,
           event_log: Option<Sender<P2PEvent>>,
           self_peer: P2PPeer,
           mode: P2PNodeMode,
           prometheus_exporter: Option<Arc<Mutex<PrometheusServer>>>,
           networks: Vec<u16>,
           seen_messages: SeenMessagesList)
           -> TlsServer {
        TlsServer { server,
                    connections: HashMap::new(),
                    next_id: 2,
                    server_tls_config: server_cfg,
                    client_tls_config: client_cfg,
                    own_id,
                    event_log,
                    self_peer,
                    banned_peers: HashSet::new(),
                    mode: mode,
                    prometheus_exporter: prometheus_exporter,
                    networks: Arc::new(Mutex::new(networks)),
                    unreachable_nodes: UnreachableNodes::new(),
                    seen_messages: seen_messages, }
    }

    fn log_event(&mut self, event: P2PEvent) {
        match self.event_log {
            Some(ref mut x) => {
                match x.send(event) {
                    Ok(_) => {}
                    Err(e) => error!("Couldn't send error {:?}", e),
                };
            }
            _ => {}
        }
    }

    fn get_self_peer(&self) -> P2PPeer {
        self.self_peer.clone()
    }

    fn remove_network(&mut self, network_id: &u16) -> ResultExtWrapper<()> {
        self.networks.lock()?.retain(|x| x == network_id);
        Ok(())
    }

    fn add_network(&mut self, network_id: &u16) -> ResultExtWrapper<()> {
        {
            let mut networks = self.networks.lock()?;
            if !networks.contains(network_id) {
                networks.push(*network_id)
            }
        }
        Ok(())
    }

    pub fn get_peer_stats(&self, nids: &Vec<u16>) -> Vec<PeerStatistic> {
        let mut ret = vec![];
        for (_, ref conn) in &self.connections {
            match conn.peer {
                Some(ref x) => {
                    if nids.len() == 0 || conn.networks.iter().any(|nid| nids.contains(nid)) {
                        ret.push(PeerStatistic::new(x.id().to_string(),
                                                    x.ip().clone(),
                                                    x.port(),
                                                    conn.get_messages_sent(),
                                                    conn.get_messages_received(),
                                                    conn.get_last_latency_measured()));
                    }
                }
                None => {}
            }
        }

        ret
    }

    pub fn ban_node(&mut self, peer: P2PPeer) -> bool {
        self.banned_peers.insert(peer)
    }

    pub fn unban_node(&mut self, peer: P2PPeer) -> bool {
        self.banned_peers.remove(&peer)
    }

    fn accept(&mut self, poll: &mut Poll, self_id: P2PPeer) -> ResultExtWrapper<()> {
        match self.server.accept() {
            Ok((socket, addr)) => {
                debug!("Accepting new connection from {:?}", addr);
                self.log_event(P2PEvent::ConnectEvent(format!("{}", addr.ip()), addr.port()));

                let tls_session = ServerSession::new(&self.server_tls_config);
                let token = Token(self.next_id);
                self.next_id += 1;

                self.connections.insert(token,
                                        Connection::new(ConnectionType::Node,
                                                        socket,
                                                        token,
                                                        Some(tls_session),
                                                        None,
                                                        false,
                                                        self.own_id.clone(),
                                                        self_id.clone(),
                                                        addr.ip().clone(),
                                                        addr.port().clone(),
                                                        self.mode,
                                                        self.prometheus_exporter.clone(),
                                                        self.event_log.clone(),
                                                        self.networks.clone(),
                                                        self.seen_messages.clone()));
                self.connections[&token].register(poll)
            }
            Err(e) => Err(ErrorKindWrapper::InternalIOError(e).into()),
        }
    }

    fn connect(&mut self,
               connection_type: ConnectionType,
               poll: &mut Poll,
               ip: IpAddr,
               port: u16,
               peer_id: Option<P2PNodeId>,
               self_id: &P2PPeer)
               -> ResultExtWrapper<()> {
        if connection_type == ConnectionType::Node && self.unreachable_nodes.contains(ip, port) {
            error!("Node marked as unreachable, so not allowing the connection");
            return Err(ErrorKindWrapper::UnreachablePeerError("Peer marked as unreachable, won't try it".to_string()).into());
        }
        let self_peer = self.get_self_peer();
        if self_peer.ip() == ip && self_peer.port() == port {
            return Err(ErrorKindWrapper::DuplicatePeerError("Already connected to peer".to_string()).into());
        }
        for (_, ref conn) in &self.connections {
            if let Some(ref peer) = conn.peer {
                if peer.ip() == ip && peer.port() == port {
                    return Err(ErrorKindWrapper::DuplicatePeerError("Already connected to peer".to_string()).into());
                } else if let Some(ref new_peer_id) = peer_id {
                    if new_peer_id == &peer.id() {
                        return Err(ErrorKindWrapper::DuplicatePeerError("Already connected to peer".to_string()).into());
                    }
                }
            } else if conn.ip() == ip && conn.port() == port {
                return Err(ErrorKindWrapper::DuplicatePeerError("Already connected to peer".to_string()).into());
            }
        }
        match TcpStream::connect(&SocketAddr::new(ip, port)) {
            Ok(x) => {
                if let Some(ref prom) = &self.prometheus_exporter {
                    prom.lock()?
                        .conn_received_inc()
                        .map_err(|e| error!("{}", e))
                        .ok();
                };
                let tls_session =
                    ClientSession::new(&self.client_tls_config,
                                       match DNSNameRef::try_from_ascii_str(&"node.concordium.com")
                                       {
                                           Ok(x) => x,
                                           Err(e) => panic!("The error is: {:?}", e),
                                       });

                let token = Token(self.next_id);

                let conn = Connection::new(connection_type,
                                           x,
                                           token,
                                           None,
                                           Some(tls_session),
                                           true,
                                           self.own_id.clone(),
                                           self_id.clone(),
                                           ip,
                                           port,
                                           self.mode,
                                           self.prometheus_exporter.clone(),
                                           self.event_log.clone(),
                                           self.networks.clone(),
                                           self.seen_messages.clone());

                conn.register(poll)?;
                self.next_id += 1;
                self.connections.insert(token, conn);
                self.log_event(P2PEvent::ConnectEvent(ip.to_string(), port));
                debug!("Requesting handshake from new peer {}:{}",
                       ip.to_string(),
                       port);
                let self_peer = self.get_self_peer().clone();
                if let Some(ref mut conn) = self.connections.get_mut(&token) {
                    serialize_bytes(conn,
                                    &NetworkRequest::Handshake(self_peer,
                                                               self.networks
                                                                   .lock()
                                                                   .unwrap()
                                                                   .clone(),
                                                               vec![]).serialize())?;
                    conn.set_measured_handshake_sent();
                }
                Ok(())
            }
            Err(e) => {
                if connection_type == ConnectionType::Node
                   && !self.unreachable_nodes.insert(ip, port)
                {
                    error!("Can't insert unreachable peer!");
                }
                Err(ErrorKindWrapper::InternalIOError(e).into())
            }
        }
    }

    fn find_connection(&mut self, id: P2PNodeId) -> Option<&mut Connection> {
        let mut tok = Token(0);
        for (token, mut connection) in &self.connections {
            match connection.peer {
                Some(ref x) => {
                    if x.id() == id {
                        tok = *token;
                    } else {
                        break;
                    }
                }
                _ => {
                    break;
                }
            }
        }

        if tok == Token(0) {
            None
        } else {
            match self.connections.get_mut(&tok) {
                Some(x) => Some(x),
                None => {
                    error!("Couldn't get connections mutable");
                    None
                }
            }
        }
    }

    fn conn_event(&mut self,
                  poll: &mut Poll,
                  event: &Event,
                  mut buckets: &mut Buckets,
                  packet_queue: &mpsc::Sender<Arc<Box<NetworkMessage>>>)
                  -> ResultExtWrapper<()> {
        let token = event.token();
        if self.connections.contains_key(&token) {
            match self.connections.get_mut(&token) {
                Some(x) => x.ready(poll, event, &mut buckets, &packet_queue)
                            .map_err(|e| error!("Error while performing ready() check on connection '{}'", e))
                            .ok(),
                None => {
                    return Err(ErrorKindWrapper::LockingError("Couldn't get lock for connection".to_string()).into())
                }
            };

            if self.connections[&token].is_closed() {
                self.connections.remove(&token);
            }
        }
        Ok(())
    }

    fn cleanup_connections(&mut self, mut poll: &mut Poll) -> ResultExtWrapper<()> {
        if self.mode == P2PNodeMode::BootstrapperMode
           || self.mode == P2PNodeMode::BootstrapperPrivateMode
        {
            for conn in self.connections.values_mut() {
                if conn.last_seen + 300000 < common::get_current_stamp() {
                    conn.close(&mut poll).map_err(|e| error!("{}", e)).ok();
                }
            }
        } else {
            for conn in self.connections.values_mut() {
                if conn.last_seen + 1200000 < common::get_current_stamp()
                   && conn.connection_type == ConnectionType::Node
                {
                    conn.close(&mut poll).map_err(|e| error!("{}", e)).ok();
                }
                if conn.failed_pkts() >= MAX_FAILED_PACKETS_ALLOWED {
                    conn.close(&mut poll).map_err(|e| error!("{}", e)).ok();
                }
            }
            self.unreachable_nodes
                .cleanup(common::get_current_stamp() - MAX_UNREACHABLE_MARK_TIME);
        }

        let closed_ones: Vec<_> = self.connections
                                      .iter()
                                      .filter(|&(_, &ref v)| v.closing)
                                      .map(|(k, _)| k.clone())
                                      .collect();
        for closed in closed_ones {
            if let Some(ref prom) = &self.prometheus_exporter {
                if let Some(ref peer) = self.connections.get(&closed) {
                    if let Some(_) = peer.peer {
                        prom.lock()?.peers_dec().map_err(|e| error!("{}", e)).ok();
                    };
                };
            };

            self.connections.remove(&closed);
        }

        //Kill banned connections
        for peer in &self.banned_peers {
            for conn in self.connections.values_mut() {
                match conn.peer.clone() {
                    Some(ref p) => {
                        if p == peer {
                            conn.close(&mut poll).map_err(|e| error!("{}", e)).ok();
                        }
                    }
                    None => {}
                }
            }
        }
        Ok(())
    }

    fn liveness_check(&mut self) -> ResultExtWrapper<()> {
        for conn in self.connections.values_mut() {
            if conn.last_seen + 120000 < common::get_current_stamp()
               || conn.get_last_ping_sent() + 300000 < common::get_current_stamp()
            {
                let self_peer = conn.get_self_peer().clone();
                serialize_bytes(conn, &NetworkRequest::Ping(self_peer).serialize()).map_err(|e| error!("{}", e))
                                                                                   .ok();
                conn.set_measured_ping_sent();
                conn.set_last_ping_sent();
            }
        }
        Ok(())
    }
}

struct Connection {
    connection_type: ConnectionType,
    socket: TcpStream,
    token: Token,
    closing: bool,
    closed: bool,
    tls_server_session: Option<ServerSession>,
    tls_client_session: Option<ClientSession>,
    initiated_by_me: bool,
    own_id: P2PNodeId,
    peer: Option<P2PPeer>,
    currently_read: u32,
    pkt_validated: bool,
    pkt_valid: bool,
    failed_pkts: u32,
    peer_ip: IpAddr,
    peer_port: u16,
    expected_size: u32,
    pkt_buffer: Option<BytesMut>,
    last_seen: u64,
    self_peer: P2PPeer,
    messages_sent: u64,
    messages_received: u64,
    mode: P2PNodeMode,
    prometheus_exporter: Option<Arc<Mutex<PrometheusServer>>>,
    networks: Vec<u16>,
    event_log: Option<Sender<P2PEvent>>,
    own_networks: Arc<Mutex<Vec<u16>>>,
    seen_messages: SeenMessagesList,
    sent_ping: Option<u64>,
    sent_handshake: Option<u64>,
    last_ping_sent: u64,
    last_latency_measured: Option<u64>,
}

impl Connection {
    fn new(connection_type: ConnectionType,
           socket: TcpStream,
           token: Token,
           tls_server_session: Option<ServerSession>,
           tls_client_session: Option<ClientSession>,
           initiated_by_me: bool,
           own_id: P2PNodeId,
           self_peer: P2PPeer,
           peer_ip: IpAddr,
           peer_port: u16,
           mode: P2PNodeMode,
           prometheus_exporter: Option<Arc<Mutex<PrometheusServer>>>,
           event_log: Option<Sender<P2PEvent>>,
           own_networks: Arc<Mutex<Vec<u16>>>,
           seen_messages: SeenMessagesList)
           -> Connection {
        Connection { connection_type,
                     socket,
                     token,
                     closing: false,
                     closed: false,
                     tls_server_session,
                     tls_client_session,
                     initiated_by_me,
                     own_id,
                     peer: None,
                     currently_read: 0,
                     expected_size: 0,
                     pkt_buffer: None,
                     last_seen: common::get_current_stamp(),
                     self_peer: self_peer,
                     messages_received: 0,
                     messages_sent: 0,
                     peer_ip: peer_ip,
                     peer_port: peer_port,
                     mode: mode,
                     pkt_validated: false,
                     pkt_valid: false,
                     failed_pkts: 0,
                     prometheus_exporter: prometheus_exporter,
                     networks: vec![],
                     event_log: event_log,
                     own_networks: own_networks,
                     seen_messages: seen_messages,
                     sent_ping: None,
                     sent_handshake: None,
                     last_latency_measured: None,
                     last_ping_sent: common::get_current_stamp(), }
    }

    fn get_last_latency_measured(&self) -> Option<u64> {
        self.last_latency_measured.clone()
    }

    fn set_measured_ping(&mut self) {
        if self.sent_ping.is_some() {
            self.last_latency_measured =
                Some(common::get_current_stamp() - self.sent_ping.unwrap());
            self.sent_ping = None;
        }
    }

    fn set_measured_handshake(&mut self) {
        if self.sent_handshake.is_some() {
            self.last_latency_measured =
                Some(common::get_current_stamp() - self.sent_handshake.unwrap());
            self.sent_handshake = None;
        }
    }

    fn set_measured_ping_sent(&mut self) {
        if self.sent_ping.is_none() {
            self.sent_ping = Some(common::get_current_stamp())
        }
    }

    fn set_measured_handshake_sent(&mut self) {
        if self.sent_handshake.is_none() {
            self.sent_handshake = Some(common::get_current_stamp())
        }
    }

    fn log_event(&mut self, event: P2PEvent) {
        match self.event_log {
            Some(ref mut x) => {
                match x.send(event) {
                    Ok(_) => {}
                    Err(e) => error!("Couldn't send event {:?}", e),
                };
            }
            _ => {}
        }
    }

    pub fn get_last_ping_sent(&self) -> u64 {
        self.last_ping_sent
    }

    pub fn set_last_ping_sent(&mut self) {
        self.last_ping_sent = common::get_current_stamp();
    }

    pub fn ip(&self) -> IpAddr {
        self.peer_ip.clone()
    }

    pub fn port(&self) -> u16 {
        self.peer_port.clone()
    }

    fn update_last_seen(&mut self) {
        self.last_seen = common::get_current_stamp();
    }

    fn add_networks(&mut self, networks: &Vec<u16>) {
        for ele in networks {
            if !self.networks.contains(ele) {
                self.networks.push(*ele);
            }
        }
    }

    fn remove_network(&mut self, network: &u16) {
        self.networks.retain(|x| x != network);
    }

    fn append_buffer(&mut self, new_data: &[u8]) {
        if let Some(ref mut buf) = self.pkt_buffer {
            buf.reserve(new_data.len());
            buf.put_slice(new_data);
            self.currently_read += new_data.len() as u32;
        }
    }

    fn update_buffer_read_stats(&mut self, buf_len: u32) {
        self.currently_read += buf_len;
    }

    fn get_self_peer(&self) -> P2PPeer {
        self.self_peer.clone()
    }

    fn get_peer(&self) -> Option<P2PPeer> {
        self.peer.clone()
    }

    fn get_messages_received(&self) -> u64 {
        self.messages_received
    }

    fn get_messages_sent(&self) -> u64 {
        self.messages_sent
    }

    fn clear_buffer(&mut self) {
        if let Some(ref mut buf) = self.pkt_buffer {
            buf.clear();
        }
        self.currently_read = 0;
        self.expected_size = 0;
        self.pkt_buffer = None;
    }

    fn pkt_validated(&self) -> bool {
        self.pkt_validated
    }

    fn pkt_valid(&self) -> bool {
        self.pkt_valid
    }

    fn set_validated(&mut self) {
        self.pkt_validated = true;
    }

    fn set_valid(&mut self) {
        self.pkt_valid = true
    }

    fn failed_pkts_inc(&mut self) {
        self.failed_pkts += 1;
    }

    fn failed_pkts(&self) -> u32 {
        self.failed_pkts
    }

    fn setup_buffer(&mut self) {
        self.pkt_buffer = Some(BytesMut::with_capacity(1024));
        self.pkt_valid = false;
        self.pkt_validated = false;
    }

    fn register(&self, poll: &mut Poll) -> ResultExtWrapper<()> {
        match poll.register(&self.socket,
                            self.token,
                            self.event_set(),
                            PollOpt::level() | PollOpt::oneshot())
        {
            Ok(_) => Ok(()),
            Err(e) => Err(ErrorKindWrapper::InternalIOError(e).into()),
        }
    }

    fn reregister(&self, poll: &mut Poll) -> ResultExtWrapper<()> {
        match poll.reregister(&self.socket,
                              self.token,
                              self.event_set(),
                              PollOpt::level() | PollOpt::oneshot())
        {
            Ok(_) => Ok(()),
            Err(e) => Err(ErrorKindWrapper::InternalIOError(e).into()),
        }
    }

    fn event_set(&self) -> Ready {
        let mut _rd = false;
        let mut _wr = false;
        match self.initiated_by_me {
            true => {
                _rd = match self.tls_client_session {
                    Some(ref x) => x.wants_read(),
                    _ => false,
                };
                _wr = match self.tls_client_session {
                    Some(ref x) => x.wants_write(),
                    _ => false,
                };
            }
            false => {
                _rd = match self.tls_server_session {
                    Some(ref x) => x.wants_read(),
                    _ => false,
                };
                _wr = match self.tls_server_session {
                    Some(ref x) => x.wants_write(),
                    _ => false,
                };
            }
        };

        //Don't trust it .. It's broken and inconsistent
        _wr = true;

        if _rd && _wr {
            Ready::readable() | Ready::writable()
        } else if _wr {
            Ready::writable()
        } else {
            Ready::readable()
        }
    }

    fn is_closed(&self) -> bool {
        self.closed
    }

    fn close(&mut self, poll: &mut Poll) -> ResultExtWrapper<()> {
        self.closing = true;
        poll.deregister(&self.socket)?;
        self.socket.shutdown(Shutdown::Both)?;
        Ok(())
    }

    fn ready(&mut self,
             poll: &mut Poll,
             ev: &Event,
             buckets: &mut Buckets,
             packets_queue: &mpsc::Sender<Arc<Box<NetworkMessage>>>)
             -> ResultExtWrapper<()> {
        if ev.readiness().is_readable() {
            self.do_tls_read().map_err(|e| error!("{}", e)).ok();
            self.try_plain_read(poll, &packets_queue, buckets);
        }

        if ev.readiness().is_writable() {
            self.do_tls_write().map_err(|e| error!("{}", e)).ok();
        }

        if self.closing {
            self.close(poll).map_err(|e| error!("{}", e)).ok();
        }

        match self.initiated_by_me {
            true => {
                if self.closing && !match self.tls_client_session {
                    Some(ref x) => x.wants_read(),
                    _ => false,
                } {
                    let _ = self.socket.shutdown(Shutdown::Both);
                    self.closed = true;
                } else {
                    self.reregister(poll).map_err(|e| error!("{}", e)).ok();
                }
            }
            false => {
                if self.closing && !match self.tls_server_session {
                    Some(ref x) => x.wants_read(),
                    _ => false,
                } {
                    let _ = self.socket.shutdown(Shutdown::Both);
                    self.closed = true;
                } else {
                    self.reregister(poll).map_err(|e| error!("{}", e)).ok();
                }
            }
        };
        Ok(())
    }

    fn do_tls_read(&mut self) -> ResultExtWrapper<(usize)> {
        let rc = match self.initiated_by_me {
            true => {
                match self.tls_client_session {
                    Some(ref mut x) => x.read_tls(&mut self.socket),
                    None => Err(Error::new(ErrorKind::Other, "Couldn't find session!")),
                }
            }
            false => {
                match self.tls_server_session {
                    Some(ref mut x) => x.read_tls(&mut self.socket),
                    None => Err(Error::new(ErrorKind::Other, "Couldn't find session!")),
                }
            }
        };

        if rc.is_err() {
            let err = &rc.unwrap_err();

            if let io::ErrorKind::WouldBlock = err.kind() {
                return Err(ErrorKindWrapper::NetworkError(format!("{}:{}/blocked {:?}",
                                                                  self.ip().to_string(),
                                                                  self.port(),
                                                                  err)).into());
            }

            //error!("read error {}:{}/{:?}", self.ip().to_string(), self.port(), err);
            self.closing = true;
            return Err(ErrorKindWrapper::NetworkError(format!("{}:{}/read error {:?}",
                                                              self.ip().to_string(),
                                                              self.port(),
                                                              err)).into());
        }

        if let Ok(size) = rc {
            if size == 0 {
                debug!("eof");
                self.closing = true;
                return Err(ErrorKindWrapper::NetworkError("eof".to_string()).into());
            }
        }

        // Process newly-received TLS messages.
        let processed = match self.initiated_by_me {
            true => {
                match self.tls_client_session {
                    Some(ref mut x) => x.process_new_packets(),
                    None => Err(TLSError::General(String::from("Couldn't find session!"))),
                }
            }
            false => {
                match self.tls_server_session {
                    Some(ref mut x) => x.process_new_packets(),
                    None => Err(TLSError::General(String::from("Couldn't find session!"))),
                }
            }
        };

        if processed.is_err() {
            error!("cannot process packet: {:?}", processed);
            self.closing = true;
            return Err(ErrorKindWrapper::NetworkError(format!("Can't process packet {:?}",
                                                              processed)).into());
        }

        rc.chain_err(|| ErrorKindWrapper::NetworkError("couldn't read from TLS socket".to_string()))
    }

    fn try_plain_read(&mut self,
                      poll: &mut Poll,
                      packets_queue: &mpsc::Sender<Arc<Box<NetworkMessage>>>,
                      mut buckets: &mut Buckets) {
        // Read and process all available plaintext.
        let mut buf = Vec::new();

        let rc = match self.initiated_by_me {
            true => {
                match self.tls_client_session {
                    Some(ref mut x) => x.read_to_end(&mut buf),
                    None => Err(Error::new(ErrorKind::Other, "Couldn't find session!")),
                }
            }
            false => {
                match self.tls_server_session {
                    Some(ref mut x) => x.read_to_end(&mut buf),
                    None => Err(Error::new(ErrorKind::Other, "Couldn't find session!")),
                }
            }
        };

        if rc.is_err() {
            error!("plaintext read failed: {:?}", rc);
            self.closing = true;
            return;
        }

        if !buf.is_empty() {
            trace!("plaintext read {:?}", buf.len());
            self.incoming_plaintext(poll, &packets_queue, &mut buckets, &buf);
        }
    }

    fn write_all(&mut self, bytes: &[u8]) -> Result<(), Error> {
        match self.initiated_by_me {
            true => {
                match self.tls_client_session {
                    Some(ref mut x) => {
                        self.messages_sent += 1;
                        x.write_all(bytes)
                    }
                    None => Err(Error::new(ErrorKind::Other, "Couldn't find session!")),
                }
            }
            false => {
                match self.tls_server_session {
                    Some(ref mut x) => {
                        self.messages_sent += 1;
                        x.write_all(bytes)
                    }
                    None => Err(Error::new(ErrorKind::Other, "Couldn't find session!")),
                }
            }
        }
    }

    fn process_complete_packet(&mut self,
                               buckets: &mut Buckets,
                               buf: &[u8],
                               packet_queue: &mpsc::Sender<Arc<Box<NetworkMessage>>>) {
        let outer = Arc::new(box NetworkMessage::deserialize(self.get_peer(), self.ip(), &buf));
        let self_peer = self.get_self_peer().clone();
        self.messages_received += 1;
        TOTAL_MESSAGES_RECEIVED_COUNTER.inc();
        if let Some(ref prom) = &self.prometheus_exporter {
            prom.lock()
                .unwrap()
                .pkt_received_inc()
                .map_err(|e| error!("{}", e))
                .ok();
        };
        match *outer.clone() {
            box NetworkMessage::NetworkRequest(ref x, _, _) => {
                match x {
                    NetworkRequest::Ping(_) => {
                        //Respond with pong
                        debug!("Got request for ping");
                        if self.mode != P2PNodeMode::BootstrapperMode
                           && self.mode != P2PNodeMode::BootstrapperPrivateMode
                        {
                            self.update_last_seen();
                        }
                        TOTAL_MESSAGES_SENT_COUNTER.inc();
                        if let Some(ref prom) = &self.prometheus_exporter {
                            prom.lock()
                                .unwrap()
                                .pkt_sent_inc()
                                .map_err(|e| error!("{}", e))
                                .ok();
                        };
                        serialize_bytes(self, &NetworkResponse::Pong(self_peer).serialize()).unwrap();
                    }
                    NetworkRequest::FindNode(_, x) => {
                        //Return list of nodes
                        debug!("Got request for FindNode");
                        if self.mode != P2PNodeMode::BootstrapperMode
                           && self.mode != P2PNodeMode::BootstrapperPrivateMode
                        {
                            self.update_last_seen();
                        }
                        let nodes = buckets.closest_nodes(x);
                        serialize_bytes(self, &NetworkResponse::FindNode(self_peer, nodes).serialize()).unwrap();
                    }
                    NetworkRequest::BanNode(_, _) => {
                        debug!("Got request for BanNode");
                        if self.mode != P2PNodeMode::BootstrapperMode
                           && self.mode != P2PNodeMode::BootstrapperPrivateMode
                        {
                            self.update_last_seen();
                        }
                        match packet_queue.send(outer.clone()) {
                            Ok(_) => {}
                            Err(e) => error!("Couldn't send to packet_queue, {:?}", e),
                        };
                    }
                    NetworkRequest::UnbanNode(_, _) => {
                        debug!("Got request for UnbanNode");
                        if self.mode != P2PNodeMode::BootstrapperMode
                           && self.mode != P2PNodeMode::BootstrapperPrivateMode
                        {
                            self.update_last_seen();
                        }
                        match packet_queue.send(outer.clone()) {
                            Ok(_) => {}
                            Err(e) => error!("Couldn't send to packet_queue, {:?}", e),
                        };
                    }
                    NetworkRequest::Handshake(sender, nets, _) => {
                        debug!("Got request for Handshake");
                        self.update_last_seen();
                        let my_nets = self.own_networks.lock().unwrap().clone();
                        serialize_bytes(self,
                                        &NetworkResponse::Handshake(self_peer.clone(),
                                                                    my_nets,
                                                                    vec![]).serialize()).unwrap();
                        serialize_bytes(self,
                                        &NetworkRequest::Ping(self_peer.clone()).serialize()).unwrap();
                        TOTAL_MESSAGES_SENT_COUNTER.add(2);
                        self.set_measured_ping_sent();
                        self.add_networks(nets);
                        self.peer = Some(sender.clone());
                        if self.mode == P2PNodeMode::BootstrapperPrivateMode
                           || self.mode == P2PNodeMode::NormalPrivateMode
                        {
                            buckets.insert_into_bucket(sender, &self.own_id, nets.clone());
                        } else if sender.ip().is_global()
                                  && !sender.ip().is_multicast()
                                  && !sender.ip().is_documentation()
                        {
                            buckets.insert_into_bucket(sender, &self.own_id, nets.clone());
                        }
                        if let Some(ref prom) = &self.prometheus_exporter {
                            let mut _prom = prom.lock().unwrap();
                            _prom.peers_inc().map_err(|e| error!("{}", e)).ok();
                            _prom.pkt_sent_inc_by(2).map_err(|e| error!("{}", e)).ok();
                        };
                        if self.mode == P2PNodeMode::BootstrapperMode
                           || self.mode == P2PNodeMode::BootstrapperPrivateMode
                        {
                            debug!("Running in bootstrapper mode, so instantly sending peers {} random peers",
                                   BOOTSTRAP_PEER_COUNT);
                            serialize_bytes(self, &NetworkResponse::PeerList(self_peer, buckets.get_random_nodes(&sender, BOOTSTRAP_PEER_COUNT, &nets)).serialize()).unwrap();
                            if let Some(ref prom) = &self.prometheus_exporter {
                                prom.lock()
                                    .unwrap()
                                    .pkt_sent_inc()
                                    .map_err(|e| error!("{}", e))
                                    .ok();
                            };
                            TOTAL_MESSAGES_SENT_COUNTER.inc();
                        }
                        match packet_queue.send(outer.clone()) {
                            Ok(_) => {}
                            Err(e) => error!("Couldn't send to packet_queue, {:?}", e),
                        };
                    }
                    NetworkRequest::GetPeers(ref sender, ref networks) => {
                        debug!("Got request for GetPeers");
                        if self.mode != P2PNodeMode::BootstrapperMode
                           && self.mode != P2PNodeMode::BootstrapperPrivateMode
                        {
                            self.update_last_seen();
                        }
                        let nodes = buckets.get_all_nodes(Some(&sender), networks);
                        TOTAL_MESSAGES_SENT_COUNTER.inc();
                        if let Some(ref prom) = &self.prometheus_exporter {
                            prom.lock()
                                .unwrap()
                                .pkt_sent_inc()
                                .map_err(|e| error!("{}", e))
                                .ok();
                        };
                        serialize_bytes(self, &NetworkResponse::PeerList(self_peer, nodes).serialize()).unwrap();
                    }
                    NetworkRequest::JoinNetwork(sender, network) => {
                        self.add_networks(&vec![*network]);
                        match self.get_peer() {
                            Some(peer) => {
                                buckets.update_network_ids(&peer, self.networks.clone());
                            }
                            _ => {}
                        }
                        self.log_event(P2PEvent::JoinedNetwork(sender.clone(), *network));
                        if self.mode != P2PNodeMode::BootstrapperMode
                           && self.mode != P2PNodeMode::BootstrapperPrivateMode
                        {
                            self.update_last_seen();
                        }
                    }
                    NetworkRequest::LeaveNetwork(sender, ref network) => {
                        self.remove_network(network);
                        match self.get_peer() {
                            Some(peer) => {
                                buckets.update_network_ids(&peer, self.networks.clone());
                            }
                            _ => {}
                        }
                        self.log_event(P2PEvent::LeftNetwork(sender.clone(), *network));
                        if self.mode != P2PNodeMode::BootstrapperMode
                           && self.mode != P2PNodeMode::BootstrapperPrivateMode
                        {
                            self.update_last_seen();
                        }
                    }
                }
            }
            box NetworkMessage::NetworkResponse(ref x, _, _) => {
                match x {
                    NetworkResponse::FindNode(_, peers) => {
                        debug!("Got response to FindNode");
                        if self.mode != P2PNodeMode::BootstrapperMode
                           && self.mode != P2PNodeMode::BootstrapperPrivateMode
                        {
                            self.update_last_seen();
                        }
                        //Process the received node list
                        for peer in peers.iter() {
                            buckets.insert_into_bucket(peer, &self.own_id, vec![]);
                        }
                    }
                    NetworkResponse::Pong(_) => {
                        debug!("Got response for ping");
                        self.set_measured_ping();
                        if self.mode != P2PNodeMode::BootstrapperMode
                           && self.mode != P2PNodeMode::BootstrapperPrivateMode
                        {
                            self.update_last_seen();
                        }
                    }
                    NetworkResponse::PeerList(_, peers) => {
                        debug!("Got response to PeerList");
                        if self.mode != P2PNodeMode::BootstrapperMode
                           && self.mode != P2PNodeMode::BootstrapperPrivateMode
                        {
                            self.update_last_seen();
                        }
                        //Process the received node list
                        for peer in peers.iter() {
                            buckets.insert_into_bucket(peer, &self.own_id, vec![]);
                        }
                        match packet_queue.send(outer.clone()) {
                            Ok(_) => {}
                            Err(e) => error!("Couldn't send to packet_queue, {:?}", e),
                        };
                    }
                    NetworkResponse::Handshake(peer, nets, _) => {
                        debug!("Got response to Handshake");
                        self.set_measured_handshake();
                        self.update_last_seen();
                        self.add_networks(nets);
                        self.peer = Some(peer.clone());
                        let bucket_sender = P2PPeer::from(self.connection_type,
                                                          peer.id().clone(),
                                                          peer.ip().clone(),
                                                          peer.port());
                        buckets.insert_into_bucket(&bucket_sender, &self.own_id, nets.clone());
                        if let Some(ref prom) = &self.prometheus_exporter {
                            prom.lock()
                                .unwrap()
                                .peers_inc()
                                .map_err(|e| error!("{}", e))
                                .ok();
                        };
                        for ele in nets {
                            self.log_event(P2PEvent::JoinedNetwork(peer.clone(), *ele));
                        }
                    }
                }
            }
            box NetworkMessage::NetworkPacket(ref x, _, _) => {
                match x {
                    NetworkPacket::DirectMessage(ref sender,
                                                 ref msgid,
                                                 _,
                                                 ref network_id,
                                                 ref msg) => {
                        if !self.seen_messages.contains(msgid) {
                            self.seen_messages.append(&msgid);
                            if self.own_networks.lock().unwrap().contains(network_id) {
                                if self.mode != P2PNodeMode::BootstrapperMode
                                   && self.mode != P2PNodeMode::BootstrapperPrivateMode
                                {
                                    self.update_last_seen();
                                }
                                debug!("Received direct message of size {}", msg.len());
                                match packet_queue.send(outer.clone()) {
                                    Ok(_) => {
                                        self.seen_messages.append(&msgid);
                                    }
                                    Err(e) => error!("Couldn't send to packet_queue, {:?}", e),
                                };
                            } else {
                                if let Some(ref prom) = &self.prometheus_exporter {
                                    prom.lock()
                                        .unwrap()
                                        .invalid_network_pkts_received_inc()
                                        .map_err(|e| error!("{}", e))
                                        .ok();
                                };
                            }
                        } else {
                            error!("Dropping duplicate packet {}/{}/{}",
                                   sender.id().to_string(),
                                   network_id,
                                   msgid);
                        }
                    }
                    NetworkPacket::BroadcastedMessage(ref sender,
                                                      ref msgid,
                                                      ref network_id,
                                                      ref msg) => {
                        if !self.seen_messages.contains(msgid) {
                            if self.own_networks.lock().unwrap().contains(network_id) {
                                if self.mode != P2PNodeMode::BootstrapperMode
                                   && self.mode != P2PNodeMode::BootstrapperPrivateMode
                                {
                                    self.update_last_seen();
                                }
                                debug!("Received broadcast message of size {}", msg.len());
                                match packet_queue.send(outer.clone()) {
                                    Ok(_) => {
                                        self.seen_messages.append(&msgid);
                                    }
                                    Err(e) => error!("Couldn't send to packet_queue, {:?}", e),
                                };
                            } else {
                                if let Some(ref prom) = &self.prometheus_exporter {
                                    prom.lock()
                                        .unwrap()
                                        .invalid_network_pkts_received_inc()
                                        .map_err(|e| error!("{}", e))
                                        .ok();
                                };
                            }
                        } else {
                            error!("Dropping duplicate packet {}/{}/{}",
                                   sender.id().to_string(),
                                   network_id,
                                   msgid);
                        }
                    }
                }
            }
            box NetworkMessage::UnknownMessage => {
                self.failed_pkts_inc();
                debug!("Unknown message received!");
                if self.mode != P2PNodeMode::BootstrapperMode
                   && self.mode != P2PNodeMode::BootstrapperPrivateMode
                {
                    self.update_last_seen();
                }
                trace!("Contents were: {:?}",
                       String::from_utf8(buf.to_vec()).unwrap());
                if let Some(ref prom) = &self.prometheus_exporter {
                    prom.lock()
                        .unwrap()
                        .unknown_pkts_received_inc()
                        .map_err(|e| error!("{}", e))
                        .ok();
                };
            }
            box NetworkMessage::InvalidMessage => {
                self.failed_pkts_inc();
                debug!("Invalid message received!");
                if self.mode != P2PNodeMode::BootstrapperMode
                   && self.mode != P2PNodeMode::BootstrapperPrivateMode
                {
                    self.update_last_seen();
                }
                trace!("Contents were: {:?}",
                       String::from_utf8(buf.to_vec()).unwrap());
                if let Some(ref prom) = &self.prometheus_exporter {
                    prom.lock()
                        .unwrap()
                        .invalid_pkts_received_inc()
                        .map_err(|e| error!("{}", e))
                        .ok();
                };
            }
        }
    }

    fn validate_packet(&mut self, poll: &mut Poll) {
        if !self.pkt_validated() {
            let buff = if let Some(ref bytebuf) = self.pkt_buffer {
                if bytebuf.len() >= 132 {
                    Some(bytebuf[24..28].to_vec())
                } else {
                    None
                }
            } else {
                None
            };
            match buff {
                Some(ref bufdata) => {
                    if self.mode == P2PNodeMode::BootstrapperMode
                       || self.mode == P2PNodeMode::BootstrapperPrivateMode
                    {
                        let msg_num = String::from_utf8(bufdata.to_vec()).unwrap();
                        if msg_num == common::PROTOCOL_MESSAGE_TYPE_DIRECT_MESSAGE
                           || msg_num == common::PROTOCOL_MESSAGE_TYPE_BROADCASTED_MESSAGE
                        {
                            info!("Received network packet message, not wanted - disconnecting peer");
                            &self.clear_buffer();
                            &self.close(poll);
                        }
                    } else {
                        self.set_valid();
                        self.set_validated();
                    }
                }
                _ => {}
            }
        }
    }

    fn incoming_plaintext(&mut self,
                          poll: &mut Poll,
                          packets_queue: &mpsc::Sender<Arc<Box<NetworkMessage>>>,
                          buckets: &mut Buckets,
                          buf: &[u8]) {
        trace!("Received plaintext");
        self.validate_packet(poll);
        if self.expected_size > 0 && self.currently_read == self.expected_size {
            trace!("Completed packet with {} size", self.currently_read);
            if self.pkt_valid() || !self.pkt_validated() {
                let mut buffered = Vec::new();
                if let Some(ref mut buf) = self.pkt_buffer {
                    buffered = buf[..].to_vec();
                }
                self.process_complete_packet(buckets, &buffered, &packets_queue);
            }
            self.clear_buffer();
            self.incoming_plaintext(poll, packets_queue, buckets, buf);
        } else if self.expected_size > 0
                  && buf.len() <= (self.expected_size as usize - self.currently_read as usize)
        {
            if self.pkt_valid() || !self.pkt_validated() {
                self.append_buffer(&buf);
            } else {
                self.update_buffer_read_stats(buf.len() as u32);
            }
            if self.expected_size == self.currently_read {
                trace!("Completed packet with {} size", self.currently_read);
                if self.pkt_valid() || !self.pkt_validated() {
                    let mut buffered = Vec::new();
                    if let Some(ref mut buf) = self.pkt_buffer {
                        buffered = buf[..].to_vec();
                    }
                    self.process_complete_packet(buckets, &buffered, &packets_queue);
                }
                self.clear_buffer();
            }
        } else if self.expected_size > 0
                  && buf.len() > (self.expected_size as usize - self.currently_read as usize)
        {
            trace!("Got more buffer than needed");
            let to_take = self.expected_size - self.currently_read;
            if self.pkt_valid() || !self.pkt_validated() {
                self.append_buffer(&buf[..to_take as usize]);
                let mut buffered = Vec::new();
                if let Some(ref mut buf) = self.pkt_buffer {
                    buffered = buf[..].to_vec();
                }
                self.process_complete_packet(buckets, &buffered, &packets_queue);
            }
            self.clear_buffer();
            self.incoming_plaintext(poll, &packets_queue, buckets, &buf[to_take as usize..]);
        } else if buf.len() >= 4 {
            trace!("Trying to read size");
            let _buf = &buf[..4].to_vec();
            let mut size_bytes = Cursor::new(_buf);
            self.expected_size = size_bytes.read_u32::<NetworkEndian>().unwrap();
            if self.expected_size > 268_435_456 {
                error!("Packet can't be bigger than 256MB");
                self.expected_size = 0;
                self.incoming_plaintext(poll, &packets_queue, buckets, &buf[4..]);
            } else {
                self.setup_buffer();
                if buf.len() > 4 {
                    trace!("Got enough to read it...");
                    self.incoming_plaintext(poll, &packets_queue, buckets, &buf[4..]);
                }
            }
        }
    }

    #[cfg(not(target_os = "windows"))]
    fn do_tls_write(&mut self) -> ResultExtWrapper<(usize)> {
        let rc = match self.initiated_by_me {
            true => {
                match self.tls_client_session {
                    Some(ref mut x) => x.writev_tls(&mut WriteVAdapter::new(&mut self.socket)),
                    None => Err(Error::new(ErrorKind::Other, "Couldn't find session!")),
                }
            }
            false => {
                match self.tls_server_session {
                    Some(ref mut x) => x.writev_tls(&mut WriteVAdapter::new(&mut self.socket)),
                    None => Err(Error::new(ErrorKind::Other, "Couldn't find session!")),
                }
            }
        };

        if rc.is_err() {
            error!("write failed {:?}", rc);
            self.closing = true;
        }
        rc.chain_err(|| ErrorKindWrapper::NetworkError("couldn't write TLS to socket".to_string()))
    }

    #[cfg(target_os = "windows")]
    fn do_tls_write(&mut self) -> ResultExtWrapper<(usize)> {
        let rc = match self.initiated_by_me {
            true => {
                match self.tls_client_session {
                    Some(ref mut x) => x.write_tls(&mut self.socket),
                    None => Err(Error::new(ErrorKind::Other, "Couldn't find session!")),
                }
            }
            false => {
                match self.tls_server_session {
                    Some(ref mut x) => x.write_tls(&mut self.socket),
                    None => Err(Error::new(ErrorKind::Other, "Couldn't find session!")),
                }
            }
        };

        if rc.is_err() {
            error!("write failed {:?}", rc);
            self.closing = true;
        }
        rc.chain_err(|| ErrorKindWrapper::NetworkError("couldn't write TLS to socket".to_string()))
    }
}

//Disable certificate verification
pub struct NoCertificateVerification {}

impl ServerCertVerifier for NoCertificateVerification {
    fn verify_server_cert(&self,
                          _roots: &RootCertStore,
                          _presented_certs: &[Certificate],
                          _dns_name: DNSNameRef,
                          _ocsp: &[u8])
                          -> Result<ServerCertVerified, TLSError> {
        Ok(ServerCertVerified::assertion())
    }
}

#[derive(Clone)]
pub struct P2PNode {
    tls_server: Arc<Mutex<TlsServer>>,
    poll: Arc<Mutex<Poll>>,
    id: P2PNodeId,
    buckets: Arc<Mutex<Buckets>>,
    send_queue: Arc<Mutex<VecDeque<Arc<Box<NetworkMessage>>>>>,
    ip: IpAddr,
    port: u16,
    incoming_pkts: mpsc::Sender<Arc<Box<NetworkMessage>>>,
    event_log: Option<mpsc::Sender<P2PEvent>>,
    start_time: Timespec,
    prometheus_exporter: Option<Arc<Mutex<PrometheusServer>>>,
    mode: P2PNodeMode,
    external_ip: IpAddr,
    external_port: u16,
    seen_messages: SeenMessagesList,
}

fn serialize_bytes(conn: &mut Connection, pkt: &[u8]) -> ResultExtWrapper<()> {
    trace!("Serializing data to connection {} bytes", pkt.len());
    let mut size_vec = Vec::with_capacity(4);
    match size_vec.write_u32::<NetworkEndian>(pkt.len() as u32) {
        Ok(()) => {}
        Err(e) => {
            if let Some(inner_err) = e.into_inner() {
                info!("{}", inner_err);
            }
        }
    };
    match conn.write_all(&size_vec[..]) {
        Ok(()) => {}
        Err(e) => {
            if let Some(inner_err) = e.into_inner() {
                info!("{}", inner_err);
            }
        }
    };
    match conn.write_all(pkt) {
        Ok(()) => {}
        Err(e) => {
            if let Some(inner_err) = e.into_inner() {
                info!("{}", inner_err);
            }
        }
    };
    Ok(())
}

impl P2PNode {
    pub fn new(supplied_id: Option<String>,
               listen_address: Option<String>,
               listen_port: u16,
               external_ip: Option<String>,
               external_port: Option<u16>,
               pkt_queue: mpsc::Sender<Arc<Box<NetworkMessage>>>,
               event_log: Option<mpsc::Sender<P2PEvent>>,
               mode: P2PNodeMode,
               prometheus_exporter: Option<Arc<Mutex<PrometheusServer>>>,
               networks: Vec<u16>)
               -> P2PNode {
        let addr = if let Some(ref addy) = listen_address {
            format!("{}:{}", addy, listen_port).parse().unwrap()
        } else {
            format!("0.0.0.0:{}", listen_port).parse().unwrap()
        };

        trace!("Creating new P2PNode");

        //Retrieve IP address octets, format to IP and SHA256 hash it
        let ip = if let Some(ref addy) = listen_address {
            match IpAddr::from_str(addy) {
                Ok(x) => x,
                _ => P2PNode::get_ip().unwrap(),
            }
        } else {
            P2PNode::get_ip().unwrap()
        };
        let ip_port = format!("{}:{}", ip.to_string(), listen_port);
        debug!("Listening on {:?}", ip_port);

        let id = match supplied_id {
            Some(x) => {
                if x.chars().count() != 64 {
                    panic!("Incorrect ID specified.. Should be a sha256 value or 64 characters long!");
                }
                x
            }
            _ => {
                let instant = time::get_time();
                utils::to_hex_string(&utils::sha256(&format!("{}.{}", instant.sec, instant.nsec)))
            }
        };

        let _id = P2PNodeId::from_string(&id).unwrap();

        let poll = match Poll::new() {
            Ok(x) => x,
            _ => panic!("Couldn't create poll"),
        };

        let server = match TcpListener::bind(&addr) {
            Ok(x) => x,
            _ => panic!("Couldn't listen on port!"),
        };

        match poll.register(&server, SERVER, Ready::readable(), PollOpt::edge()) {
            Ok(_x) => (),
            _ => panic!("Couldn't register server with poll!"),
        };

        //Generate key pair and cert
        let (cert, private_key) = match utils::generate_certificate(id) {
            Ok(x) => {
                match x.x509.to_der() {
                    Ok(der) => {
                        match x.private_key.private_key_to_der() {
                            Ok(private_part) => (Certificate(der), PrivateKey(private_part)),
                            Err(e) => {
                                panic!("Couldn't convert certificate to DER! {:?}", e);
                            }
                        }
                    }
                    Err(e) => {
                        panic!("Couldn't convert certificate to DER! {:?}", e);
                    }
                }
            }
            Err(e) => {
                panic!("Couldn't create certificate! {:?}", e);
            }
        };

        let mut server_conf = ServerConfig::new(NoClientAuth::new());
        server_conf.set_single_cert(vec![cert], private_key)
                   .map_err(|e| error!("{}", e))
                   .ok();

        let mut client_conf = ClientConfig::new();
        client_conf.dangerous()
                   .set_certificate_verifier(Arc::new(NoCertificateVerification {}));

        let own_peer_ip = if let Some(ref own_ip) = external_ip {
            match IpAddr::from_str(own_ip) {
                Ok(ip) => ip,
                _ => ip,
            }
        } else {
            ip
        };

        let own_peer_port = if let Some(own_port) = external_port {
            own_port
        } else {
            listen_port
        };

        let self_peer = P2PPeer::from(ConnectionType::Node,
                                      _id.clone(),
                                      own_peer_ip,
                                      own_peer_port);

        let seen_messages = SeenMessagesList::new();

        let tlsserv = TlsServer::new(server,
                                     Arc::new(server_conf),
                                     Arc::new(client_conf),
                                     _id.clone(),
                                     event_log.clone(),
                                     self_peer,
                                     mode,
                                     prometheus_exporter.clone(),
                                     networks,
                                     seen_messages.clone());

        P2PNode { tls_server: Arc::new(Mutex::new(tlsserv)),
                  poll: Arc::new(Mutex::new(poll)),
                  id: _id,
                  buckets: Arc::new(Mutex::new(Buckets::new())),
                  send_queue: Arc::new(Mutex::new(VecDeque::new())),
                  ip: ip,
                  port: listen_port,
                  incoming_pkts: pkt_queue,
                  event_log,
                  start_time: time::get_time(),
                  prometheus_exporter: prometheus_exporter,
                  external_ip: own_peer_ip,
                  external_port: own_peer_port,
                  mode: mode,
                  seen_messages: seen_messages, }
    }

    pub fn spawn(&mut self) -> thread::JoinHandle<()> {
        let mut self_clone = self.clone();
        thread::spawn(move || {
                          let mut events = Events::with_capacity(1024);
                          loop {
                              self_clone.process(&mut events)
                                        .map_err(|e| error!("{}", e))
                                        .ok();
                          }
                      })
    }

    pub fn get_version(&self) -> String {
        ::VERSION.to_string()
    }

    pub fn connect(&mut self,
                   connection_type: ConnectionType,
                   ip: IpAddr,
                   port: u16,
                   peer_id: Option<P2PNodeId>)
                   -> ResultExtWrapper<()> {
        self.log_event(P2PEvent::InitiatingConnection(ip.clone(), port));
        match self.tls_server.lock() {
            Ok(mut x) => {
                match self.poll.lock() {
                    Ok(mut y) => {
                        x.connect(connection_type,
                                  &mut y,
                                  ip,
                                  port,
                                  peer_id,
                                  &self.get_self_peer())
                    }
                    Err(e) => Err(ErrorWrapper::from(e).into()),
                }
            }
            Err(e) => Err(ErrorWrapper::from(e).into()),
        }
    }

    pub fn get_own_id(&self) -> P2PNodeId {
        self.id.clone()
    }

    pub fn get_listening_ip(&self) -> IpAddr {
        self.ip.clone()
    }

    pub fn get_listening_port(&self) -> u16 {
        self.port
    }

    pub fn get_nodes(&self, nids: &Vec<u16>) -> Result<Vec<PeerStatistic>, Error> {
        match self.tls_server.lock() {
            Ok(x) => Ok(x.get_peer_stats(nids)),
            Err(_e) => Err(Error::new(ErrorKind::Other, "Couldn't get lock on buckets!")),
        }
    }

    fn log_event(&mut self, event: P2PEvent) {
        match self.event_log {
            Some(ref mut x) => {
                match x.send(event) {
                    Ok(_) => {}
                    Err(e) => error!("Couldn't send event {:?}", e),
                };
            }
            _ => {}
        }
    }

    pub fn get_uptime(&self) -> i64 {
        (time::get_time() - self.start_time).num_milliseconds()
    }

    pub fn process_messages(&mut self) -> ResultExtWrapper<()> {
        {
            let mut send_q = self.send_queue.lock()?;
            if send_q.len() == 0 {
                return Ok(());
            }
            let mut resend_queue: VecDeque<Arc<Box<NetworkMessage>>> = VecDeque::new();
            loop {
                trace!("Processing messages!");
                let outer_pkt = send_q.pop_front();
                match outer_pkt.clone() {
                    Some(ref x) => {
                        if let Some(ref prom) = &self.prometheus_exporter {
                            match prom.lock() {
                                Ok(ref mut lock) => {
                                    lock.queue_size_dec().map_err(|e| error!("{}", e)).ok();
                                }
                                _ => error!("Couldn't lock prometheus instance"),
                            }
                        };
                        trace!("Got message to process!");
                        match *x.clone() {
                            box NetworkMessage::NetworkPacket(ref inner_pkt @ NetworkPacket::DirectMessage(_,
                                                                                          _,
                                                                                           _,
                                                                                           _,
                                                                                           _),
                                                              _,
                                                              _) => {
                                if let NetworkPacket::DirectMessage(_, msgid, receiver, network_id,  _) = inner_pkt {
                                    match self.tls_server.lock()?.find_connection(receiver.clone()) {
                                        Some(ref mut conn) => {
                                            if conn.own_networks.lock().unwrap().contains(network_id) {
                                                if let Some(ref peer) = conn.peer.clone() {
                                                    match serialize_bytes(conn, &inner_pkt.serialize()) {
                                                        Ok(_) => {
                                                            self.seen_messages.append(&msgid);
                                                            TOTAL_MESSAGES_SENT_COUNTER.inc();
                                                            self.pks_sent_inc()?;
                                                            debug!("Sent message");
                                                        }
                                                        Err(e) => {
                                                            error!("Could not send to peer {} due to {}",
                                                                peer.id().to_string(),
                                                                e);
                                                            resend_queue.push_back(outer_pkt.unwrap().clone());
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        _ => {
                                            resend_queue.push_back(outer_pkt.unwrap().clone());
                                            trace!("Couldn't find connection, requeuing message!");
                                        }
                                    }
                                }
                            }
                            box NetworkMessage::NetworkPacket(ref inner_pkt @ NetworkPacket::BroadcastedMessage(_,
                                                                                                _,
                                                                                                _,
                                                                                                _),
                                                              _,
                                                              _) => {
                                for (_, mut conn) in &mut self.tls_server.lock()?.connections {
                                    if let NetworkPacket::BroadcastedMessage(_, ref msgid, ref network_id, _ ) = inner_pkt {
                                        if conn.own_networks.lock().unwrap().contains(network_id) {
                                            if let Some(ref peer) = conn.peer.clone() {
                                                match serialize_bytes(conn, &inner_pkt.serialize()) {
                                                    Ok(_) => {
                                                        self.seen_messages.append(msgid);
                                                        self.pks_sent_inc()?;
                                                        TOTAL_MESSAGES_SENT_COUNTER.inc();
                                                    }
                                                    Err(e) => {
                                                        error!("Could not send to peer {} due to {}", peer.id().to_string(), e);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            box NetworkMessage::NetworkRequest(ref inner_pkt @ NetworkRequest::BanNode(_, _), _, _) => {
                                for (_, mut conn) in &mut self.tls_server.lock()?.connections {
                                    if let Some(ref peer) = conn.peer.clone() {
                                        match serialize_bytes(conn, &inner_pkt.serialize()) {
                                            Ok(_) => {
                                                self.pks_sent_inc()?;
                                                TOTAL_MESSAGES_SENT_COUNTER.inc();
                                            }
                                            Err(e) => {
                                                error!("Could not send to peer {} due to {}", peer.id().to_string(), e);
                                            }
                                        }
                                    }
                                }
                            }
                            box NetworkMessage::NetworkRequest(ref inner_pkt @ NetworkRequest::JoinNetwork(_, _), _, _) => {
                                {
                                    let mut tls_server = self.tls_server.lock()?;
                                    for (_, mut conn) in &mut tls_server.connections {
                                        if let Some(ref peer) = conn.peer.clone() {
                                            match serialize_bytes(conn, &inner_pkt.serialize()) {
                                                Ok(_) => {
                                                    self.pks_sent_inc()?;
                                                    TOTAL_MESSAGES_SENT_COUNTER.inc();
                                                }
                                                Err(e) => {
                                                    error!("Could not send to peer {} due to {}", peer.id().to_string(), e);
                                                }
                                            }
                                        }
                                    }
                                    if let NetworkRequest::JoinNetwork(_, network_id) = inner_pkt {
                                        tls_server.add_network(network_id).map_err(|e| error!("{}", e)).ok();
                                    }
                                }
                            }
                            box NetworkMessage::NetworkRequest(ref inner_pkt @ NetworkRequest::LeaveNetwork(_,_), _, _) => {
                                {
                                    let mut tls_server = self.tls_server.lock()?;
                                    for (_, mut conn) in &mut tls_server.connections {
                                        if let Some(ref peer) = conn.peer.clone() {
                                            match serialize_bytes(conn, &inner_pkt.serialize()) {
                                                Ok(_) => {
                                                    self.pks_sent_inc()?;
                                                    TOTAL_MESSAGES_SENT_COUNTER.inc();
                                                }
                                                Err(e) => {
                                                    error!("Could not send to peer {} due to {}", peer.id().to_string(), e);
                                                }
                                            }
                                        }
                                    }
                                    if let NetworkRequest::LeaveNetwork(_, network_id) = inner_pkt {
                                        tls_server.remove_network(network_id).map_err(|e| error!("{}", e)).ok();
                                    }
                                }
                            }
                            box NetworkMessage::NetworkRequest(ref inner_pkt @ NetworkRequest::UnbanNode(_, _),
                                                               _,
                                                               _) => {
                                for (_, mut conn) in &mut self.tls_server.lock()?.connections {
                                    if let Some(ref peer) = conn.peer.clone() {
                                        match serialize_bytes(conn, &inner_pkt.serialize()) {
                                            Ok(_) => {
                                                self.pks_sent_inc()?;
                                                TOTAL_MESSAGES_SENT_COUNTER.inc();
                                            }
                                            Err(e) => {
                                                error!("Could not send to peer {} due to {}", peer.id().to_string(), e);
                                            }
                                        }
                                    }
                                }
                            }
                            box NetworkMessage::NetworkRequest(ref inner_pkt @ NetworkRequest::GetPeers(_,_), _, _) => {
                                for (_, mut conn) in &mut self.tls_server.lock()?.connections {
                                    if let Some(ref peer) = conn.peer.clone() {
                                        match serialize_bytes(conn, &inner_pkt.serialize()) {
                                            Ok(_) => {
                                                self.pks_sent_inc()?;
                                                TOTAL_MESSAGES_SENT_COUNTER.inc();
                                            }
                                            Err(e) => {
                                                error!("Could not send to peer {} due to {}", peer.id().to_string(), e);
                                            }
                                        }
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                    _ => {
                        if resend_queue.len() > 0 {
                            if let Some(ref prom) = &self.prometheus_exporter {
                                match prom.lock() {
                                    Ok(ref mut lock) => {
                                        lock.queue_size_inc_by(resend_queue.len() as i64)
                                            .map_err(|e| error!("{}", e))
                                            .ok();
                                        lock.queue_resent_inc_by(resend_queue.len() as i64)
                                            .map_err(|e| error!("{}", e))
                                            .ok();
                                    }
                                    _ => error!("Couldn't lock prometheus instance"),
                                }
                            };
                            send_q.append(&mut resend_queue);
                            resend_queue.clear();
                        }
                        break;
                    }
                }
            }
        }
        Ok(())
    }

    fn queue_size_inc(&self) -> ResultExtWrapper<()> {
        if let Some(ref prom) = &self.prometheus_exporter {
            match prom.lock() {
                Ok(ref mut lock) => {
                    lock.queue_size_inc().map_err(|e| error!("{}", e)).ok();
                }
                _ => error!("Couldn't lock prometheus instance"),
            }
        };
        Ok(())
    }

    fn pks_sent_inc(&self) -> ResultExtWrapper<()> {
        if let Some(ref prom) = &self.prometheus_exporter {
            match prom.lock() {
                Ok(ref mut lock) => {
                    lock.pkt_sent_inc().map_err(|e| error!("{}", e)).ok();
                }
                _ => error!("Couldn't lock prometheus instance"),
            }
        };
        Ok(())
    }

    pub fn send_message(&mut self,
                        id: Option<P2PNodeId>,
                        network_id: u16,
                        msg_id: Option<String>,
                        msg: &[u8],
                        broadcast: bool)
                        -> ResultExtWrapper<()> {
        debug!("Queueing message!");
        match broadcast {
            true => {
                self.send_queue.lock()?.push_back(Arc::new(box NetworkMessage::NetworkPacket(NetworkPacket::BroadcastedMessage(self.get_self_peer(), msg_id.unwrap_or(NetworkPacket::generate_message_id()), network_id,  msg.to_vec()), None, None)));
                self.queue_size_inc()?;
                return Ok(());
            }
            false => {
                match id {
                    Some(x) => {
                        self.send_queue.lock()?.push_back(Arc::new(box NetworkMessage::NetworkPacket(NetworkPacket::DirectMessage(self.get_self_peer(), msg_id.unwrap_or(NetworkPacket::generate_message_id()), x, network_id, msg.to_vec()), None, None)));
                        self.queue_size_inc()?;
                        return Ok(());
                    }
                    None => {
                        return Err(ErrorKindWrapper::ParseError("Invalid receiver ID for message".to_string()).into());
                    }
                }
            }
        }
    }

    pub fn send_ban(&mut self, id: P2PPeer) -> ResultExtWrapper<()> {
        self.send_queue
            .lock()?
            .push_back(Arc::new(box NetworkMessage::NetworkRequest(NetworkRequest::BanNode(self.get_self_peer(), id),
                                                               None,
                                                               None)));
        self.queue_size_inc()?;
        Ok(())
    }

    pub fn send_unban(&mut self, id: P2PPeer) -> ResultExtWrapper<()> {
        self.send_queue
            .lock()?
            .push_back(Arc::new(box NetworkMessage::NetworkRequest(NetworkRequest::UnbanNode(self.get_self_peer(), id),
                                                               None,
                                                               None)));
        self.queue_size_inc()?;
        Ok(())
    }

    pub fn send_joinnetwork(&mut self, network_id: u16) -> ResultExtWrapper<()> {
        self.send_queue
            .lock()?
            .push_back(Arc::new(box NetworkMessage::NetworkRequest(NetworkRequest::JoinNetwork(self.get_self_peer(), network_id),
                                                               None,
                                                               None)));
        self.queue_size_inc()?;
        Ok(())
    }

    pub fn send_leavenetwork(&mut self, network_id: u16) -> ResultExtWrapper<()> {
        self.send_queue
            .lock()?
            .push_back(Arc::new(box NetworkMessage::NetworkRequest(NetworkRequest::LeaveNetwork(self.get_self_peer(), network_id),
                                                               None,
                                                               None)));
        self.queue_size_inc()?;
        Ok(())
    }

    pub fn send_get_peers(&mut self, nids: Vec<u16>) -> ResultExtWrapper<()> {
        self.send_queue
            .lock()?
            .push_back(Arc::new(box NetworkMessage::NetworkRequest(NetworkRequest::GetPeers(self.get_self_peer(),nids.clone() ),
                                                               None,
                                                               None)));
        self.queue_size_inc()?;
        Ok(())
    }

    pub fn peek_queue(&self) -> Vec<String> {
        if let Ok(lock) = self.send_queue.lock() {
            return lock.iter()
                       .map(|x| format!("{:?}", x))
                       .collect::<Vec<String>>();
        };
        vec![]
    }

    pub fn get_peer_stats(&self, nids: &Vec<u16>) -> ResultExtWrapper<Vec<PeerStatistic>> {
        match self.tls_server.lock() {
            Ok(x) => Ok(x.get_peer_stats(nids)),
            Err(e) => {
                error!("Couldn't lock for tls_server: {:?}", e);
                Err(ErrorWrapper::from(e))
            }
        }
    }

    pub fn get_ip() -> Option<IpAddr> {
        let localhost = IpAddr::from_str("127.0.0.1").unwrap();
        let mut ip: IpAddr = localhost.clone();

        for adapter in get_if_addrs::get_if_addrs().unwrap() {
            match adapter.addr.ip() {
                V4(x) => {
                    if !x.is_loopback()
                       && !x.is_link_local()
                       && !x.is_multicast()
                       && !x.is_broadcast()
                    {
                        ip = IpAddr::V4(x);
                    }
                }
                V6(_) => {
                    //Ignore for now
                }
            };
        }

        if ip == localhost {
            None
        } else {
            Some(ip)
        }
    }

    fn get_self_peer(&self) -> P2PPeer {
        P2PPeer::from(ConnectionType::Node,
                      self.get_own_id().clone(),
                      self.get_listening_ip().clone(),
                      self.get_listening_port())
    }

    pub fn get_total_sent(&self) -> u64 {
        TOTAL_MESSAGES_SENT_COUNTER.get() as u64
    }

    pub fn get_total_received(&self) -> u64 {
        TOTAL_MESSAGES_SENT_COUNTER.get() as u64
    }

    pub fn ban_node(&mut self, peer: P2PPeer) -> ResultExtWrapper<()> {
        match self.tls_server.lock() {
            Ok(mut x) => {
                x.ban_node(peer);
                Ok(())
            }
            Err(e) => Err(ErrorWrapper::from(e)),
        }
    }

    pub fn unban_node(&mut self, peer: P2PPeer) -> ResultExtWrapper<()> {
        match self.tls_server.lock() {
            Ok(mut x) => {
                x.unban_node(peer);
                Ok(())
            }
            Err(e) => Err(ErrorWrapper::from(e)),
        }
    }

    pub fn process(&mut self, events: &mut Events) -> ResultExtWrapper<()> {
        self.poll
            .lock()?
            .poll(events, Some(Duration::from_millis(500)))?;

        if self.mode != P2PNodeMode::BootstrapperMode
           && self.mode != P2PNodeMode::BootstrapperPrivateMode
        {
            self.tls_server.lock()?.liveness_check()?;
        }

        for event in events.iter() {
            let mut tls_ref = self.tls_server.lock()?;
            let mut poll_ref = self.poll.lock()?;
            let mut buckets_ref = self.buckets.lock()?;
            match event.token() {
                SERVER => {
                    debug!("Got new connection!");
                    tls_ref.accept(&mut poll_ref, self.get_self_peer().clone())
                           .map_err(|e| error!("{}", e))
                           .ok();
                    if let Some(ref prom) = &self.prometheus_exporter {
                        prom.lock()?
                            .conn_received_inc()
                            .map_err(|e| error!("{}", e))
                            .ok();
                    };
                }
                _ => {
                    trace!("Got data!");
                    tls_ref.conn_event(&mut poll_ref,
                                       &event,
                                       &mut buckets_ref,
                                       &self.incoming_pkts)
                           .map_err(|e| error!("Error occured while parsing event '{}'", e))
                           .ok();
                }
            }
        }

        {
            let mut tls_ref = self.tls_server.lock()?;
            let mut poll_ref = self.poll.lock()?;
            let mut buckets_ref = self.buckets.lock()?;
            tls_ref.cleanup_connections(&mut poll_ref)?;
            if self.mode == P2PNodeMode::BootstrapperMode
               || self.mode == P2PNodeMode::BootstrapperPrivateMode
            {
                buckets_ref.clean_peers_older_than(common::get_current_stamp() - 3600000);
            }
        }

        self.process_messages()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use p2p::*;

    #[test]
    pub fn test_buckets_insert_duplicate_peer_id() {
        let mut bucket = Buckets::new();
        let p2p_self = P2PNodeId::from_ipstring("127.0.0.1:8888".to_string());
        let p2p_node_id = P2PNodeId::from_string(&"c19cd000746763871fae95fcdd4508dfd8bf725f9767be68c3038df183527bb2".to_string()).unwrap();
        let p2p_new_peer = P2PPeer::from(ConnectionType::Node,
                                         p2p_node_id.clone(),
                                         IpAddr::from_str("127.0.0.1").unwrap(),
                                         8888);
        let p2p_new_replacement_peer = P2PPeer::from(ConnectionType::Node,
                                                     p2p_node_id.clone(),
                                                     IpAddr::from_str("127.0.0.1").unwrap(),
                                                     8889);
        bucket.insert_into_bucket(&p2p_new_peer, &p2p_self, vec![]);
        bucket.insert_into_bucket(&p2p_new_replacement_peer, &p2p_self, vec![]);
        assert_eq!(bucket.len(), 1);
    }

    #[test]
    pub fn test_buckets_insert_duplicate_ip_port() {
        let mut bucket = Buckets::new();
        let p2p_self = P2PNodeId::from_ipstring("127.0.0.1:8888".to_string());
        let p2p_node_id = P2PNodeId::from_string(&"c19cd000746763871fae95fcdd4508dfd8bf725f9767be68c3038df183527bb2".to_string()).unwrap();
        let p2p_node_id_2 = P2PNodeId::from_string(&"c19cd000746763871fae95fcdd4508dfd8bf725f9767be68c3038df183527bb3".to_string()).unwrap();
        let p2p_new_peer = P2PPeer::from(ConnectionType::Node,
                                         p2p_node_id.clone(),
                                         IpAddr::from_str("127.0.0.1").unwrap(),
                                         8888);
        let p2p_new_replacement_peer = P2PPeer::from(ConnectionType::Node,
                                                     p2p_node_id_2.clone(),
                                                     IpAddr::from_str("127.0.0.1").unwrap(),
                                                     8888);
        bucket.insert_into_bucket(&p2p_new_peer, &p2p_self, vec![]);
        bucket.insert_into_bucket(&p2p_new_replacement_peer, &p2p_self, vec![]);
        assert_eq!(bucket.len(), 1);
    }
}
