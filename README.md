# iohk-challenge

## Building

    stack build

Tested on GHC 8.0.2.

## Running

The executable takes a list of space-delimited hosts to connect to. For example,
if we had three machines, it could look something like this:

    user@10.0.0.1 $ stack exec iohk-node -- --port 9000 10.0.0.2:9000 10.0.0.3:9000
    user@10.0.0.2 $ stack exec iohk-node -- --port 9000 10.0.0.1:9000 10.0.0.3:9000
    user@10.0.0.3 $ stack exec iohk-node -- --port 9000 10.0.0.1:9000 10.0.0.2:9000

To specify sending time and grace period, pass `--send-for N` and `--wait-for N`,
where N is in seconds.

To specify a random seed, pass `--with-seed N`.
