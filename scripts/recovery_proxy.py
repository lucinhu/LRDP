#!/usr/bin/env python3
"""Private loopback fault injector. TLS remains end-to-end; no packet inspection."""
import argparse
import asyncio
import json
from pathlib import Path

async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--alternate-port', type=int, required=True)
    parser.add_argument('--control', required=True)
    args = parser.parse_args()
    active_port = args.port
    paused = False
    connections = 0
    writers = set()
    gate = asyncio.Event()
    gate.set()

    async def forward(reader, writer):
        while data := await reader.read(65536):
            await gate.wait()
            writer.write(data)
            await writer.drain()

    async def client(reader, writer):
        nonlocal connections
        connections += 1
        upstream = None
        tasks = []
        writers.add(writer)
        try:
            if paused:
                return
            incoming, upstream = await asyncio.open_connection('127.0.0.1', active_port)
            writers.add(upstream)
            tasks = [asyncio.create_task(forward(reader, upstream)),
                     asyncio.create_task(forward(incoming, writer))]
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        except (ConnectionError, OSError):
            pass
        finally:
            for task in tasks:
                task.cancel()
            if tasks:
                await asyncio.gather(*tasks, return_exceptions=True)
            for stream in (writer, upstream):
                if stream:
                    writers.discard(stream)
                    stream.close()
                    try:
                        await stream.wait_closed()
                    except (ConnectionError, OSError):
                        pass

    async def control(reader, writer):
        nonlocal paused, active_port
        command = (await reader.readline()).decode().strip()
        if command == 'hold':
            gate.clear()
        elif command == 'release':
            gate.set()
        elif command == 'pause':
            paused = True
        elif command == 'resume':
            paused = False
        elif command == 'rotate':
            active_port = args.alternate_port
        if command in ('drop', 'pause', 'rotate'):
            for stream in tuple(writers):
                stream.transport.abort()
        writer.write((json.dumps({'connections': connections, 'paused': paused, 'holding': not gate.is_set()}) + '\n').encode())
        await writer.drain()
        writer.close()
        await writer.wait_closed()

    tcp = await asyncio.start_server(client, '127.0.0.1', 0)
    unix = await asyncio.start_unix_server(control, args.control)
    Path(args.control).chmod(0o600)
    print(json.dumps({'port': tcp.sockets[0].getsockname()[1]}), flush=True)
    async with tcp, unix:
        await asyncio.gather(tcp.serve_forever(), unix.serve_forever())

if __name__ == '__main__':
    asyncio.run(main())
