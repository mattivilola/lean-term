#!/usr/bin/env python3
"""Summarize exported Typometer columns; preserve duplicate titles by ordinal."""
import argparse
import csv
import json
import math
from pathlib import Path
import statistics


def summarize(path):
    with path.open(newline='') as source:
        rows = list(csv.reader(source))
    if not rows:
        raise ValueError('Empty CSV')
    result = []
    for index, title in enumerate(rows[0]):
        values = [float(row[index]) for row in rows[1:] if index < len(row) and row[index].strip()]
        if not values or not all(math.isfinite(value) and value >= 0 for value in values):
            raise ValueError(f'Invalid samples in column {index + 1}')
        ordered = sorted(values)
        position = 0.95 * (len(values) - 1)
        low, high = math.floor(position), math.ceil(position)
        p95 = ordered[low] + (position - low) * (ordered[high] - ordered[low])
        result.append({'column': index + 1, 'title': title, 'samples': len(values),
                       'median_ms': statistics.median(values), 'p95_ms': p95,
                       'mean_ms': statistics.mean(values), 'min_ms': min(values),
                       'max_ms': max(values), 'population_sd_ms': statistics.pstdev(values)})
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('csv', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    text = json.dumps(summarize(args.csv), indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    print(text, end='')
