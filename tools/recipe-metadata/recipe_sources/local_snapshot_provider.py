"""Convenience loader for the default committed offline metadata snapshot."""

from pathlib import Path

from recipe_sources.db2_provider import DEFAULT_SNAPSHOT, load_committed_snapshots
from recipe_sources.secondary_provider import load_secondary_sources


def load_local_snapshot(snapshot_root, snapshot=DEFAULT_SNAPSHOT):
    primary = load_committed_snapshots(snapshot_root, snapshot)
    secondary = load_secondary_sources(Path(primary["snapshotDir"]))
    return primary, secondary
