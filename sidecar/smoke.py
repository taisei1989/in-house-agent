"""Real model smoke test: python -m sidecar.smoke --model ... --workspace ..."""
import argparse
import asyncio
from .backend import BackendConfig, SDKBackend


async def smoke(args):
    async def read_only(call, reason=""):
        return getattr(call.name, "value", call.name) in {
            "list_directory", "find_file", "view_file", "search_directory", "finish"
        }
    backend = SDKBackend(BackendConfig(args.model, args.workspace), read_only)
    try:
        await backend.start()
        async for event in backend.stream("What files are in the current directory? Use the list_directory tool and report the file names."):
            if event["type"] == "token":
                print(event["text"], end="", flush=True)
            else:
                print(f"\nTool: {event.get('name')} {event.get('status')}", flush=True)
        print()
    finally:
        await backend.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--workspace", required=True)
    asyncio.run(smoke(parser.parse_args()))
