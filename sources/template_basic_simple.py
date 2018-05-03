#!/usr/bin/env python3

import asyncio
import iterm2
import sys
# This script was created with the "basic" environment which does not support adding dependencies
# outside of those that ship with Python.

async def main(connection, argv):
    # Your code goes here. Here's a bit of example code that adds a tab to the current window:
    a = await iterm2.app.async_get_app(connection)
    w = await a.async_get_key_window()
    if w is not None:
        await w.async_create_tab()
    else:
        # You can view this message in the script console. Open the script console before running
        # the script.
        print("No current window")

if __name__ == "__main__":
    iterm2.connection.Connection().run(main, sys.argv)