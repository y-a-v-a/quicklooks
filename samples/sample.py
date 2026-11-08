#!/usr/bin/env python3
"""Module docstring spanning lines.

It mentions def, class and return, which must not be coloured as keywords,
and a # that is not a comment.
"""
from dataclasses import dataclass

TIMEOUT = 30  # seconds
URL = "https://example.com/#anchor"   # the # inside the string is not a comment


@dataclass
class Order:
    """One-line docstring."""
    id: int
    total: float = 0.0

    def label(self) -> str:
        return f"Order {self.id}: {self.total:.2f}"


async def fetch(ids, retries=3):
    for i in ids:
        if i is None or not isinstance(i, int):
            continue
        yield await lookup(i)
    raise TimeoutError('gave up after %d tries' % retries)
