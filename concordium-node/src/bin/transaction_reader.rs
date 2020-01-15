use std::{
    env,
    fs::File,
    io::{self, Cursor, Read},
};

use concordium_common::serial::Serial;
use globalstate_rust::transaction::BareTransaction;

fn read_transaction(bytes: &[u8]) {
    let mut cursor = Cursor::new(bytes);
    let transaction = BareTransaction::deserial(&mut cursor)
        .expect("Can't serialize the provided data as a Transaction object!");

    println!("{:#?}", transaction);
}

fn main() -> io::Result<()> {
    let mut args = env::args();
    let _ = args.next();
    let filename = args.next().expect("No arguments provided (expected a filename)!");
    let mut file = File::open(filename)?;
    let mut buffer = Vec::new();

    file.read_to_end(&mut buffer)?;

    read_transaction(&buffer);

    Ok(())
}
