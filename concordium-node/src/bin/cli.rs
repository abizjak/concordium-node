extern crate p2p_client;
#[macro_use]
extern crate log;
extern crate bytes;
extern crate chrono;
extern crate env_logger;
extern crate grpcio;
extern crate mio;
extern crate timer;

use env_logger::Env;
use p2p_client::common::{NetworkMessage, NetworkPacket, NetworkRequest, NetworkResponse};
use p2p_client::configuration;
use p2p_client::db::P2PDB;
use p2p_client::p2p::*;
use p2p_client::rpc::RpcServerImpl;
use p2p_client::utils;
use std::sync::mpsc;
use std::thread;
use timer::Timer;

fn main() {
    let conf = configuration::parse_config();
    let app_prefs = configuration::AppPreferences::new();

    let bootstrap_nodes = utils::get_bootstrap_nodes(conf.require_dnssec);

    let listen_port = match conf.listen_port {
        Some(x) => x,
        _ => 8888,
    };

    let env = if conf.debug {
        Env::default().filter_or("MY_LOG_LEVEL", "debug")
    } else {
        Env::default().filter_or("MY_LOG_LEVEL", "info")
    };

    env_logger::init_from_env(env);
    info!("Starting up {} version {}!",
          p2p_client::APPNAME,
          p2p_client::VERSION);
    info!("Application data directory: {:?}",
          app_prefs.get_user_app_dir());
    info!("Application config directory: {:?}",
          app_prefs.get_user_config_dir());

    let mut db_path = app_prefs.get_user_app_dir().clone();
    db_path.push("p2p.db");

    let db = P2PDB::new(db_path.as_path());

    info!("Debugging enabled {}", conf.debug);

    let (pkt_in, pkt_out) = mpsc::channel();

    let mut node = if conf.debug {
        let (sender, receiver) = mpsc::channel();
        let _guard = thread::spawn(move || loop {
                                       if let Ok(msg) = receiver.recv() {
                                           match msg {
                                               P2PEvent::ConnectEvent(ip, port) => {
                                                   info!("Received connection from {}:{}", ip, port)
                                               }
                                               P2PEvent::DisconnectEvent(msg) => {
                                                   info!("Received disconnect for {}", msg)
                                               }
                                               P2PEvent::ReceivedMessageEvent(node_id) => {
                                                   info!("Received message from {:?}", node_id)
                                               }
                                               P2PEvent::SentMessageEvent(node_id) => {
                                                   info!("Sent message to {:?}", node_id)
                                               }
                                               P2PEvent::InitiatingConnection(ip, port) => {
                                                   info!("Initiating connection to {}:{}", ip, port)
                                               }
                                           }
                                       }
                                   });
        P2PNode::new(conf.id, listen_port, pkt_in, Some(sender))
    } else {
        P2PNode::new(conf.id, listen_port, pkt_in, None)
    };

    match db.get_banlist() {
        Some(nodes) => {
            info!("Found existing banlist, loading up!");
            for n in nodes {
                node.ban_node(n.to_peer());
            }
        }
        None => {
            info!("Couldn't find existing banlist. Creating new!");
            db.create_banlist();
        }
    };

    let mut rpc_serv: Option<RpcServerImpl> = None;
    if !conf.no_rpc_server {
        let mut serv = RpcServerImpl::new(node.clone(),
                                          Some(db.clone()),
                                          conf.rpc_server_addr,
                                          conf.rpc_server_port,
                                          conf.rpc_server_token);
        serv.start_server();
        rpc_serv = Some(serv);
    }

    let mut _node_self_clone = node.clone();

    let _no_trust_bans = conf.no_trust_bans;
    let _no_trust_broadcasts = conf.no_trust_broadcasts;
    let mut _rpc_clone = rpc_serv.clone();
    let _desired_nodes_clone = conf.desired_nodes;
    let _guard_pkt = thread::spawn(move || loop {
        if let Ok(ref mut full_msg) = pkt_out.recv() {
            match full_msg {
                NetworkMessage::NetworkPacket(NetworkPacket::DirectMessage(_, _, ref msg),
                                              _,
                                              _) => {
                    if let Some(ref mut rpc) = _rpc_clone {
                        rpc.queue_message(full_msg);
                    }
                    info!("DirectMessage with size {} received", msg.len());
                }
                NetworkMessage::NetworkPacket(NetworkPacket::BroadcastedMessage(_, ref msg),
                                              _,
                                              _) => {
                    if let Some(ref mut rpc) = _rpc_clone {
                        rpc.queue_message(full_msg);
                    }
                    if !_no_trust_broadcasts {
                        info!("BroadcastedMessage with size {} received", msg.len());
                        _node_self_clone.send_message(None, &msg, true);
                    }
                }

                NetworkMessage::NetworkRequest(NetworkRequest::BanNode(peer, x), _, _) => {
                    info!("Ban node request for {:?}", x);
                    _node_self_clone.ban_node(x.clone());
                    db.insert_ban(peer.id().to_string(), format!("{}", peer.ip()), peer.port());
                    if !_no_trust_bans {
                        _node_self_clone.send_ban(x.clone());
                    }
                }
                NetworkMessage::NetworkRequest(NetworkRequest::UnbanNode(peer, x), _, _) => {
                    info!("Unban node requets for {:?}", x);
                    _node_self_clone.unban_node(x.clone());
                    db.delete_ban(peer.id().to_string(), format!("{}", peer.ip()), peer.port());
                    if !_no_trust_bans {
                        _node_self_clone.send_unban(x.clone());
                    }
                }
                NetworkMessage::NetworkResponse(NetworkResponse::PeerList(_, peers), _, _) => {
                    info!("Received PeerList response, attempting to satisfy desired peers");
                    let mut new_peers = 0;
                    match _node_self_clone.get_nodes() {
                        Ok(x) => {
                            for peer_node in peers {
                                if _node_self_clone.connect(peer_node.ip(), peer_node.port()) {
                                    new_peers += 1;
                                }
                                if new_peers + x.len() as u8 >= _desired_nodes_clone {
                                    break;
                                }
                            }
                        }
                        _ => {
                            error!("Can't get nodes - so not trying to connect to new peers!");
                        }
                    }
                }
                _ => {}
            }
        }
    });

    info!("Concordium P2P layer. Network disabled: {}",
          conf.no_network);

    let _node_th = node.spawn();

    if conf.connect_to.is_some() {
        let connect_to = conf.connect_to.unwrap();
        match utils::parse_ip_port(&connect_to) {
            Some((ip, port)) => {
                info!("Connecting to peer {}", &connect_to);
                node.connect(ip, port);
            }
            _ => {}
        }
    }

    info!("Attempting to bootstrap via DNS");
    match bootstrap_nodes {
        Ok(nodes) => {
            for (ip, port) in nodes {
                info!("Found bootstrap node IP: {} and port: {}", ip, port);
                node.connect(ip, port);
            }
        },
        Err(e) => error!("Couldn't retrieve bootstrap node list! {:?}", e),
    };

    let timer = Timer::new();

    let _desired_nodes_count = conf.desired_nodes;
    let _no_net_clone = conf.no_network;
    let _guard_timer = timer.schedule_repeating(chrono::Duration::seconds(30), move || {
                                match node.get_nodes() {
                                    Ok(x) => {
                                        info!("I currently have {}/{} nodes!",
                                              x.len(),
                                              _desired_nodes_count);
                                        if !_no_net_clone && _desired_nodes_count > x.len() as u8 {
                                            info!("Not enough nodes, sending GetPeers requests");
                                            node.send_get_peers();
                                        }
                                    }
                                    Err(e) => error!("Couldn't get node list, {:?}", e),
                                };
                            });

    _node_th.join().unwrap();
    if let Some(ref mut serv) = rpc_serv {
        serv.stop_server();
    }
}