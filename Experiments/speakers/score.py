#!/usr/bin/env python3
# EXPERIMENT (for docs/design/speaker-labels.md), not product code.
#
#   python3 Experiments/speakers/score.py <run.jsonl.chars.json> <truth.json> [--skip <seconds>]
#   python3 Experiments/speakers/score.py --segments <kk-spike-diar out.json> <run.jsonl.chars.json> <truth.json>
#
# With --segments, the characters' times are kept but their speakers come from another
# diarizer's segments (the one active at the character's middle, else none), so both are scored
# on exactly the same characters.
#
# Scores `kikitori-cli speakers --json` against a truth file from splice.py. Every recognized
# character has the speaker shown for it (its turn's label); its truth is the turn its middle
# falls in (characters in the gaps are not scored). Labels are matched to true speakers by
# the mapping that gets the most characters right (labels are arbitrary letters).
#   - character accuracy: share of characters shown with the right speaker;
#   - speaker changes: true changes between consecutive scored characters, found when a shown
#     change lies within ±0.5 s (and ±1 s); precision counts shown changes near a true one;
#   - lines: share of shown turns (lines without translation) whose label is right for most of it.
# --skip: leave out the first seconds (the tracker is still learning the voices).
import itertools, json, sys

args = sys.argv[1:]
segments = None
if args and args[0] == "--segments":
    segments = json.load(open(args[1])); args = args[2:]
chunks = json.load(open(args[0]))
if segments is not None:
    for chunk in chunks:
        for c in chunk:
            mid = (c["start"] + c["end"]) / 2
            hit = [s for s in segments if s["start"] <= mid < s["end"]]
            c["speaker"] = hit[0]["speaker"] if hit else ""
truth = json.load(open(args[1]))
skip = float(args[args.index("--skip") + 1]) if "--skip" in args else 0

def true_speaker(t):
    for seg in truth:
        if seg["start"] <= t < seg["end"]: return seg["speaker"]
    return None

chars, lines = [], []
for chunk in chunks:
    line = []
    for c in chunk:
        mid = (c["start"] + c["end"]) / 2
        if mid < skip: continue
        item = (mid, c["speaker"], true_speaker(mid))
        chars.append(item)
        if line and line[-1][1] != c["speaker"]: lines.append(line); line = []
        line.append(item)
    if line: lines.append(line)

scored = [c for c in chars if c[2] is not None]
labels = sorted({c[1] for c in scored})
people = sorted({c[2] for c in scored})
best, mapping = -1, {}
for perm in itertools.permutations(people + [None] * max(0, len(labels) - len(people)), len(labels)):
    m = dict(zip(labels, perm))
    right = sum(1 for _, l, p in scored if m[l] == p)
    if right > best: best, mapping = right, m
print(f"characters scored: {len(scored)} (of {len(chars)}); labels {labels} → {mapping}")
print(f"character accuracy: {best / len(scored):.1%}")
for p in people:
    mine = [c for c in scored if c[2] == p]
    print(f"  {p}: {sum(1 for c in mine if mapping[c[1]] == p) / len(mine):.1%} of {len(mine)}")

def changes(seq, key):
    return [(seq[i][0] + seq[i + 1][0]) / 2 for i in range(len(seq) - 1)
            if key(seq[i]) != key(seq[i + 1]) and seq[i + 1][0] - seq[i][0] < 3]

true_changes = changes(scored, lambda c: c[2])
shown_changes = changes(scored, lambda c: c[1])
for tol in (0.5, 1.0):
    found = sum(1 for t in true_changes if any(abs(t - s) <= tol for s in shown_changes))
    good = sum(1 for s in shown_changes if any(abs(t - s) <= tol for t in true_changes))
    print(f"speaker changes ±{tol} s: recall {found}/{len(true_changes)} = {found / max(1, len(true_changes)):.0%}, "
          f"precision {good}/{len(shown_changes)} = {good / max(1, len(shown_changes)):.0%}")
right = 0
for line in lines:
    votes = {}
    for _, l, p in line:
        if p is not None: votes[p] = votes.get(p, 0) + 1
    if votes and mapping.get(line[0][1]) == max(votes, key=votes.get): right += 1
print(f"lines (turns shown): {right}/{len(lines)} = {right / max(1, len(lines)):.0%} with the right speaker")
