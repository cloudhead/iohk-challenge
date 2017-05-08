# iohk-challenge

The approach taken here is to broadcast messages between nodes without expecting a reply.
Each node has a receiving process and a broadcasting process which work independently, to
exploit parallelism, and avoid blocking while waiting for messages. We use a "fire and forget" model because nodes cannot rely on each other to be online beyond the initial
discovery phase.

To maintain total ordering by *time sent*, we have to buffer. The size of that buffer is specified with the `--buffer` flag, which defaults to 10'000 messages. Without the buffer, ordering is only on a per-node basis, since we already receive messages in sending order, but not accross nodes. If a message arrives too late to be processed in order, it is dropped. If nodes have even connectivity, a smaller buffer size should do. In the case of discrepancies between nodes, the node with the highest ping will have its messages dropped the most, since the buffer will fill with "faster" nodes.

If we wanted to maintain complete ordering with no dropped messages, we would have to store every single message. This is of course not practical, hence the buffer size parameter.

With more time, we could have run a profiler to find out if there are any hotspots, or try out different methods of maintaining ordering.

## Assumptions

* The nodes need to be started together, and available in the initial startup phase, as they will wait for each of their remotes to be online before starting to broadcast. However, if one node dies, the rest will keep going.

* Nodes are well-behaved and run in a trusted network.

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

To specify a random seed, pass `--with-seed N`. To see all options, run the command with
no arguments.

## Output

At the end of the grace period, the program outputs two values, delimited with a space, to stdout. The first is the number of messages received and the second is the final computed value. Note that dropped messages are not included in either of these.

Debug information is output to stderr.
