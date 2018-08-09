use hacl_star::sha2;
use nom::rest;
use openssl::asn1::Asn1Time;
use openssl::bn::{BigNum, MsbOption};
use openssl::ec::{EcGroup, EcKey};
use openssl::hash::MessageDigest;
use openssl::nid::Nid;
use openssl::pkey::{PKey, Private};
use openssl::rsa::Rsa;
use openssl::x509::extension::SubjectAlternativeName;
use openssl::x509::{X509Builder, X509NameBuilder, X509};
use std::io::Error;
use std::net::IpAddr;
use std::str::FromStr;
use trust_dns::client::{Client, ClientConnection, ClientStreamHandle, SecureSyncClient, SecureClientHandle};
use trust_dns::udp::UdpClientConnection;
use trust_dns::op::DnsResponse;
use trust_dns::rr::{DNSClass, Name, RData, Record, RecordType};
use common::P2PPeer;

pub fn sha256(input: &str) -> [u8; 32] {
    let mut output = [0; 32];
    sha2::Sha256::hash(&mut output, input.as_bytes());
    output
}

pub fn to_hex_string(bytes: [u8; 32]) -> String {
    let strs: Vec<String> = bytes.iter().map(|b| format!("{:02X}", b)).collect();
    strs.join("")
}

pub struct Cert {
    pub x509: X509,
    pub private_key: Rsa<Private>,
}

pub fn generate_certificate(id: String) -> Result<Cert, Error> {
    let group = EcGroup::from_curve_name(Nid::SECP224R1).unwrap();
    match EcKey::generate(&group) {
        Ok(_) => {
            match X509Builder::new() {
                Ok(mut builder) => {
                    match X509NameBuilder::new() {
                        Ok(mut name_builder) => {
                            name_builder.append_entry_by_text("C", "EU").unwrap();
                            name_builder.append_entry_by_text("O", "Concordium")
                                        .unwrap();
                            name_builder.append_entry_by_text("CN", &id).unwrap();

                            //let pkey = PKey::from_ec_key(private_key.clone()).unwrap();
                            let private_part = Rsa::generate(2048).unwrap();
                            let pkey = PKey::from_rsa(private_part.clone()).unwrap();

                            let name = name_builder.build();
                            builder.set_subject_name(&name).unwrap();
                            builder.set_issuer_name(&name).unwrap();
                            builder.set_pubkey(&pkey).unwrap();
                            builder.set_version(2).unwrap();

                            builder.set_not_before(&Asn1Time::days_from_now(0).unwrap())
                                   .unwrap();

                            builder.set_not_after(&Asn1Time::days_from_now(365).unwrap())
                                   .unwrap();

                            let mut serial = BigNum::new().unwrap();
                            serial.rand(128, MsbOption::MAYBE_ZERO, false).unwrap();
                            builder.set_serial_number(&serial.to_asn1_integer().unwrap())
                                   .unwrap();

                            let subject_alternative_name = SubjectAlternativeName::new()
                .dns(&format!("{}.node.concordium.com", id))
                .build(&builder.x509v3_context(None, None))
                .unwrap();
                            builder.append_extension(subject_alternative_name).unwrap();

                            builder.sign(&pkey, MessageDigest::sha256()).unwrap();

                            Ok(Cert { x509: builder.build(),
                                      private_key: private_part, })
                        }
                        Err(e) => Err(Error::from(e)),
                    }
                }
                Err(e) => Err(Error::from(e)),
            }
        }
        Err(e) => Err(Error::from(e)),
    }
}

named!(nom_ip_port_parse<&str,(IpAddr,u16)>,
    do_parse!(
      ip: take_until_and_consume1!(":") >>
      port: rest >>
      (( IpAddr::from_str(ip).unwrap(), port.parse::<u16>().unwrap()))
    )
);

pub fn parse_ip_port(input: &str) -> Option<(IpAddr, u16)> {
    match nom_ip_port_parse(input) {
        Ok((_, (ip, port))) => Some((ip, port)),
        _ => None,
    }
}

pub fn get_bootstrap_node() {
    let resolver_address = "8.8.8.8:53".parse().unwrap();

    match UdpClientConnection::new(resolver_address) {
        Ok(conn) => {
            let client = SecureSyncClient::new(conn).build();

            //Remember trailing dot to make it a FQDN.
            match Name::from_str("concordium.com.") {
                Ok(name) => {
                    match client.query(&name, DNSClass::IN, RecordType::A) {
                        Ok(response) => {
                            let answers: &[Record] = response.answers();

                            if let &RData::A(ref ip) = answers[0].rdata() {
                                println!("I got response {:?}", ip);
                            }
                        },
                        Err(e) => panic!("Couldn't query DNS server for specified name {:?}", e),
                    }
                },
                Err(e) => panic!("Couldn't create FQDN from specified name! {:?}", e),
            }
        },
        Err(e) => panic!("Couldn't create connection to resolver! {:?}", e),
    }

}
