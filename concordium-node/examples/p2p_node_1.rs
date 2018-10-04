#![feature(box_syntax, box_patterns)]
#![recursion_limit = "1024"]
#[macro_use]
extern crate error_chain;
extern crate bytes;
extern crate mio;
extern crate p2p_client;
#[macro_use]
extern crate log;
extern crate chrono;
extern crate env_logger;
extern crate timer;

use env_logger::{Builder, Env};
use p2p_client::common::{ConnectionType, NetworkMessage, NetworkPacket, NetworkRequest};
use p2p_client::configuration;
use p2p_client::db::P2PDB;
use p2p_client::errors::*;
use p2p_client::p2p::*;
use p2p_client::prometheus_exporter::{PrometheusMode, PrometheusServer};
use p2p_client::utils;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use timer::Timer;

quick_main!(run);

fn run() -> ResultExtWrapper<()> {
    let conf = configuration::parse_cli_config();
    let app_prefs =
        configuration::AppPreferences::new(conf.config_dir.clone(), conf.data_dir.clone());

    let env = if conf.trace {
        Env::default().filter_or("MY_LOG_LEVEL", "trace")
    } else if conf.debug {
        Env::default().filter_or("MY_LOG_LEVEL", "debug")
    } else {
        Env::default().filter_or("MY_LOG_LEVEL", "info")
    };

    let mode_type = if conf.private_node {
        P2PNodeMode::BootstrapperPrivateMode
    } else {
        P2PNodeMode::BootstrapperMode
    };

    let mut log_builder = Builder::from_env(env);
    if conf.no_log_timestamp {
        log_builder.default_format_timestamp(false);
    }
    log_builder.init();

    p2p_client::setup_panics();

    info!("Starting up {} version {}!",
          p2p_client::APPNAME,
          p2p_client::VERSION);

    info!("Application data directory: {:?}",
          app_prefs.get_user_app_dir());
    info!("Application config directory: {:?}",
          app_prefs.get_user_config_dir());

    let prometheus = if conf.prometheus_server {
        info!("Enabling prometheus server");
        let mut srv = PrometheusServer::new(PrometheusMode::NodeMode);
        srv.start_server(&conf.prometheus_listen_addr, conf.prometheus_listen_port)
           .map_err(|e| error!("{}", e))
           .ok();
        Some(Arc::new(Mutex::new(srv)))
    } else if conf.prometheus_push_gateway.is_some() {
        info!("Enabling prometheus push gateway at {}",
              &conf.prometheus_push_gateway.clone().unwrap());
        let mut srv = PrometheusServer::new(PrometheusMode::NodeMode);
        Some(Arc::new(Mutex::new(srv)))
    } else {
        None
    };

    info!("Debuging enabled {}", conf.debug);

    let mut db_path = app_prefs.get_user_app_dir().clone();
    db_path.push("p2p.db");

    let db = P2PDB::new(db_path.as_path());

    let bootstrap_nodes = utils::get_bootstrap_nodes(conf.bootstrap_server.clone(),
                                                     &conf.dns_resolver,
                                                     conf.no_dnssec,
                                                     conf.bootstrap_node.clone());

    let (pkt_in, pkt_out) = mpsc::channel::<Arc<Box<NetworkMessage>>>();

    let _guard_pkt = thread::spawn(move || {
                                       loop {
                                           if let Ok(ref outer_msg) = pkt_out.recv() {
                                               match *outer_msg.clone() {
                                               box NetworkMessage::NetworkPacket(NetworkPacket::DirectMessage(_, ref msgid, _, ref nid, ref msg), _, _) => info!("DirectMessage/{}/{} with {:?} received", nid, msgid, msg),
                                               box NetworkMessage::NetworkPacket(NetworkPacket::BroadcastedMessage(_,ref msgid, ref nid, ref msg), _, _) => info!("BroadcastedMessage/{}/{} with {:?} received", nid, msgid, msg),
                                               box NetworkMessage::NetworkRequest(NetworkRequest::BanNode(_, ref x), _, _) => info!("Ban node request for {:?}", x),
                                               box NetworkMessage::NetworkRequest(NetworkRequest::UnbanNode(_, ref x), _, _) => info!("Unban node requets for {:?}", x),
                                               _ => {}
                                           }
                                           }
                                       }
                                   });

    let external_ip = if conf.external_ip.is_some() {
        conf.external_ip
    } else if conf.ip_discovery_service {
        match utils::discover_external_ip(&conf.ip_discovery_service_host) {
            Ok(ip) => Some(ip.to_string()),
            Err(_) => None,
        }
    } else {
        None
    };

    let mut node = if conf.debug {
        let (sender, receiver) = mpsc::channel();
        let _guard =
            thread::spawn(move || {
                              loop {
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
                                          P2PEvent::JoinedNetwork(peer, network_id) => {
                                              info!("Peer {} joined network {}",
                                                    peer.id().to_string(),
                                                    network_id);
                                          }
                                          P2PEvent::LeftNetwork(peer, network_id) => {
                                              info!("Peer {} left network {}",
                                                    peer.id().to_string(),
                                                    network_id);
                                          }
                                      }
                                  }
                              }
                          });
        P2PNode::new(conf.id,
                     conf.listen_address,
                     conf.listen_port,
                     external_ip,
                     conf.external_port,
                     pkt_in,
                     Some(sender),
                     mode_type,
                     prometheus.clone(),
                     conf.network_ids.clone())
    } else {
        P2PNode::new(conf.id,
                     conf.listen_address,
                     conf.listen_port,
                     external_ip,
                     conf.external_port,
                     pkt_in,
                     None,
                     mode_type,
                     prometheus.clone(),
                     conf.network_ids.clone())
    };

    if let Some(ref prom) = prometheus {
        if let Some(ref prom_push_addy) = conf.prometheus_push_gateway {
            let instance_name = if let Some(ref instance_id) = conf.prometheus_instance_name {
                instance_id.clone()
            } else {
                node.get_own_id().to_string()
            };
            prom.lock()?
                .start_push_to_gateway(prom_push_addy.clone(),
                                       conf.prometheus_push_interval,
                                       conf.prometheus_job_name,
                                       instance_name,
                                       conf.prometheus_push_username,
                                       conf.prometheus_push_password)
                .map_err(|e| error!("{}", e))
                .ok();
        }
    }

    let _th = node.spawn();

    if !conf.no_network {
        for connect_to in conf.connect_to {
            match utils::parse_host_port(&connect_to, &conf.dns_resolver, conf.no_dnssec) {
                Some((ip, port)) => {
                    info!("Connecting to peer {}", &connect_to);
                    node.connect(ConnectionType::Node, ip, port)
                        .map_err(|e| error!("{}", e))
                        .ok();
                }
                None => error!("Can't parse IP to connect to '{}'", &connect_to),
            }
        }
    }

    if !conf.no_network && !conf.no_boostrap_dns {
        info!("Attempting to bootstrap");
        match bootstrap_nodes {
            Ok(nodes) => {
                for (ip, port) in nodes {
                    info!("Found bootstrap node IP: {} and port: {}", ip, port);
                    node.connect(ConnectionType::Bootstrapper, ip, port)
                        .map_err(|e| error!("{}", e))
                        .ok();
                }
            }
            Err(e) => error!("Couldn't retrieve bootstrap node list! {:?}", e),
        };
    }

    match db.get_banlist() {
        Some(nodes) => {
            info!("Found existing banlist, loading up!");
            for n in nodes {
                node.ban_node(n.to_peer())?;
            }
        }
        None => {
            info!("Couldn't find existing banlist. Creating new!");
            db.create_banlist();
        }
    };

    let timer = Timer::new();

    let _desired_nodes_count = conf.desired_nodes;
    let _no_net_clone = conf.no_network;
    let _bootstrappers_conf = conf.bootstrap_server;
    let _dnssec = conf.no_dnssec;
    let _dns_resolvers = conf.dns_resolver.clone();
    let _bootstrap_node = conf.bootstrap_node.clone();
    let _nids = conf.network_ids.clone();
    let _guard_timer =
        timer.schedule_repeating(chrono::Duration::seconds(30), move || {
                 match node.get_nodes(&vec![]) {
                     Ok(ref x) => {
                         info!("I currently have {}/{} nodes!",
                               x.len(),
                               _desired_nodes_count);
                         let mut count = 0;
                         for i in x {
                             info!("Peer {}: {}/{}:{}",
                                   count,
                                   i.id().to_string(),
                                   i.ip().to_string(),
                                   i.port());
                             count += 1;
                         }
                         if !_no_net_clone && _desired_nodes_count > x.len() as u8 {
                             if x.len() == 0 {
                                 info!("No nodes at all - retrying bootstrapping");
                                 match utils::get_bootstrap_nodes(_bootstrappers_conf.clone(),
                                                                  &_dns_resolvers,
                                                                  _dnssec,
                                                                  _bootstrap_node.clone())
                                 {
                                     Ok(nodes) => {
                                         for (ip, port) in nodes {
                                             info!("Found bootstrap node IP: {} and port: {}",
                                                   ip, port);
                                             node.connect(ConnectionType::Bootstrapper, ip, port)
                                                 .map_err(|e| error!("{}", e))
                                                 .ok();
                                         }
                                     }
                                     _ => error!("Can't find any bootstrap nodes - check DNS!"),
                                 }
                             } else {
                                 info!("Not enough nodes, sending GetPeers requests");
                                 node.send_get_peers(_nids.clone())
                                     .map_err(|e| error!("{}", e))
                                     .ok();
                             }
                         }
                     }
                     Err(e) => error!("Couldn't get node list, {:?}", e),
                 };
             });

    _th.join().unwrap();

    Ok(())
}
