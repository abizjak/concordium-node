# To rebuild using docker
The below expects the p2p-client source to be checked out at
`$HOME/git/concordium/p2p-client`.
```bash
$> docker run -v $HOME/git/concordium/p2p-client:/p2p-client -t -i archlinux/base /bin/bash
$> pacman -Syyu wget tar git
$> cd /p2p-client
$> scripts/genesis-data/generate-data.sh
$> exit # to exit the docker container```

Then proceed to check-in the new genesis data.