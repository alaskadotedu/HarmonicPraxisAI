import argparse
import json
from .bridge import HarmonicBridge


def main() -> None:
    parser = argparse.ArgumentParser(prog="harmonic-praxis", description="Harmonic Praxis AI Python CLI")
    parser.add_argument("--profile", default="PHOTONIC_CRYSTAL_HEX", help="Material lattice profile")
    parser.add_argument("--rows", type=int, default=4, help="Wafer grid rows")
    parser.add_argument("--cols", type=int, default=4, help="Wafer grid columns")
    parser.add_argument("--snapshot", action="store_true", help="Create SHA-256 workspace snapshot")
    parser.add_argument("--edl", action="store_true", help="Verify DPAPI-sealed EDL bearer transit")
    args = parser.parse_args()

    bridge = HarmonicBridge()
    if args.edl:
        print(json.dumps(bridge.verify_edl_transit(), indent=2))
        return
    if args.snapshot:
        print(json.dumps(bridge.snapshot(), indent=2))
        return
    result = bridge.synthesize(profile=args.profile, rows=args.rows, cols=args.cols)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()