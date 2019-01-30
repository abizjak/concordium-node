use common::functor::{ AFunctor, AFunctorCW, FunctorResult };
use network::{ NetworkRequest };
use network::request::{ NetworkRequest as NRequest };


pub struct RequestHandler {
    pub ping_handler: AFunctor<NRequest>,
    pub find_node_handler: AFunctor<NRequest>,
    pub ban_node_handler: AFunctor<NRequest>,
    pub unban_node_handler: AFunctor<NRequest>,
    pub handshake_handler: AFunctor<NRequest>,
    pub get_peers_handler: AFunctor<NRequest>,
    pub join_network_handler: AFunctor<NRequest>,
    pub leave_network_handler: AFunctor<NRequest>,

    pub main_handler: AFunctor<NRequest>
}

impl RequestHandler {

    pub fn new() -> Self {
        RequestHandler {
            ping_handler: AFunctor::<NRequest>::new(
                    "Network request ping handler"),
            find_node_handler: AFunctor::new(
                    "Network request find node handler"),
            ban_node_handler: AFunctor::new(
                    "Network request ban node handler"),
            unban_node_handler: AFunctor::new(
                    "Network request unban node handler"),
            handshake_handler: AFunctor::new(
                    "Network request handshake handler"),
            get_peers_handler: AFunctor::new(
                    "Network request get peers handler"),
            join_network_handler: AFunctor::new(
                    "Network request join network handler"),
            leave_network_handler: AFunctor::new(
                    "Network request leave network handler"),
            main_handler: AFunctor::new(
                    "Main Network request handler")
        }
    }

    pub fn add_callback( &mut self, callback: AFunctorCW<NRequest>) -> &mut Self {
        self.main_handler.add_callback( callback);
        self
    }

    pub fn add_ping_callback( &mut self, callback: AFunctorCW<NRequest>) -> &mut Self {
        self.ping_handler.add_callback( callback);
        self
    }

    pub fn add_find_node_callback( &mut self, callback: AFunctorCW<NRequest>) -> &mut Self {
        self.find_node_handler.add_callback( callback);
        self
    }

    pub fn add_ban_node_callback( &mut self, callback: AFunctorCW<NRequest>) -> &mut Self {
        self.ban_node_handler.add_callback( callback);
        self
    }

    pub fn add_unban_node_callback( &mut self, callback: AFunctorCW<NRequest>) -> &mut Self {
        self.unban_node_handler.add_callback( callback);
        self
    }

    pub fn add_handshake_callback( &mut self, callback: AFunctorCW<NRequest>) -> &mut Self {
        self.handshake_handler.add_callback( callback);
        self
    }

    pub fn add_get_peers_callback( &mut self, callback: AFunctorCW<NRequest>) -> &mut Self {
        self.get_peers_handler.add_callback( callback);
        self
    }

    pub fn add_join_network_callback( &mut self, callback: AFunctorCW<NRequest>) -> &mut Self {
        self.join_network_handler.add_callback( callback);
        self
    }

    pub fn add_leave_network_callback( &mut self, callback: AFunctorCW<NRequest>) -> &mut Self {
        self.leave_network_handler.add_callback( callback);
        self
    }

    fn process_message(&self, msg: &NetworkRequest) -> FunctorResult {
        let main_status = (&self.main_handler)(msg);

        let spec_status = match msg {
            ref ping_inner_pkt @ NetworkRequest::Ping(_) => {
                (&self.ping_handler)(ping_inner_pkt)
            },
            ref find_inner_pkt @ NetworkRequest::FindNode(_, _) => {
                (&self.find_node_handler)(find_inner_pkt)
            },
            ref ban_inner_pkt @ NetworkRequest::BanNode(_, _) => {
                (&self.ban_node_handler)(ban_inner_pkt)
            },
            ref unban_inner_pkt @ NetworkRequest::UnbanNode(_, _) => {
                (&self.unban_node_handler)(unban_inner_pkt)
            },
            ref handshake_inner_pkt @ NetworkRequest::Handshake(_, _, _) => {
                (&self.handshake_handler)(handshake_inner_pkt)
            },
            ref get_peers_inner_pkt @ NetworkRequest::GetPeers(_, _) => {
                (&self.get_peers_handler)(get_peers_inner_pkt)
            },
            ref join_network_inner_pkt @ NetworkRequest::JoinNetwork(_, _) => {
                (&self.join_network_handler)(join_network_inner_pkt)
            },
            ref leave_network_inner_pkt @ NetworkRequest::LeaveNetwork(_, _) => {
                (&self.leave_network_handler)(leave_network_inner_pkt)
            }
        };

        main_status.and( spec_status)
    }
}

impl_all_fns!( RequestHandler, NRequest);


#[cfg(test)]
mod request_handler_test {
    use connection::{ RequestHandler };
    use common::{ ConnectionType, P2PPeer, P2PNodeId };
    use network::request::{ NetworkRequest as NRequest };

    use std::sync::{ Arc, Mutex };
    use std::net::{ IpAddr, Ipv4Addr };
    use std::sync::atomic::{ AtomicUsize, Ordering, ATOMIC_USIZE_INIT };

    static PING_COUNTER: AtomicUsize = ATOMIC_USIZE_INIT;
    static FIND_NODE_COUNTER: AtomicUsize = ATOMIC_USIZE_INIT;
    static BAN_NODE_COUNTER: AtomicUsize = ATOMIC_USIZE_INIT;

    fn make_request_handler() -> RequestHandler {
        let mut handler = RequestHandler::new();

        handler.add_ping_callback( make_atomic_callback!( |_:&NRequest| {
                PING_COUNTER.fetch_add( 1, Ordering::SeqCst);
                Ok(())
            }))
            .add_find_node_callback( make_atomic_callback!( |_:&NRequest| {
                FIND_NODE_COUNTER.fetch_add( 1, Ordering::SeqCst);
                Ok(())
            }))
            .add_ban_node_callback( make_atomic_callback!( |_:&NRequest| {
                BAN_NODE_COUNTER.fetch_add( 1, Ordering::SeqCst);
                Ok(())
            }));

        handler
    }

    fn ut_1_data() -> Vec<NRequest> {
        let ip = IpAddr::V4(Ipv4Addr::new(127,0,0,1));
        let p2p_peer = P2PPeer::new( ConnectionType::Node, ip, 8080);
        let node_id: P2PNodeId = P2PNodeId::from_ip_port( ip, 8080);

        let data = vec![
            NRequest::Ping( p2p_peer.clone()),
            NRequest::FindNode( p2p_peer.clone(), node_id.clone()),
            NRequest::BanNode( p2p_peer.clone(), p2p_peer.clone())
        ];
        data
    }

    #[test]
    pub fn ut_1() {
        let rh = make_request_handler();

        for message in ut_1_data() {
            (&rh)(&message).unwrap();
        }

        assert_eq!( PING_COUNTER.load(Ordering::Relaxed), 1);
        assert_eq!( FIND_NODE_COUNTER.load(Ordering::Relaxed), 1);
        assert_eq!( BAN_NODE_COUNTER.load(Ordering::Relaxed), 1);
    }
}
