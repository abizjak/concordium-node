//! Miscellaneous utilities.

use crate::configuration as config;
use env_logger::{Builder, Env};
use log::LevelFilter;
use std::{
    io::Write,
    net::{SocketAddr, ToSocketAddrs},
    path::Path,
};

pub fn to_hex_string(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

/// Setup a log4rs logger based on the given configuration file.
pub fn setup_logger_config(config_file: &Path) {
    log4rs::init_file(config_file, Default::default()).unwrap();
}

pub fn setup_logger_env(env: Env, no_log_timestamp: bool) {
    let mut log_builder = Builder::from_env(env);
    if no_log_timestamp {
        log_builder.format_timestamp(None);
    } else {
        log_builder.format(|buf, record| {
            writeln!(buf, "{}: {}: {}", buf.timestamp_nanos(), record.level(), record.args())
        });
    }
    log_builder.filter(Some(&"tokio_reactor"), LevelFilter::Error);
    log_builder.filter(Some(&"hyper"), LevelFilter::Error);
    log_builder.filter(Some(&"reqwest"), LevelFilter::Error);
    log_builder.filter(Some(&"gotham"), LevelFilter::Error);
    log_builder.filter(Some(&"h2"), LevelFilter::Error);
    log_builder.init();
}

pub fn get_bootstrap_nodes(bootstrap_nodes: &[String]) -> Result<Vec<SocketAddr>, String> {
    if !bootstrap_nodes.is_empty() {
        debug!("Resolving bootstrapper nodes.");
        let bootstrap_nodes = bootstrap_nodes
            .iter()
            .filter_map(|ip_port| {
                ToSocketAddrs::to_socket_addrs(ip_port)
                    .map_err(|err| error!("Invalid bootstrapper node received: {}", err))
                    .ok()
            })
            .flatten()
            .collect::<Vec<_>>();
        Ok(bootstrap_nodes)
    } else {
        Err("No bootstrap nodes specified.".to_string())
    }
}

pub fn get_config_and_logging_setup() -> anyhow::Result<(config::Config, config::AppPreferences)> {
    // Get config and app preferences
    let conf = config::parse_config()?;
    let app_prefs = config::AppPreferences::new(
        conf.common.config_dir.to_owned(),
        conf.common.data_dir.to_owned(),
    );

    // Prepare the logger
    let (env, log_lvl) = if conf.common.trace {
        (Env::default().filter_or("LOG_LEVEL", "trace"), "trace")
    } else if conf.common.debug {
        (Env::default().filter_or("LOG_LEVEL", "debug"), "debug")
    } else {
        (Env::default().filter_or("LOG_LEVEL", "info"), "info")
    };

    if let Some(ref log_config) = conf.common.log_config {
        setup_logger_config(log_config);
    } else {
        setup_logger_env(env, conf.common.no_log_timestamp);
    }

    if conf.common.print_config {
        info!("Config:{:?}\n", conf);
    }

    info!("Starting up {} version {}!", crate::APPNAME, crate::VERSION);
    info!("Application data directory: {}", app_prefs.get_user_app_dir().to_string_lossy());
    info!("Application config directory: {}", app_prefs.get_user_config_dir().to_string_lossy());
    info!(
        "Network: {}",
        if conf.cli.no_network {
            "disabled"
        } else {
            "enabled"
        }
    );
    info!("Log level: {}", log_lvl);

    Ok((conf, app_prefs))
}
