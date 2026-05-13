#!/usr/bin/env python3
"""Generate graphs from Bluetti data.csv."""

import argparse
import sys
from pathlib import Path

import matplotlib.dates as mdates
import matplotlib.pyplot as plt
import pandas as pd


def load_csv(path):
    df = pd.read_csv(path, parse_dates=["timestamp"])
    df.set_index("timestamp", inplace=True)
    return df


def plot_power(df, output):
    fig, axes = plt.subplots(3, 1, figsize=(14, 10), sharex=True)
    fig.suptitle("Bluetti AC200MAX - Power Monitor", fontsize=14, fontweight="bold")

    ax = axes[0]
    ax.plot(df.index, df["dc_input_power"], color="green", label="DC Input (Solar)")
    ax.plot(df.index, df["ac_output_power"], color="red", label="AC Output (Load)")
    ax.plot(df.index, df["ac_input_power"], color="blue", label="AC Input")
    ax.plot(df.index, df["dc_output_power"], color="orange", label="DC Output")
    ax.set_ylabel("Power (W)")
    ax.legend(loc="upper right")
    ax.grid(True, alpha=0.3)

    ax = axes[1]
    ax.plot(df.index, df["internal_dc_input_voltage"], color="green", label="DC Input Voltage")
    ax_twin = ax.twinx()
    ax_twin.plot(df.index, df["internal_dc_input_current"], color="purple", label="DC Input Current")
    ax.set_ylabel("Voltage (V)", color="green")
    ax_twin.set_ylabel("Current (A)", color="purple")
    ax.legend(loc="upper left")
    ax_twin.legend(loc="upper right")
    ax.grid(True, alpha=0.3)

    ax = axes[2]
    ax.plot(df.index, df["internal_ac_voltage"], color="blue", label="AC Voltage")
    ax_twin = ax.twinx()
    ax_twin.plot(df.index, df["internal_current_one"], color="purple", label="AC Current")
    ax_twin.plot(df.index, df["internal_ac_frequency"], color="orange", linestyle="--", label="AC Freq (Hz)")
    ax.set_ylabel("Voltage (V)", color="blue")
    ax_twin.set_ylabel("Current (A) / Freq (Hz)", color="purple")
    ax.legend(loc="upper left")
    ax_twin.legend(loc="upper right")
    ax.grid(True, alpha=0.3)
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))
    ax.set_xlabel("Time")

    plt.tight_layout()
    fig.savefig(output, dpi=150)
    print(f"Saved {output}")


def plot_battery(df, output):
    fig, ax1 = plt.subplots(figsize=(14, 5))
    fig.suptitle("Bluetti AC200MAX - Battery", fontsize=14, fontweight="bold")

    ax1.plot(df.index, df["total_battery_percent"], color="green", linewidth=2, label="Battery %")
    ax1.fill_between(df.index, df["total_battery_percent"], alpha=0.15, color="green")
    ax1.set_ylabel("Battery (%)", color="green")
    ax1.set_ylim(0, 105)
    ax1.legend(loc="upper left")
    ax1.grid(True, alpha=0.3)

    ax2 = ax1.twinx()
    ax2.plot(df.index, df["total_battery_voltage"], color="blue", label="Voltage")
    ax2.set_ylabel("Voltage (V)", color="blue")
    ax2.legend(loc="upper right")

    ax1.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))
    ax1.set_xlabel("Time")
    plt.tight_layout()
    fig.savefig(output, dpi=150)
    print(f"Saved {output}")


def main():
    parser = argparse.ArgumentParser(description="Generate graphs from Bluetti CSV data")
    parser.add_argument("--input", "-i", default="data.csv", help="CSV file (default: data.csv)")
    parser.add_argument("--output", "-o", default=None, help="Output PNG (default: <stem>_power.png / <stem>_battery.png)")
    args = parser.parse_args()

    if not Path(args.input).exists():
        print(f"File not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    df = load_csv(args.input)
    if len(df) == 0:
        print("No data rows in CSV", file=sys.stderr)
        sys.exit(1)

    stem = Path(args.input).stem
    out_power = args.output or f"{stem}_power.png"
    out_battery = args.output or f"{stem}_battery.png"

    plot_power(df, out_power)
    plot_battery(df, out_battery)


if __name__ == "__main__":
    main()
